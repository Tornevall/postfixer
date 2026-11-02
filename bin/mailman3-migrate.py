#!/usr/bin/env python3
"""Explicit, private and held migration of a selected Mailman 2 list."""
import argparse
import base64
import configparser
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import fcntl
import urllib.request
import urllib.error

CONFIG = Path('/etc/postfixer-mailman3')
PREFIX = Path('/opt/postfixer-mailman3')
USER = 'postfixer-mailman'
VENV = PREFIX / 'venv/bin'


def within(stage, path):
    stage = stage.resolve(strict=True)
    resolved = path.resolve(strict=True)
    if resolved == stage or not resolved.is_relative_to(stage):
        raise ValueError('Staged path escapes the migration directory')
    return resolved


def valid_list(value):
    if not re.fullmatch(r'[a-z0-9][a-z0-9_.+-]{0,63}', value) or '..' in value:
        raise ValueError('Select one lowercase legacy list name without path components')
    return value


def inventory(stage):
    if not stage.is_dir() or not (stage / 'lists').is_dir():
        raise ValueError('Missing staged Mailman 2 lists/ directory; fetch the source first')
    result = []
    for directory in sorted((stage / 'lists').iterdir()):
        if not directory.is_dir():
            continue
        name = valid_list(directory.name)
        config = directory / 'config.pck'
        if not config.is_file():
            continue
        config = within(stage, config)
        mbox = None
        for candidate in [stage / 'archives/private' / (name + '.mbox') / (name + '.mbox'),
                          stage / 'archives/private' / (name + '.mbox')]:
            if candidate.is_file():
                mbox = within(stage, candidate)
                break
        result.append({'list': name, 'config': str(config), 'mbox': str(mbox) if mbox else None,
                       'mbox_bytes': mbox.stat().st_size if mbox else 0,
                       'legacy_html_present': (stage / 'archives/private' / name).is_dir()})
    return result


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def as_user(*args, **kwargs):
    return run('runuser', '-u', USER, '--', 'env', 'PYTHONPATH=' + str(CONFIG),
               'DJANGO_SETTINGS_MODULE=settings', 'MAILMAN_CONFIG_FILE=' + str(CONFIG / 'mailman.cfg'),
               *args, cwd=PREFIX, **kwargs)


