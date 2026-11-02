# Changelog

All notable changes to Postfixer are documented in this file.

## Unreleased

### Changed

- Added separate root-only configuration and Maildir backup commands through
  `bin/backup.sh` and `make backup`, `make backup-config` and `make backup-mail`.
  Backups preserve ownership, ACLs and extended attributes and include only
  `/home` accounts with a Maildir.
- Added the separate Tornevall-system mail backup runner for inbound hosts. It
  writes Maildir and mail-configuration archives below the existing backup
  store's `.../<host>/mail/` branch and has its own cron entry and completion
  marker, independent of file and SQL backups.
- Added active Postfix map validation: `make check` now detects missing or stale
  `hash:` databases and missing plain list files, while `make maps` remains the
  canonical rebuild operation after virtual-alias or transport changes.
- Added an installed `/etc/postfix/Makefile` for rebuilding aliases, virtual
  aliases and transport maps, validating the configuration and reloading
  Postfix. This is also the intended narrow maintenance entry point for the
  future ToolsAPI integration.
- Hardened OpenDKIM permission normalization for nested key directories and the
  `default.private` key, and documented the personal system-repository links
  used for OpenDKIM and SpamAssassin.
- Enabled the packaged SpamAssassin maintenance timer during installation when
  available. Signed generated rule data remains under `/var/lib/spamassassin`,
  while local configuration and Razor data remain versioned in the system repo.

- Added an explicit `POSTFIXER_ALLOW_PLAINTEXT_SUBMISSION=yes` compatibility
  switch for legacy SMTP clients that cannot use TLS on port 587. The default
  remains mandatory STARTTLS; the opt-in mode is documented as insecure and
  limited to authenticated submission. The migration importer can persist the
  reviewed exception and `make apply` can reproduce it on the target.

- Hardened OpenDKIM maintenance and migration handling: external trees and
  Git-restored keys are normalized to `opendkim:opendkim` with private keys at
  `0600` and tables at `0640`; `make check` now detects unsafe permissions and
  the migration report documents the required repair step.
- Documented that mailbox display names and delivery aliases do not change PAM
  login names; migrated IMAP/SMTP credentials must use the actual Unix account.
- Corrected the migrated SpamAssassin DNS resolver profile: retired or
  timeout-prone nameservers are excluded so DKIM/SPF/DMARC checks do not
  produce false `DKIM_INVALID` results after a 15-second DNS timeout.
- Kept the responsive site-local resolver at `62.171.175.28`, added the
  requested `5.75.250.68` and `95.216.170.246` resolvers, and removed public
  fallback resolvers from the personal SpamAssassin profile.
- Added authenticated SMTPS compatibility on port 465 with implicit TLS for
  older clients such as Outlook Express, while retaining STARTTLS submission
  on port 587 and keeping port 25 free of client authentication.
- Clarified clean-server installation and documented how every interactive node
  answer updates the active `main.cf`, `master.cf` or modular data files.
- Documented filtered `passwd`/`shadow` migration, password-hash preservation,
  UID/GID ownership requirements and the cases that still require a reset.
- Exported the primary group records required by migrated mailbox GIDs while
  deliberately excluding unreviewed supplementary and administrative groups.
- Fixed Maildir account discovery to match each directory against the account's
  `passwd` home field instead of assuming the directory basename is the username.
- Documented that Postfixer originated as a personal migration tool for an
  existing production mail server while remaining generic and reusable.
- Required passwordless SSH key or agent authentication for remote Postfix and
  Maildir imports. Import commands now use OpenSSH `BatchMode=yes` and fail
  instead of waiting for password input.
- Added `openssh-client` as an explicit installer dependency for SSH-backed
  configuration and Maildir migration.
- Documented SSH key setup, host-key initialization, root/sudo agent handling
  and the remote permissions required by account and Maildir migration.
- Changed mailbox discovery to include every `/home/*/Maildir`, including empty
  Maildirs, with an optional `REMOTE_HOME_ROOT` override for other layouts.
- Split Maildir transfer into a non-destructive pre-sync and an explicitly
  confirmed final sync. The final action refuses to run unless the source is
  declared frozen, then uses `rsync --delete` for an exact staged copy.
- Documented the source-service shutdown, port verification, final delta sync,
  target validation and last-step MX cutover sequence to avoid lost mail.
- Enabled a local loopback-only `spamd` and managed Postfix SpamAssassin pipe
  for inbound SMTP and authenticated submission on every installation.
- Added optional per-node SpamAssassin failover hosts while keeping local
  filtering as the default with no external spamd dependency.
- Added Razor, Pyzor, SPF and SQL Perl dependencies needed by migrated custom
  SpamAssassin profiles, plus lint and listener health checks.
