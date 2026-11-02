#!/usr/bin/env python3
"""Opt-in Mailman Suite installer. Never imports or publishes legacy archives."""
import argparse
import configparser
import datetime
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import base64
import time
import urllib.request
import urllib.error
import urllib.parse

PREFIX = Path('/opt/postfixer-mailman3')
CONFIG = Path('/etc/postfixer-mailman3')
USER = 'postfixer-mailman'
DBUSER = 'postfixer_mailman'
VENV = PREFIX / 'venv'
DATA = PREFIX / 'core'
MAPS = DATA / 'data'


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def output(*args):
    return subprocess.check_output([str(a) for a in args], text=True).strip()


def validate_domain(value):
    if len(value) > 253 or not re.fullmatch(r'(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', value):
        raise ValueError('A lowercase fully qualified list domain is required')
    return value


def prepend_map(value, item):
    tokens = [v for v in re.split(r'[,\s]+', value.strip()) if v]
    return ', '.join([item] + [v for v in tokens if v != item])


def write_new(path, content, mode=0o640):
    """Host-owned settings and generated secrets survive every reinstall."""
    if path.exists():
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    with os.fdopen(fd, 'w') as stream:
        stream.write(content)


def managed(path, content, mode=0o644):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and path.read_text() == content:
        return
    tmp = path.with_suffix(path.suffix + '.postfixer-new')
    tmp.write_text(content)
    tmp.chmod(mode)
    tmp.replace(path)


def as_user(*args, **kwargs):
    kwargs.setdefault('cwd', str(PREFIX))
    pythonpath = kwargs.pop('pythonpath', str(CONFIG))
    return run('runuser', '-u', USER, '--', 'env',
               'PYTHONPATH=' + pythonpath, 'DJANGO_SETTINGS_MODULE=settings',
               'MAILMAN_CONFIG_FILE=' + str(CONFIG / 'mailman.cfg'),
               *args, **kwargs)


def configure_postfix():
    if not (CONFIG / 'mailman.cfg').exists():
        raise RuntimeError('Install Mailman before configuring Postfix')
    if not (MAPS / 'postfix_lmtp.db').exists():
        raise RuntimeError('Mailman generated recipient map is missing')
    domain = (CONFIG / 'domain').read_text().strip()
    # A relay list domain must not also be a local/virtual domain.
    for param in ('mydestination', 'virtual_alias_domains', 'virtual_mailbox_domains'):
        value = output('postconf', '-h', param)
        for token in re.split(r'[,\s]+', value):
            if token.rstrip('.') == domain:
                raise RuntimeError(f'{domain} conflicts with {param}')
            if token.startswith('/') and Path(token).is_file():
                for line in Path(token).read_text().splitlines():
                    if line.split('#', 1)[0].strip().rstrip('.') == domain:
                        raise RuntimeError(f'{domain} conflicts with {token}')
    # Keep existing recipient policy. An empty relay map means other domains
    # accept every recipient; adding one global map would narrow that policy.
    recipients = output('postconf', '-h', 'relay_recipient_maps')
    relay = output('postconf', '-h', 'relay_domains')
    if not recipients:
        other = []
        for token in re.split(r'[,\s]+', relay):
            if not token:
                continue
            if token.startswith('/') and Path(token).is_file():
                other += [l.split('#', 1)[0].strip() for l in Path(token).read_text().splitlines() if l.split('#', 1)[0].strip()]
            elif token != 'hash:' + str(MAPS / 'postfix_domains'):
                other.append(token)
        if other:
            raise RuntimeError('Existing relay domains lack recipient validation; review before enabling Mailman')
    for param, item in [('transport_maps', 'hash:' + str(MAPS / 'postfix_lmtp')),
                        ('relay_domains', 'hash:' + str(MAPS / 'postfix_domains')),
                        ('relay_recipient_maps', 'hash:' + str(MAPS / 'postfix_lmtp'))]:
        run('postconf', '-e', param + ' = ' + prepend_map(output('postconf', '-h', param), item))
    run('postconf', '-e', 'owner_request_special = no')
    run('postfix', 'check')