def import_list(stage, name, domain=None):
    valid_list(name)
    if os.environ.get('MAILMAN_IMPORT_CONFIRM') != 'reviewed' or os.environ.get('MAILMAN_SOURCE_FROZEN') != 'yes':
        raise ValueError('Review trusted pickle data and freeze the original list service first; set MAILMAN_IMPORT_CONFIRM=reviewed MAILMAN_SOURCE_FROZEN=yes')
    if not (CONFIG / 'mailman.cfg').is_file():
        raise ValueError('Install optional Mailman 3 before importing lists')
    item = next((row for row in inventory(stage) if row['list'] == name), None)
    if item is None:
        raise ValueError('Selected list is not in the staged inventory')
    domain = domain or (CONFIG / 'domain').read_text().strip()
    if not re.fullmatch(r'(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', domain):
        raise ValueError('Invalid target list domain')
    address = name + '@' + domain
    if not re.fullmatch(r'[a-z0-9_.+-]+@[a-z0-9.-]+\.[a-z0-9-]+', address):
        raise ValueError('Invalid target list address')
    cfg = configparser.ConfigParser(); cfg.read(CONFIG / 'mailman.cfg')
    auth = base64.b64encode((cfg['webservice']['admin_user'] + ':' + cfg['webservice']['admin_pass']).encode()).decode()
    headers = {'Authorization': 'Basic ' + auth}
    # Refuse to overwrite an existing live list, even on a repeated invocation.
    try:
        with urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:8001/3.1/lists/' + address, headers=headers), timeout=10):
            raise ValueError('Target list already exists; inspect the prior migration report rather than re-importing memberships')
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise RuntimeError('Cannot verify target list state') from None
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    backup = Path('/var/backups/postfixer') / ('mailman3-import-' + stamp)
    backup.mkdir(parents=True, mode=0o700)
    for db in ('mailman3_core', 'mailman3_web'):
        with (backup / (db + '.dump')).open('wb') as f:
            run('runuser', '-u', 'postgres', '--', 'pg_dump', '-Fc', db, stdout=f)
    shutil.copytree(CONFIG, backup / 'config')
    report = {'list': address, 'source': str(stage.resolve()), 'config_sha256': hashlib.sha256(Path(item['config']).read_bytes()).hexdigest(),
              'archive_imported': False, 'delivery_held': True, 'archive_private': True, 'status': 'starting'}
    report_path = backup / 'migration.json'
    report_path.write_text(json.dumps(report, indent=2))
    work = PREFIX / 'migration' / stamp
    work.mkdir(parents=True, mode=0o700)
    run('chown', USER + ':' + USER, work.parent, work)
    for source, target in [(item['config'], work / 'config.pck'), (item['mbox'], work / 'archive.mbox')]:
        if source:
            shutil.copyfile(source, target)
            target.chmod(0o600)
            run('chown', USER + ':' + USER, target)
    hook = CONFIG / 'postfixer_migration_hooks.py'
    shutil.copyfile(Path(__file__).with_name('mailman3-migration-hooks.py'), hook)
    hook.chmod(0o640); run('chown', 'root:' + USER, hook)
    held = False
    stopped = []
    log = (backup / 'import.log').open('w')
    try:
        for service in ('postfixer-mailman3-qcluster', 'postfixer-mailman3-core'):
            if subprocess.run(['systemctl', 'is-active', '--quiet', service]).returncode == 0:
                run('systemctl', 'stop', service)
                stopped.append(service)
        cli = [VENV / 'mailman', '-C', CONFIG / 'mailman.cfg']
        as_user(*cli, 'create', '--quiet', '-N', address, stdout=log, stderr=log)
        as_user(*cli, 'shell', '-l', address, '-r', 'postfixer_migration_hooks.hold', stdout=log, stderr=log)
        try:
            as_user(*cli, 'import21', address, work / 'config.pck', stdout=log, stderr=log)
        finally:
            # import21 restores legacy policies. Reapply the hold before any runner restarts.
            as_user(*cli, 'shell', '-l', address, '-r', 'postfixer_migration_hooks.hold', stdout=log, stderr=log)
            held = True
        as_user(VENV / 'mailman-web', 'shell', '-c',
                "from hyperkitty.models import MailingList; from hyperkitty.models.mailinglist import ArchivePolicy; MailingList.objects.update_or_create(name=" + repr(address) + ", defaults={'archive_policy': ArchivePolicy.private.value})", stdout=log, stderr=log)
        if item['mbox']:
            as_user(VENV / 'mailman-web', 'hyperkitty_import', '--no-sync-mailman', '-l', address, work / 'archive.mbox', stdout=log, stderr=log)
            report['archive_imported'] = True
        report['status'] = 'imported-held-for-review'
    except Exception:
        report['status'] = 'failed-review-required'
        raise RuntimeError('Import did not complete. Inspect the private migration report: ' + str(backup)) from None
    finally:
        report['delivery_held'] = held
        report_path.write_text(json.dumps(report, indent=2))
        log.close()
        # A failed/unverified hold must never release a partial list.
        if held:
            for service in reversed(stopped):
                run('systemctl', 'start', service)
        else:
            print('Mailman runners remain stopped: hold could not be verified. See ' + str(backup), file=__import__('sys').stderr)
        # Only the copied working files are removed; original staging/backups remain.
        if work.resolve().is_relative_to((PREFIX / 'migration').resolve()):
            shutil.rmtree(work)
    print('Imported ' + address + ' with delivery held and archives private. Review before activation. Report: ' + str(report_path))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['plan', 'import'])
    parser.add_argument('--stage', type=Path, required=True)
    parser.add_argument('--list', default='')
    parser.add_argument('--domain', default=os.environ.get('MAILMAN_TARGET_DOMAIN'))
    args = parser.parse_args()
    if os.geteuid():
        parser.error('Run as root')
    os.umask(0o077)
    if args.action == 'plan':
        print(json.dumps({'stage': str(args.stage), 'lists': inventory(args.stage),
                          'note': 'No pickle executed; no mail sent; no archives published.'}, indent=2))
    else:
        with open('/run/lock/postfixer-mailman3-migrate.lock', 'w') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                parser.error('Another Mailman migration is already running')
            import_list(args.stage, args.list, args.domain)


if __name__ == '__main__':
    main()