- Included SpamAssassin rules and daemon defaults in pre-install/apply backups.
- Added Noble's separate `spamd` package and release-aware daemon/default-file
  handling while retaining compatibility with older Ubuntu packaging.
- Documented SpamAssassin fail-open behavior and the complete production
  replacement runbook from target preparation and pre-sync through source
  freeze, exact import, MX cutover, rollback and sensitive-data cleanup.
- Final Maildir imports now synchronize each staged mailbox into the matching
  target `/home` directory and apply the target user's ownership.
- Documented the completed `inbound-1` to `inbound.tornevall.net` migration,
  queue handling, verification results and MX/PTR cutover.
- Added an explicit opt-in Tornevall OpenDKIM tree link for the personal
  migration profile without changing generic installations.
- Final Maildir imports now recursively apply the target user's UID/GID to the
  complete Maildir tree, including Courier folders and message files.
- Added an opt-in Tornevall certificate-tree link so Postfix and Courier can
  use the externally synchronized `/var/tornevall/system/etc/letsencrypt` tree.
- Documented target-version SpamAssassin linting during migration, including
  deactivation/porting of removed plugins such as Hashcash and review of stale
  source-server DNS/trusted-network entries.
- Fixed the active migrated SpamAssassin profile by disabling its unavailable
  Hashcash plugin and removing the retired Bitbucket/DNS address; the clean lint
  result is now part of the cutover validation.

## 2026-11-01 - Initial working release candidate

This release collects all changes since the initial repository commit and
provides a tested installer for hybrid mailbox servers and relay-only nodes.

### Added

- Added a shared Ubuntu installer with release handlers for Ubuntu 18.04,
  20.04, 22.04 and 24.04.
- Added the default `inout` hybrid role for inbound/outbound SMTP, local Unix
  users, Maildir delivery, SMTP AUTH and optional relay domains.
- Added the `relay` role for SMTP queueing and routing without local Maildir,
  Courier IMAP or Courier POP services.
- Added interactive node configuration for hostname, mail domain, certificate
  domain, trusted networks, outbound relays, relay domains and final delivery
  hosts.
- Added role-aware package installation for Postfix, Cyrus SASL, Courier,
  Postgrey, SPF policy checks, OpenDKIM, OpenDMARC, SpamAssassin and ClamAV.
- Added a Ubuntu 24.04 Courier fallback using HTTPS Jammy packages, with a
  source-package build fallback when binary packages are unavailable.
- Added local Maildir delivery through Courier IMAP, IMAPS, POP3 and POP3S for
  hybrid servers.
- Added SMTP submission on port 587 with mandatory STARTTLS, Cyrus SASL,
  `saslauthd`, PAM and local Unix account authentication.
- Added managed TLS policy that disables SSLv2, SSLv3, TLS 1.0 and TLS 1.1.
- Added externally managed Let's Encrypt certificate support for Postfix and
  atomic Courier PEM deployment.
- Added OpenDKIM signing and verification configuration with node-specific key,
  signing and trusted-host tables outside Git.
- Added Postgrey and SPF policy checks, including the required `policyd-spf`
  service in `master.cf`.
- Added relay-domain, valid-recipient and transport-map support for relay and
  hybrid topologies.
- Added primary and fallback outbound relay routing with self-relay validation.
- Added configuration backups before installation, apply and destructive reset
  operations.
- Added an explicit destructive purge/reset workflow with confirmation.
- Added an intuitive Make interface for install, apply, maps, certificates,
  checks, status, restart, reload, purge, migration and tests.
- Added `/etc/postfix/postfixer.d` for active node-specific and dynamic data.
- Added `/etc/postfix/samples-postfixer` for inert generic `main.cf`,
  `master.cf` and data-file references.
- Added automatic migration from the legacy `/etc/postfixer` directory.
- Added materialization of migrated data symlinks so active Postfix data stays
  inside `/etc/postfix/postfixer.d`.
- Added a generic Postfix server importer that stages old `/etc/postfix`
  configuration outside Git and installs only reviewed modular map files.
- Added remote Maildir user discovery and secure `passwd`/`shadow` exports for
  mailbox migrations.
- Added resumable per-user Maildir transfers with
  `rsync -aHAX --numeric-ids --partial`.
- Added profile regression tests for hybrid and relay installs, Ubuntu 24.04
  Courier behavior, legacy migration, symlink materialization and secret-safe
  modular imports.
- Added runtime checks for Postfix, role-specific services, `policyd-spf`, the
  SASL chroot socket, submission configuration, STARTTLS and advertised AUTH
  mechanisms.
- Added a complete README installation, topology, migration, recovery and
  operation guide, plus an updated WordPress article draft.

### Changed

- Changed plain `make` to show help without modifying the system.
- Changed `install-server` to default to the recommended hybrid `inout` role
  and `install-relay` to default to the relay-only role.