def ensure_domain(domain):
    config = configparser.ConfigParser()
    config.read(CONFIG / 'mailman.cfg')
    auth = base64.b64encode((config['webservice']['admin_user'] + ':' + config['webservice']['admin_pass']).encode()).decode()
    headers = {'Authorization': 'Basic ' + auth}
    for attempt in range(15):
        try:
            url = 'http://127.0.0.1:8001/3.1/domains/' + urllib.parse.quote(domain)
            with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=3):
                return
        except urllib.error.HTTPError as e:
            if e.code != 404:
                raise RuntimeError('Mailman domain lookup failed: HTTP ' + str(e.code)) from None
            data = urllib.parse.urlencode({'mail_host': domain, 'description': domain}).encode()
            with urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:8001/3.1/domains', headers=headers, data=data), timeout=5):
                return
        except (urllib.error.URLError, TimeoutError):
            if attempt == 14:
                raise RuntimeError('Mailman REST API did not become available') from None
            time.sleep(1)


def install(domain, owner, cert):
    validate_domain(domain)
    validate_domain(cert)
    if not re.fullmatch(r'[^\s@]+@[^\s@]+\.[^\s@]+', owner):
        raise ValueError('A real site-owner email address is required')
    if (CONFIG / 'domain').exists() and (CONFIG / 'domain').read_text().strip() != domain:
        raise RuntimeError('Existing installation has a different domain; refusing to rewrite it')
    for file in ('fullchain.pem', 'privkey.pem'):
        if not (Path('/etc/letsencrypt/live') / cert / file).is_file():
            raise RuntimeError('Externally managed TLS certificate is missing')
    backup = Path('/var/backups/postfixer') / ('mailman3-' + datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ'))
    backup.mkdir(parents=True, mode=0o700)
    shutil.copytree('/etc/postfix', backup / 'postfix', symlinks=True)
    if CONFIG.exists():
        shutil.copytree(CONFIG, backup / 'mailman3')
    print('Backup:', backup, flush=True)
    run('apt-get', 'update')
    run('apt-get', 'install', '-y', '--no-install-recommends',
        'python3-venv', 'python3-dev', 'build-essential', 'libpq-dev',
        'libffi-dev', 'sassc', 'lynx', 'postgresql', 'nginx', 'curl')
    if subprocess.run(['id', '-u', USER], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
        run('useradd', '--system', '--home-dir', str(PREFIX), '--create-home', '--shell', '/usr/sbin/nologin', USER)
    PREFIX.mkdir(parents=True, exist_ok=True)
    CONFIG.mkdir(parents=True, exist_ok=True)
    run('chown', USER + ':' + USER, PREFIX)
    run('chown', 'root:' + USER, CONFIG)
    CONFIG.chmod(0o750)
    for p in [DATA, PREFIX / 'web', PREFIX / 'web/logs', PREFIX / 'web/static']:
        p.mkdir(parents=True, exist_ok=True)
        run('chown', USER + ':' + USER, p)
    run('systemctl', 'enable', '--now', 'postgresql')
    # Local peer authentication, with a dedicated fixed role/database pair.
    mapping = Path('/etc/postgresql')
    versions = sorted(mapping.glob('*/main/pg_ident.conf'))
    if len(versions) != 1:
        raise RuntimeError('Expected one PostgreSQL main cluster; configure database explicitly')
    ident = versions[0]
    hba = ident.with_name('pg_hba.conf')
    ident_line = 'postfixer_mailman ' + USER + ' ' + DBUSER
    if ident_line not in ident.read_text().splitlines():
        with ident.open('a') as f:
            f.write('\n' + ident_line + '\n')
    hba_line = 'local mailman3_core,mailman3_web ' + DBUSER + ' peer map=postfixer_mailman'
    if hba_line not in hba.read_text().splitlines():
        managed(hba, hba_line + '\n' + hba.read_text(), 0o640)
        run('chown', 'postgres:postgres', hba)
    run('runuser', '-u', 'postgres', '--', 'psql', '-v', 'ON_ERROR_STOP=1',
        '-c', 'SELECT pg_reload_conf();', stdout=subprocess.DEVNULL)
    sql = "DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='postfixer_mailman') THEN CREATE ROLE postfixer_mailman LOGIN; END IF; END $$;"
    run('runuser', '-u', 'postgres', '--', 'psql', '-v', 'ON_ERROR_STOP=1', '-c', sql, stdout=subprocess.DEVNULL)
    for db in ('mailman3_core', 'mailman3_web'):
        exists = output('runuser', '-u', 'postgres', '--', 'psql', '-tAc', f"SELECT 1 FROM pg_database WHERE datname='{db}'")
        if not exists:
            run('runuser', '-u', 'postgres', '--', 'createdb', '-O', DBUSER, db)
    if not (VENV / 'bin/python').exists():
        as_user('python3', '-m', 'venv', VENV)
    requirements = Path(__file__).with_name('mailman3-requirements.txt')
    lock = Path(__file__).with_name('mailman3-requirements.lock')
    if lock.is_file():
        requirements = lock
    managed(PREFIX / 'requirements.txt', requirements.read_text())
    with tempfile.TemporaryDirectory(prefix='pip-network-', dir=PREFIX) as temp:
        pythonpath = str(CONFIG)
        if os.environ.get('MAILMAN_PIP_IPV4') == 'yes':
            # Installer and isolated build subprocesses only, never global policy.
            Path(temp).chmod(0o755)
            managed(Path(temp) / 'sitecustomize.py',
                    'import socket\n_original = socket.getaddrinfo\n'
                    'socket.getaddrinfo = lambda h,p,f=0,t=0,pr=0,fl=0: _original(h,p,socket.AF_INET,t,pr,fl)\n')
            pythonpath = temp + ':' + str(CONFIG)
        as_user(VENV / 'bin/python', '-m', 'pip', 'install', '--disable-pip-version-check',
                '-r', PREFIX / 'requirements.txt', pythonpath=pythonpath)
    write_new(CONFIG / 'domain', domain + '\n')
    write_new(CONFIG / 'mailman.cfg', f'''[paths.postfixer]
var_dir: {DATA}
[mailman]
layout: postfixer
site_owner: {owner}
[database]
class: mailman.database.postgresql.PostgreSQLDatabase
url: postgresql://{DBUSER}@/mailman3_core
[mta]
incoming: mailman.mta.postfix.LMTP
outgoing: mailman.mta.deliver.deliver
lmtp_host: 127.0.0.1
lmtp_port: 8024
smtp_host: 127.0.0.1
smtp_port: 25
configuration: python:mailman.config.postfix
[webservice]
hostname: 127.0.0.1
port: 8001
admin_user: restadmin
admin_pass: {secrets.token_urlsafe(48)}
[archiver.prototype]
enable: yes
[archiver.hyperkitty]
class: mailman_hyperkitty.Archiver
enable: yes
configuration: {CONFIG}/hyperkitty.cfg
''')
    core = configparser.ConfigParser()
    core.read(CONFIG / 'mailman.cfg')
    write_new(CONFIG / 'hyperkitty.cfg', f'[general]\nbase_url: http://127.0.0.1:8000/archives/\napi_key: {secrets.token_urlsafe(48)}\n')
    archive = configparser.ConfigParser()
    archive.read(CONFIG / 'hyperkitty.cfg')
    write_new(CONFIG / 'settings.py', f'''from mailman_web.settings.base import *
from mailman_web.settings.mailman import *
DEBUG = False
SECRET_KEY = {secrets.token_urlsafe(64)!r}
ALLOWED_HOSTS = [{domain!r}, 'localhost', '127.0.0.1']
CSRF_TRUSTED_ORIGINS = ['https://{domain}']
DATABASES = {{'default': {{'ENGINE': 'django.db.backends.postgresql', 'NAME': 'mailman3_web', 'USER': '{DBUSER}', 'HOST': ''}}}}
MAILMAN_REST_API_URL = 'http://127.0.0.1:8001'
MAILMAN_REST_API_USER = 'restadmin'
MAILMAN_REST_API_PASS = {core['webservice']['admin_pass']!r}
MAILMAN_ARCHIVER_KEY = {archive['general']['api_key']!r}
MAILMAN_ARCHIVER_FROM = ('127.0.0.1', '::1')
DEFAULT_FROM_EMAIL = {owner!r}
SERVER_EMAIL = {owner!r}
EMAIL_BACKEND = 'django.core.mail.backends.smtp.EmailBackend'
EMAIL_HOST = '127.0.0.1'
EMAIL_PORT = 25
STATIC_ROOT = '{PREFIX}/web/static'
LOGGING['handlers']['file']['filename'] = '{PREFIX}/web/logs/mailmanweb.log'
HAYSTACK_CONNECTIONS = {{'default': {{'ENGINE': 'haystack.backends.whoosh_backend.WhooshEngine', 'PATH': '{PREFIX}/web/search_index'}}}}
COMPRESS_ENABLED = True
COMPRESS_OFFLINE = True
SECURE_PROXY_SSL_HEADER = ('HTTP_X_FORWARDED_PROTO', 'https')
SESSION_COOKIE_SECURE = True
CSRF_COOKIE_SECURE = True
SITE_ID = 1
''')
    for path in CONFIG.iterdir():
        run('chown', 'root:' + USER, path)
    as_user(VENV / 'bin/mailman', '-C', CONFIG / 'mailman.cfg', 'aliases')
    run('chmod', '0751', DATA)
    run('chmod', '0755', MAPS)
    for path in MAPS.glob('postfix_*'):
        if path.is_file():
            path.chmod(0o644)
    as_user(VENV / 'bin/mailman-web', 'migrate', '--noinput')
    as_user(VENV / 'bin/mailman-web', 'collectstatic', '--noinput')
    as_user(VENV / 'bin/mailman-web', 'compress')
    as_user(VENV / 'bin/mailman-web', 'shell', '-c',
            "from django.contrib.sites.models import Site; Site.objects.update_or_create(id=1, defaults={'domain': " + repr(domain) + ", 'name': 'Mailing lists'})")
    for name, command, kind, extra in [
        ('core', f'{VENV}/bin/mailman -C {CONFIG}/mailman.cfg start', 'forking', f'PIDFile={DATA}/master.pid\nExecStop={VENV}/bin/mailman -C {CONFIG}/mailman.cfg stop\n'),
        ('web', f'{VENV}/bin/gunicorn --bind 127.0.0.1:8000 --workers 2 --access-logfile - mailman_web.wsgi:application', 'simple', ''),
        ('qcluster', f'{VENV}/bin/mailman-web qcluster', 'simple', '')]:
        managed(Path('/etc/systemd/system') / f'postfixer-mailman3-{name}.service', f'''[Unit]
Description=Postfixer Mailman 3 {name}
After=network.target postgresql.service
[Service]
Type={kind}
User={USER}
Group={USER}
WorkingDirectory={PREFIX}/web
Environment=PYTHONPATH={CONFIG}
Environment=DJANGO_SETTINGS_MODULE=settings
Environment=MAILMAN_CONFIG_FILE={CONFIG}/mailman.cfg
ExecStart={command}
{extra}Restart=on-failure
RestartSec=10
UMask={'0022' if name == 'core' else '0027'}
[Install]
WantedBy=multi-user.target
''')
    nginx = f'''# Managed by Postfixer. Mailman API/LMTP are never public.
server {{
    listen 80;
    server_name {domain};
    return 301 https://$host$request_uri;
}}
server {{
    listen 443 ssl;
    server_name {domain};
    ssl_certificate /etc/letsencrypt/live/{cert}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/{cert}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    client_max_body_size 25m;
    location /static/ {{ alias {PREFIX}/web/static/; }}
    location / {{
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-For $remote_addr;
    }}
    # Legacy private archives require authenticated migration; never expose a directory.
    location /pipermail/ {{ return 404; }}
}}
'''
    managed(Path('/etc/nginx/sites-available/postfixer-mailman3'), nginx)
    link = Path('/etc/nginx/sites-enabled/postfixer-mailman3')
    if not link.exists():
        link.symlink_to('/etc/nginx/sites-available/postfixer-mailman3')
    # Static files are public; the rest of the prefix stays private to Mailman.
    run('chmod', '0755', PREFIX, PREFIX / 'web')
    run('chmod', '-R', 'a+rX', PREFIX / 'web/static')
    cron = f'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\nPYTHONPATH={CONFIG}\nDJANGO_SETTINGS_MODULE=settings\nMAILMAN_CONFIG_FILE={CONFIG}/mailman.cfg\n'
    cron += f'@daily {USER} {VENV}/bin/mailman -C {CONFIG}/mailman.cfg digests --periodic\n@daily {USER} {VENV}/bin/mailman -C {CONFIG}/mailman.cfg notify\n'
    for when, job in [('* * * * *', 'minutely'), ('2,17,32,47 * * * *', 'quarter_hourly'), ('@hourly', 'hourly'), ('@daily', 'daily'), ('@weekly', 'weekly'), ('@monthly', 'monthly'), ('@yearly', 'yearly')]:
        cron += f'{when} {USER} {VENV}/bin/mailman-web runjobs {job}\n'
    managed(Path('/etc/cron.d/postfixer-mailman3'), cron)
    configure_postfix()
    run('nginx', '-t')
    run('systemctl', 'daemon-reload')
    for name in ('core', 'web', 'qcluster'):
        run('systemctl', 'enable', '--now', f'postfixer-mailman3-{name}')
    ensure_domain(domain)
    run('systemctl', 'enable', '--now', 'nginx')
    run('systemctl', 'reload', 'nginx')
    run('systemctl', 'reload', 'postfix')
    check(domain)


def check(domain=None):
    domain = domain or (CONFIG / 'domain').read_text().strip()
    for service in ('core', 'web', 'qcluster'):
        run('systemctl', 'is-active', '--quiet', 'postfixer-mailman3-' + service)
    as_user(VENV / 'bin/mailman-web', 'check')
    run('curl', '--fail', '--location', '--silent', '--show-error', '--retry', '8', '--retry-connrefused', '--retry-delay', '1',
        '--resolve', domain + ':443:127.0.0.1', 'https://' + domain + '/', stdout=subprocess.DEVNULL)
    print('Mailman core, web, task queue and HTTPS are healthy. Historical archive recovery is a separate operation.')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=['install', 'postfix', 'check'])
    p.add_argument('--domain', default=os.environ.get('MAILMAN_DOMAIN'))
    p.add_argument('--owner', default=os.environ.get('MAILMAN_OWNER'))
    p.add_argument('--cert', default=os.environ.get('CERT_DOMAIN'))
    a = p.parse_args()
    if os.geteuid():
        p.error('Run as root')
    os.environ['DEBIAN_FRONTEND'] = 'noninteractive'
    if a.action == 'install':
        if not all([a.domain, a.owner, a.cert]):
            p.error('MAILMAN_DOMAIN, MAILMAN_OWNER and CERT_DOMAIN are required')
        install(a.domain, a.owner, a.cert)
    elif a.action == 'postfix':
        configure_postfix()
    else:
        check()


if __name__ == '__main__':
    main()
