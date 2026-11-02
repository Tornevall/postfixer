# Optional Mailman 3 Suite

Mailman is opt-in. A normal Postfixer installation leaves it out unless selected.
The Suite uses an isolated Python environment, PostgreSQL over local peer
authentication, Mailman Core, Postorius, HyperKitty, Gunicorn, a Django task
worker and nginx. No Python 2/Mailman 2 runtime is installed on Noble.

```sh
sudo make install-server POSTFIXER_INSTALL_MAILMAN=yes \
  MAILMAN_DOMAIN=lists.example.net MAILMAN_OWNER=postmaster@example.net \
  CERT_DOMAIN=example.net
# Or add it later to an already installed server:
sudo make install-mailman3 MAILMAN_DOMAIN=lists.example.net \
  MAILMAN_OWNER=postmaster@example.net CERT_DOMAIN=example.net
sudo make check-mailman3
make test-mailman3
```

The normal interactive installer asks whether to add Mailman, default **no**.
Non-interactive installation defaults to no unless explicitly enabled with
`POSTFIXER_INSTALL_MAILMAN=yes`. `POSTFIXER_INSTALL_MAILMAN=no` skips the optional
step; it never uninstalls an existing list system. Existing Mailman configuration
is retained without asking again. Relay-only profiles do not offer Mailman.

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
sudo make import-mailman3-plan
# Include it with the ordinary Postfix fetch, using the same migration name:
sudo make import-fetch REMOTE=root@ORIGINAL_IP MIGRATION_NAME=inbound-1 \
  IMPORT_MAILMAN=yes
sudo make import-mailman3-plan MIGRATION_NAME=inbound-1
```

Use its original IP, not an alias that now points to the new server. Fetching
stages data under `/root/postfixer-migration/MIGRATION_NAME/mailman2/`; it never deletes remote
data, imports memberships, starts list delivery, or publishes archives.

The canonical migration runner now has `--fetch-mailman`, `--plan-mailman` and
`--import-mailman` actions. The plan inventories config/mbox/HTML without loading
pickle data. The fetch includes the complete list/configuration and archive tree,
including private archives and public HTML symlinks, but never publishes it.

Review each list's `config.pck`, owner, moderators, membership and privacy. Only
trusted source files may be imported because legacy configuration uses Python
pickle. Freeze the old list service and do a final fetch before import. Then:

```sh
sudo make import-mailman3 MIGRATION_NAME=inbound-1 MAILMAN_LIST=example-list \
  MAILMAN_IMPORT_CONFIRM=reviewed MAILMAN_SOURCE_FROZEN=yes
```

Import selects exactly one staged list, refuses an existing target list, backs up
both databases/config, and serializes concurrent migration attempts. It stops
Mailman runners (ordinary Postfix/Courier continue running), imports membership
and config via `import21`, then reapplies emergency moderation, disables list
advertising and forces archive privacy before restarting runners. No welcome or
goodbye messages are enabled. Mbox is imported into HyperKitty if available.
Sensitive diagnostics and a migration manifest are stored in the root-only
`/var/backups/postfixer/mailman3-import-*` directory. A failed unverified hold
leaves Mailman runners stopped for review rather than releasing a partial list.
The original staging files and backups are retained.

New incoming posts to an imported list are held. After reviewing member counts,
owners, moderation policy and archive privacy, the operator can release the
emergency hold and enable advertising in Postorius. Public archive access is a
separate explicit decision. The migration never switches delivery on automatically.

For archive-only recovery or resuming a reviewed partial migration, use
`mailman-web hyperkitty_import` with the list address and original mbox; review
the saved manifest first. The normal importer refuses to overwrite an existing
list rather than silently re-importing memberships.
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

### Preserving additional list domains

Set `MAILMAN_TARGET_DOMAIN=lists.original-domain.example` with
`make import-mailman3` when a legacy list belongs to another posting domain.
Review its original `host_name` before importing; never collapse separate list
domains into the installer default. The importer registers the selected domain
without enabling public archives or releasing the moderation hold. DNS/MX for
that domain must separately reach this mail server.

### Reviewed legacy public HTML

After copying only the originally public list HTML into a separate directory
under `/var/www/`, put that directory path in the root-owned
`/etc/postfixer-mailman3/legacy-public-archives` marker. Reinstall preserves the
marker and renders a read-only `/pipermail/` alias with symlink access disabled.
The default remains 404. Never copy private list HTML or mbox trees into that
public directory. Private restored lists remain available only through
authenticated HyperKitty.