- Changed node identity and routing to be applied with `postconf` instead of
  shipping one host-specific `main.cf`.
- Changed active dynamic paths from `/etc/postfixer` to
  `/etc/postfix/postfixer.d`.
- Changed the default trusted-network file to loopback only; application hosts,
  relay peers and private networks must be added explicitly.
- Changed relay-to-relay examples to use SMTP port 25 and reserved port 587 for
  authenticated client submission.
- Changed Courier installation and service startup to be role-aware so relay
  nodes do not install or run Courier IMAP/POP.
- Changed the migration command from the site-specific
  `import-mail01-postfix.sh` name to `import-postfix-server.sh`.
- Changed imported maps to remain inactive until explicitly reviewed and
  connected to a Postfix parameter.
- Changed installer and maintenance entry scripts to executable files.

### Fixed

- Fixed Ubuntu 24.04 relay installs incorrectly entering the Courier package or
  build path.
- Fixed missing `policyd-spf` service creation while the recipient restriction
  already referenced its private socket.
- Fixed fresh hybrid installs not seeding the configured local mail domain.
- Fixed fresh relay installs not seeding relay domains and transport routes.
- Fixed hybrid installs lacking an interactive way to add non-local relay
  domains and a final delivery host.
- Fixed Maildir user discovery depth for messages below
  `/home/USER/Maildir/{cur,new}`.
- Fixed the importer report, warning function, generic examples and activation
  notes.
- Fixed legacy external `networks` symlinks causing Postfix directory-boundary
  warnings after migration.
- Fixed submission checks that previously allowed packages to be installed
  without proving that TLS and SMTP AUTH actually worked.

### Security

- Refused non-interactive installs without an explicit node configuration.
- Required valid FQDN values for host, mail and certificate domains.
- Required a readable TLS certificate before enabling authenticated submission.
- Disabled SMTP AUTH globally on port 25 and enabled it only inside the
  TLS-required submission service.
- Limited SASL mechanisms to `PLAIN` and `LOGIN` over encrypted submission.
- Replaced broad RFC1918 relay trust defaults with loopback-only defaults.
- Kept DKIM private keys, TLS private keys, password hashes and SMTP relay
  credentials outside Git.
- Added `.gitignore` protection for generated Postfix databases, credentials,
  private keys and password files.
- Removed broad importer operations that could overwrite `/etc/postfix` or copy
  secrets into the repository.
- Restricted migration staging and account exports to root-only permissions.
- Validated imported usernames before constructing remote Maildir paths.

### Removed

- Removed the site-specific default remote hostname from the migration tool.
- Removed automatic repository overlay replacement from imported Postfix trees.
- Removed automatic replacement of the active `/etc/postfix` tree by imported
  configuration.
- Removed active RFC1918 relay networks from the generic example.

### Known limitations

- SpamAssassin, ClamAV and OpenDMARC packages and services are installed, but
  the legacy site-specific content-filter chain is not enabled by default.
- Imported virtual aliases, sender-dependent relay maps and other site-specific
  maps require manual review and explicit activation.
- Maildir transfers are staged outside Git; account creation and final restore
  remain deliberate administrator actions.
- Ubuntu 18.04 and 20.04 require working legacy repositories or Ubuntu ESM.
# 2026-11-02 — Optional Mailman 3 Suite

- Integrate optional Mailman selection into the normal installer and add list/
  membership/archive fetch, inventory and held/private per-list import to the
  canonical migration runner. Add regression coverage and a synthetic end-to-end
  import/privacy check; refuse existing-list replacement and serialize imports.

- Add opt-in Suite installation with isolated Python runtime, local PostgreSQL,
  Postorius/HyperKitty, nginx TLS, Core and background worker systemd units.
- Preserve existing host settings and Postfix maps; reapply list routing during
  normal Postfixer configuration and validate list recipients.
- Add focused safety/idempotence tests and read-only legacy Mailman staging.
- Document that historical memberships and archives require explicit recovery;
  installation alone does not migrate them or publish private archives.
- Verify public list/archive pages, loopback-only APIs and real LMTP routing;
  pin the tested dependency set (including SQLAlchemy <2.1 compatibility),
  preserve host configuration byte-for-byte on reinstall and bootstrap the
  selected domain without creating lists or administrator passwords.


## 2026-11-02: Preserve legacy list posting domains

- Allow an explicit MAILMAN_TARGET_DOMAIN during reviewed imports, retaining
  original addresses for installations with more than one list domain.

## 2026-11-02: Reviewed historical public archives

- Preserve an explicit public-archive directory marker across reinstall; render
  a read-only Pipermail alias only for a reviewed directory below /var/www,
  with directory listing and symlink access disabled. Add path-isolation tests.
