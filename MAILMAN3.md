# Optional Mailman 3 Suite

Mailman is opt-in. Installing a normal Postfixer server/relay never installs it.
The Suite uses an isolated Python environment, PostgreSQL over local peer
authentication, Mailman Core, Postorius, HyperKitty, Gunicorn, a Django task
worker and nginx. No Python 2/Mailman 2 runtime is installed on Noble.

```sh
sudo make install-mailman3 MAILMAN_DOMAIN=lists.example.net \
  MAILMAN_OWNER=postmaster@example.net CERT_DOMAIN=example.net
sudo make check-mailman3
make test-mailman3
```

DNS must already resolve the list host to this server and the externally
managed certificate under `/etc/letsencrypt/live/CERT_DOMAIN/` must cover it.
The list domain must not also appear in Postfix local/virtual destinations.
An installation with other relay domains and no recipient validation fails
closed for operator review rather than changing those domains' policy.

## Configuration and services

- Host-owned config/secrets: `/etc/postfixer-mailman3/`, root-owned and readable
  only by the dedicated service group. Reinstall preserves existing files.
- Runtime: `/opt/postfixer-mailman3/venv/`.
- List data: `/opt/postfixer-mailman3/core/`.
- Web logs/static files: `/opt/postfixer-mailman3/web/`.
- Databases: `mailman3_core`, `mailman3_web`; PostgreSQL role
  `postfixer_mailman`, mapped from system user `postfixer-mailman` via local
  peer authentication. The installer requires one PostgreSQL main cluster.
- Services: `postfixer-mailman3-core`, `postfixer-mailman3-web`,
  `postfixer-mailman3-qcluster`, plus nginx/PostgreSQL.
- REST API: `127.0.0.1:8001`; LMTP: `127.0.0.1:8024`;
  internal web backend: `127.0.0.1:8000`. Do not expose these publicly.
- nginx serves only HTTPS for the selected list domain, with an HTTP redirect.
- Periodic Mailman/HyperKitty jobs: `/etc/cron.d/postfixer-mailman3`.

Existing Postfix routes are preserved. Generated Mailman transport/domain maps
are prepended, and generated recipients are checked before delivery. The
Postfixer installer re-applies this integration when Mailman config exists.
Pre-install configuration backups are under `/var/backups/postfixer/mailman3-*`.
No default administrator password is created. Set up the first operator with:

```sh
sudo -u postfixer-mailman env PYTHONPATH=/etc/postfixer-mailman3 \
  DJANGO_SETTINGS_MODULE=settings \
  /opt/postfixer-mailman3/venv/bin/mailman-web createsuperuser
```

## Mailman 2 recovery is a separate operation

Installation does **not** recover the old lists or archives. The old Maildir
account named `tn-thorne-list` is not a Mailman archive backup.
Recover `/var/lib/mailman/lists/`, `/var/lib/mailman/archives/` and relevant
configuration from the original host/disk/snapshot, retaining access controls.
When the original host is reachable:

```sh
sudo make import-mailman3-fetch REMOTE=root@ORIGINAL_IP
```

Use its original IP, not an alias that now points to the new server. Fetching
stages data under `/root/postfixer-migration/mailman2/`; it never deletes remote
data, imports memberships, starts list delivery, or publishes archives.

Review each list's `config.pck`, owner, moderators, membership and privacy.
Only trusted source files may be passed to Mailman's `import21` command, since
the legacy configuration uses Python pickle. Import each list explicitly using
the installed CLI's `create --help` and `import21 --help`; do not recreate all
old members automatically or send welcome messages during recovery.

Import the original mbox archives with `mailman-web hyperkitty_import` after
the corresponding list exists and its archive privacy is verified. Consult
`hyperkitty_import --help`; import uses a list address and the original mbox.
Verify list counts, message counts, dates, attachments and access control before
enabling delivery. A new installation has no historical archive messages.

Public Pipermail HTML may be preserved as a separately reviewed read-only
archive to retain old URLs. The nginx template deliberately returns 404 for
`/pipermail/` until that recovery is completed. Never alias the whole legacy
`archives/private` tree or assume a Mailman 2 private archive can safely become
public; private archives need authenticated HyperKitty access after import.

Migration reference: https://docs.mailman3.org/en/latest/migration.html

## Backup and updates

Back up both PostgreSQL databases (using `pg_dump`), the private host config,
Mailman queue/data, and recovered legacy archive files. Protect backups like
mailboxes: they may contain member addresses, private messages and secrets.
Database dumps and filesystem snapshots must form a reviewed recovery point;
stop list delivery/task workers for a coordinated final migration snapshot.

Direct package requirements are in `bin/mailman3-requirements.txt`; the tested
resolved versions in `bin/mailman3-requirements.lock` are used when present.
Set `MAILMAN_PIP_IPV4=yes` for package installation on a host with a broken
outbound IPv6 route; this does not change system resolver policy. Changes to
dependencies require a tested upgrade. This install does not alter DNS or the
separate `mail.example.net` webmail host. Use `journalctl -u SERVICE` and the
Mailman logs for diagnostics; never print the full config/API credentials.
