# Postfixer

Postfixer is a mail server customizer for Ubuntu.

The purpose is to replace several generations of hand-built Postfix servers with one reproducible installer that can customize either a complete inbound/outbound mail server or a relay helper from the same repository.

Postfixer was created primarily for personal operational use: migrating the author's existing long-running mail server to a modern Ubuntu server without losing its local users, Maildirs, Courier access, relay topology or established delivery behavior. The project is published and structured generically so that others can reuse the same approach, but its migration-first design reflects that original need. Every administrator should review imported domains, users, trusted networks, routes and credentials before using it in production.

See [CHANGELOG.md](CHANGELOG.md) for the complete release history and current known limitations.

It is not intended to ship one server-specific `main.cf`. Shared Postfix configuration belongs in Git. Node identity, relay routing, trusted networks and role-specific settings belong under `/etc/postfix/postfixer.d`.

## What Postfixer is intended to replace

The previous mail stack contains, depending on server role:

- Postfix for inbound and outbound SMTP.
- Local Maildir delivery.
- Cyrus SASL and `saslauthd` for SMTP AUTH.
- Courier IMAP, IMAPS, POP3 and POP3S.
- PAM authentication against local Unix accounts.
- SpamAssassin and `spamc`.
- ClamAV.
- SPF policy checks.
- Postgrey.
- OpenDKIM signing and verification.
- OpenDMARC.
- Relay domains and recipient maps.
- Transport maps.
- Primary and fallback outbound relays.
- Externally managed Let's Encrypt certificates.
- Certbot when available from the Ubuntu package repositories.

Postfixer is meant to install and normalize that stack instead of assuming that the target machine already has a working Postfix configuration.

## Node roles

### `inout` (recommended hybrid server)

A complete inbound/outbound mail server and final Maildir destination. This is the default hybrid role: it delivers local user mail and can also relay selected non-local domains.

It provides:

- SMTP on port 25.
- Authenticated message submission on port 587.
- Mandatory STARTTLS on port 587.
- Cyrus SASL through `saslauthd` and PAM.
- Local Unix account authentication.
- Local Maildir delivery.
- Courier IMAP/POP services.
- SPF, Postgrey and OpenDKIM processing, plus installed SpamAssassin, ClamAV and OpenDMARC services ready for explicit filter wiring.
- Relay and transport support for selected non-local domains.

### `relay`

A relay helper, gateway or backup MX.

It provides:

- SMTP and SMTP queueing.
- Authenticated message submission on port 587.
- Mandatory STARTTLS on port 587.
- Cyrus SASL through `saslauthd` and PAM.
- Local Unix account authentication for SMTP AUTH.
- Trusted-network relay control.
- Relay domains and transport maps.
- Valid-recipient maps for public relay domains.
- SPF, Postgrey and OpenDKIM processing, plus installed SpamAssassin, ClamAV and OpenDMARC services ready for explicit filter wiring.
- Primary and fallback outbound routing.

It does not become a final mailbox server. Local Maildir delivery and Courier IMAP/POP are disabled.

A relay may queue mail while the final server is unavailable. That is normal Postfix queueing and is different from delivering the message into a local Maildir.

## Relay-to-relay versus message submission

Port 587 is for authenticated message submission from mail clients.

Normal Postfix-to-Postfix traffic between trusted relay nodes should normally use port 25. For example:

```bash
POSTFIXER_HOSTNAME=relay-1.example.com
POSTFIXER_RELAYHOST='[relay-2.example.com]'
POSTFIXER_FALLBACK_RELAYS='[relay-3.example.com] [relay-4.example.com]'
```

The receiving relay permits trusted servers through `/etc/postfix/postfixer.d/networks`.

A relay domain for which the node is an MX should be routed with `relay_domains` and a transport map instead of being confused with the ordinary outbound `relayhost` path:

```text
# /etc/postfix/postfixer.d/relay-domains
example.com
```

```text
# /etc/postfix/postfixer.d/transport
example.com relay:[mail-primary.example.com]
```

This keeps backup MX behavior separate from ordinary outbound fallback routing.

## Recipient handling

### Relay nodes

A relay does not check whether a recipient is a local Unix account. The domain is not local on that node.

Internet-facing relay nodes should synchronize valid recipients from the final delivery server into:

```text
/etc/postfix/postfixer.d/relay-recipients
```

Example:

```text
alice@example.com OK
bob@example.com OK
postmaster@example.com OK
```

This prevents the relay from accepting mail for arbitrary non-existent recipients and discovering the failure only after the message has already been accepted.

### Inout nodes

A domain listed as local is final delivery by default.

Known local recipients are delivered to Maildir. Unknown local recipients are rejected. Postfixer does not silently forward every unknown local address to another host.

Split delivery can be added later with an explicit recipient source and `fallback_transport_maps` or equivalent routing. It is not enabled as a default.

## Server-specific configuration

Node-specific settings live in:

```text
/etc/postfix/postfixer.d/postfixer.conf
```

Example:

```bash
POSTFIXER_ROLE=inout
POSTFIXER_HOSTNAME=mail-primary.example.com
POSTFIXER_MAIL_DOMAIN=example.com
POSTFIXER_RELAYHOST='[relay-1.example.com]'
POSTFIXER_FALLBACK_RELAYS='[relay-2.example.com]'
POSTFIXER_CERT_DOMAIN=mail-primary.example.com

POSTFIXER_NETWORKS_FILE=/etc/postfix/postfixer.d/networks
POSTFIXER_LOCAL_DOMAINS_FILE=/etc/postfix/postfixer.d/local-domains
POSTFIXER_RELAY_DOMAINS_FILE=/etc/postfix/postfixer.d/relay-domains
POSTFIXER_RELAY_RECIPIENTS_FILE=/etc/postfix/postfixer.d/relay-recipients
POSTFIXER_TRANSPORT_FILE=/etc/postfix/postfixer.d/transport
POSTFIXER_DKIM_DIR=/etc/opendkim
```

The related data files are:

```text
/etc/postfix/
|-- main.cf
|-- master.cf
|-- samples-postfixer/
`-- postfixer.d/
    |-- postfixer.conf
    |-- networks
    |-- local-domains
    |-- relay-domains
    |-- relay-recipients
    `-- transport
```

If `/etc/postfix/postfixer.d/postfixer.conf` is missing, the first interactive installation creates it.
Non-interactive installation refuses to continue until the file exists.

Trusted Postfix relay networks are managed through `POSTFIXER_NETWORKS_FILE`, which defaults to `/etc/postfix/postfixer.d/networks`. The default contains loopback only. Add trusted application hosts and relay nodes explicitly. Existing `/etc/postfixer` data is migrated automatically on the first run.

Postfix does not support a general `include main.d/*.cf` directive for arbitrary `main.cf` fragments. Postfixer therefore keeps list and map data modular through `/etc/postfix/postfixer.d` file references, while scalar `main.cf` values and `master.cf` services are applied with `postconf`. Imported fragments remain inactive until they are reviewed and connected to a specific Postfix parameter.

## Hostname and SMTP identity

Server identity must not be hard-coded in the shared `main.cf`.

`POSTFIXER_HOSTNAME` is applied as the system hostname. Postfixer removes an explicit `myhostname` assignment from `/etc/postfix/main.cf`, allowing Postfix to derive `$myhostname` from the system FQDN.

`POSTFIXER_HOSTNAME`, `POSTFIXER_MAIL_DOMAIN` and `POSTFIXER_CERT_DOMAIN` must all be fully qualified domain names. If the installer cannot safely detect a host FQDN during the first interactive run, it asks the installer to enter one instead of writing a guessed short hostname or `localdomain` value. Existing config files are validated the same way before changes are applied.

A shared banner can therefore remain:

```text
smtpd_banner = $myhostname ESMTP $mail_name
```

`POSTFIXER_MAIL_DOMAIN` is written to `/etc/mailname`.

Postfixer also refuses a node configuration where the configured primary or fallback relay resolves to the same hostname as the node itself.

## Existing Postfix installation or clean server

Postfixer supports both.

No existing Postfix or Postfixer configuration is required for an interactive installation on a clean Ubuntu server. `sudo make install-server` or `sudo make install-relay` creates the node configuration from the answers, installs the packages, keeps the package-generated base files and applies the answers to the active Postfix configuration with `postconf`.

The administrator still needs a resolvable FQDN, correct DNS planning and an externally managed TLS certificate. A hybrid mailbox server also needs local Unix users, created fresh or migrated with their Maildirs. Old `main.cf`, `master.cf` or Postfixer files are optional migration sources, not prerequisites.

If this exists:

```text
/etc/postfix/main.cf
```

Postfixer treats the machine as an existing installation, backs it up and reapplies the managed configuration. Old SASL, submission and TLS settings are not assumed to be correct just because Postfix was already installed.

If `/etc/postfix/main.cf` does not exist, Postfix is installed first and then customized.

Backups are written below:

```text
/root/postfixer-backup-*
```

They include Postfix, Courier, SASL/PAM and SpamAssassin rules and daemon defaults. Ubuntu 24.04 installs the daemon from its separate `spamd` package; older supported Ubuntu releases may provide it through `spamassassin` itself.

### How installer answers update Postfix

The installer does not generate a host-specific `main.cf` template. It stores node answers below `/etc/postfix/postfixer.d` and updates the package-generated `/etc/postfix/main.cf` safely through `postconf`:

| Installer answer | Stored or applied as | Active Postfix setting |
| --- | --- | --- |
| Hybrid or relay role | `POSTFIXER_ROLE` | Local delivery, recipient checks and role-specific services |
| SMTP/server hostname | System FQDN | Postfix `$myhostname` default and SMTP banner |
| Default mail domain | `/etc/mailname` and `local-domains` for hybrid | `myorigin` and `mydestination` |
| Primary outbound relay | `POSTFIXER_RELAYHOST` | `relayhost` |
| Fallback outbound relays | `POSTFIXER_FALLBACK_RELAYS` | `smtp_fallback_relay` |
| Certificate domain | `POSTFIXER_CERT_DOMAIN` | SMTP certificate/key paths and submission TLS |
| Trusted relay networks | `postfixer.d/networks` | `mynetworks` |
| Non-local relay domains | `postfixer.d/relay-domains` | `relay_domains` |
| Final host for relay domains | `postfixer.d/transport` | `transport_maps` |

The installer also manages submission and policy services in `master.cf` with `postconf -M` and `postconf -P`. Re-running `make apply` reapplies the stored answers without requiring the interactive questions again.

## SMTP submission and SASL

This area is deliberately managed instead of inherited from an old installation.

The authentication path on both `inout` and `relay` nodes is:

```text
Postfix submission :587
    -> Cyrus SASL
    -> saslauthd
    -> PAM
    -> local Unix account
```

The saslauthd socket is placed inside the Postfix chroot:

```text
/var/spool/postfix/var/run/saslauthd/mux
```

Postfixer also creates the SMTP PAM service:

```text
/etc/pam.d/smtp
```

Cyrus uses:

```text
/etc/postfix/sasl/smtpd.conf
```

with:

```text
pwcheck_method: saslauthd
mech_list: PLAIN LOGIN
```

Old `DIGEST-MD5`, `CRAM-MD5` or accidental socket-path values in `smtpd_sasl_path` are not preserved. With Cyrus SASL, `smtpd_sasl_path` is the application name `smtpd`; Cyrus itself communicates with the saslauthd mux socket.

### Port 25

Port 25 is for SMTP transport.

Postfixer keeps TLS opportunistic there and disables SMTP AUTH globally. Relay permission comes from trusted networks, accepted destination classes and the normal Postfix relay restrictions.

### Port 587

Both roles create and manage the `submission` service in `master.cf`.

It requires:

- STARTTLS.
- TLS before AUTH is advertised or accepted.
- Cyrus SASL.
- `PLAIN` and `LOGIN` only inside the encrypted TLS session.
- Successful SASL authentication before relaying.
- DKIM milter processing for originating authenticated mail.

The effective service is equivalent to:

```text
submission inet n - y - - smtpd
  -o smtpd_tls_security_level=encrypt
  -o smtpd_tls_auth_only=yes
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_sasl_type=cyrus
  -o smtpd_sasl_path=smtpd
  -o smtpd_sasl_security_options=noanonymous
  -o smtpd_sasl_tls_security_options=noanonymous
  -o smtpd_relay_restrictions=permit_sasl_authenticated,reject
  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING
```

A valid externally synchronized TLS certificate is mandatory before the submission service is enabled. The installer fails closed instead of exposing a half-working authentication service.

## TLS policy

Certificates are not issued by Postfixer.

They are expected under:

```text
/etc/letsencrypt/live/DOMAIN/fullchain.pem
/etc/letsencrypt/live/DOMAIN/privkey.pem
```

Another server may run Certbot and synchronize `/etc/letsencrypt` to this node. `/etc/letsencrypt` may also be a symlink to a shared tree, for example `/var/tornevall/system/etc/letsencrypt`, as long as `/etc/letsencrypt/live/DOMAIN/fullchain.pem` and `/etc/letsencrypt/live/DOMAIN/privkey.pem` are readable on the mail node.

`POSTFIXER_CERT_DOMAIN` selects the node certificate.

Postfixer installs Certbot when it is available from the Ubuntu package repositories, but it does not automatically request or replace certificates during mail-stack installation.

Postfixer disables SSLv2, SSLv3, TLS 1.0 and TLS 1.1 in its managed SMTP TLS policy. Submission requires encrypted SMTP before authentication.

On an `inout` server, `make cert` also rebuilds the combined Courier PEM files atomically and only restarts Courier when the certificate content changes.

## OpenDKIM

OpenDKIM is configured on both roles.

For the author's existing Tornevall server only, the node configuration may opt
into reusing the external OpenDKIM tree:

```text
POSTFIXER_USE_TORNEVALL_OPENDKIM=yes
POSTFIXER_TORNEVALL_OPENDKIM_DIR=/var/tornevall/system/etc/opendkim
```

This is deliberately disabled by default and must not be enabled for generic
installations or administrators who manage their own `/etc/opendkim`. When it is
enabled, the installer backs up an existing directory and creates the symlink
`/etc/opendkim` to the configured external tree.

The migrated model uses:

```text
KeyTable          /etc/opendkim/key.table
SigningTable      refile:/etc/opendkim/signing.table
ExternalIgnoreList /etc/opendkim/trusted.hosts
InternalHosts     /etc/opendkim/trusted.hosts
Mode              sv
Socket            inet:18891@localhost
```

Postfixer configures:

```text
smtpd_milters = inet:127.0.0.1:18891
non_smtpd_milters = inet:127.0.0.1:18891
```

`Mode sv` allows the same filter to sign qualifying internal/authenticated originating mail and verify external mail.

DKIM private keys are not stored in Git. Existing keys must be migrated separately. Postfixer normalizes migrated `*.private` files to mode `0600`.

## Spam and policy processing

Both roles install the SMTP policy stack:

- SpamAssassin and `spamc`.
- ClamAV.
- Postgrey.
- `postfix-policyd-spf-python`.
- OpenDKIM.
- OpenDMARC.

SPF, Postgrey and OpenDKIM are wired into Postfix. SpamAssassin is also wired into Postfix by default through a managed `spamassassin` pipe service. `spamd` runs locally on `127.0.0.1:783`, so filtering does not require an external SpamAssassin host. Both inbound SMTP and authenticated submission are filtered.

The node setting `POSTFIXER_SPAMD_HOSTS` defaults to `127.0.0.1`. Optional failover hosts can follow as a comma-separated list, for example:

```bash
POSTFIXER_SPAMD_HOSTS=127.0.0.1,spamd-backup.example.com
```

The managed Postfix pipe runs `spamc` with safe fallback (`-f`). It tries the configured hosts and, if no `spamd` can filter the message, returns the original message for normal delivery instead of rejecting or losing it. If the pipe process or Postfix reinjection itself fails, Postfix defers the message in its queue for retry. Filtering failure therefore does not intentionally block mail, but monitoring should alert because messages may pass through unfiltered.

Site-specific rules, Razor identities, Bayes databases and SQL credentials belong under `/etc/spamassassin` or another root-controlled external tree, never in Git. Installations migrated from SpamAssassin 3 must run `spamassassin --lint` on the target version: removed plugins such as Hashcash must be disabled or ported before activation.

ClamAV and OpenDMARC are installed, while their complete message-body integration remains separate migration work. OpenDKIM, SPF and Postgrey are already active in the SMTP path.

## Shared repository configuration

Shared Postfix files belong in:

```text
etc-postfix/
```

For example:

```text
etc-postfix/
|-- main.cf
|-- master.cf
|-- aliases
|-- header_checks
|-- virtual/
|-- transport
`-- sasl/
```

The installation order is:

```text
install packages if needed
    -> create /etc/postfix
    -> apply etc-postfix/
    -> apply /etc/postfix/postfixer.d node settings
    -> normalize TLS/SASL/submission
    -> configure OpenDKIM
    -> rebuild maps
    -> validate
    -> restart services
    -> run role-specific checks
```

## Supported Ubuntu releases

Release handlers currently exist for:

- Ubuntu 18.04 LTS.
- Ubuntu 20.04 LTS.
- Ubuntu 22.04 LTS.
- Ubuntu 24.04 LTS.

18.04 and 20.04 are legacy releases and require usable package repositories or Ubuntu ESM where applicable.

The `inout` handler for Ubuntu 24.04 includes a Courier package-build fallback when the required Courier IMAP/POP binary packages are unavailable. Relay nodes do not need Courier.

## Repository layout

```text
postfixer/
|-- Makefile
|-- README.md
|-- WP.md
|-- bin/
|   |-- install.sh
|   |-- common.sh
|   |-- customizer.sh
|   |-- submission.sh
|   |-- 18.04.sh
|   |-- 20.04.sh
|   |-- 22.04.sh
|   |-- 24.04.sh
|   `-- saslauthd-prepare.sh
|-- etc-postfix/
|   `-- README.md
|-- samples-postfixer/
|   |-- README.md
|   |-- main.cf.example
|   `-- master.cf.example
`-- etc-postfixer/
    |-- postfixer.conf.example
    |-- networks.example
    |-- local-domains.example
    |-- relay-domains.example
    |-- relay-recipients.example
    `-- transport.example
```

## Installation

Before installation, place a valid certificate at:

```text
/etc/letsencrypt/live/MAIL-HOST/fullchain.pem
/etc/letsencrypt/live/MAIL-HOST/privkey.pem
```

Install the recommended hybrid user server:

```bash
git clone https://github.com/Tornevall/postfixer.git
cd postfixer
sudo make install-server
```

Install a relay without Courier IMAP/POP with `sudo make install-relay`. Run plain `make` to show all available targets.

After installation, verify the selected role and the complete live mail stack:

```bash
sudo make status
sudo make check
```

The check must pass before the server is placed in DNS or receives production traffic. For a hybrid server, create or migrate the local Unix accounts that own `/home/USER/Maildir`; the same accounts authenticate through Courier and SMTP submission. Review `/etc/postfix/postfixer.d/networks` before allowing applications or other servers to relay.

The first interactive installation asks for:

- Server identity and role (`install-server` defaults to `inout`; `install-relay` defaults to `relay`).
- SMTP/server hostname as an FQDN.
- Default mail domain as an FQDN.
- Optional primary outbound relay.
- Optional fallback outbound relays.
- Certificate domain as an FQDN.
- Trusted relay networks/IPs to seed `/etc/postfix/postfixer.d/networks`.
- Optional relay domains and final delivery host for the hybrid server.
- Relay domains and their final delivery host when installing a relay.

## Make targets

| Target | Function |
| --- | --- |
| `make` | Show help without changing the system. |
| `make install-server` | Install the hybrid Maildir/Courier user server. |
| `make install-relay` | Install a relay without Courier IMAP/POP. |
| `make install` | Choose the role interactively. |
| `make apply` | Reapply repository and node configuration, rebuild maps and reload Postfix. |
| `make maps` | Rebuild active Postfix `hash:` maps. |
| `make aliases` | Rebuild aliases and reload Postfix. |
| `make cert` | Apply the externally managed TLS certificate. |
| `make check` | Validate the active role, services, TLS and submission configuration. |
| `make status` | Show the configured role and service state. |
| `make restart` | Restart role-specific services and run checks. |
| `make reload` | Validate and reload Postfix. |
| `make purge` | Back up and purge the managed mail stack after explicit confirmation. |

The map builder reads the active Postfix configuration. `hash:` maps use `postmap`, aliases use `postalias`, and `regexp:` maps are not blindly hashed.

## What `make check` verifies

For both `inout` and `relay` nodes, the checks include:

- `postfix check`.
- Required services are active.
- The `policyd-spf` service exists in `master.cf`.
- SpamAssassin configuration passes `spamassassin --lint`.
- Local `spamd` is active on `127.0.0.1:783` and its Postfix pipe exists.
- Cyrus SASL is compiled into Postfix.
- The saslauthd mux socket exists inside the Postfix chroot.
- The submission service exists in `master.cf`.
- Port 587 is listening.
- Port 587 advertises STARTTLS before encryption.
- Port 587 does not advertise AUTH before STARTTLS.
- Port 587 advertises both `AUTH PLAIN` and `LOGIN` after STARTTLS.
- Submission relay restrictions require authenticated SASL users.

This is intended to catch the common case where packages are installed but the actual SMTP service still cannot authenticate or relay.

Manual backend authentication can also be tested with:

```bash
testsaslauthd \
  -f /var/spool/postfix/var/run/saslauthd/mux \
  -s smtp \
  -u USERNAME \
  -p PASSWORD
```

## Full reset

For repeated test installs, Postfixer includes a destructive reset helper:

```bash
POSTFIXER_RESET_CONFIRM=purge-mail-stack sudo make purge
```

The reset creates a backup below:

```text
/root/postfixer-reset-backup-*
```

It backs up and removes managed mail configuration and runtime state such as `/etc/postfix`, the legacy `/etc/postfixer`, `/etc/courier`, SASL/PAM mail files, Postfix runtime directories and Postfixer Courier staging trees. It purges the installed mail packages used by Postfixer.

It does not remove `/home`, externally managed `/etc/letsencrypt`, or the Git checkout such as `/root/postfixer`.

## Migration notes

The old mail-server tree contains more than `main.cf` and `master.cf`.

Migration should be done by function:

- Node identity and primary/fallback routing -> `/etc/postfix/postfixer.d/postfixer.conf`.
- Trusted relay networks -> `/etc/postfix/postfixer.d/networks`.
- Final local domains -> `/etc/postfix/postfixer.d/local-domains`.
- Relay domains -> `/etc/postfix/postfixer.d/relay-domains`.
- Valid relay recipients -> `/etc/postfix/postfixer.d/relay-recipients`.
- Domain transport routing -> `/etc/postfix/postfixer.d/transport`.
- Generic Postfix rules -> `etc-postfix/`.
- DKIM tables and keys -> `/etc/opendkim`, with private keys kept outside Git.

Remaining migration work includes the exact SpamAssassin/content-filter path, virtual alias rules, sender-dependent relay maps and any other site-specific maps from the previous server.

An example migration runner is available at:

```bash
examples/migrations/import-postfix-server.sh
```

Set the remote source explicitly. Data is staged below `/root/postfixer-migration/postfix-import` by default. A safe migration sequence is:

Remote imports require a passwordless SSH session through a public key or an unlocked SSH agent. The importer enables OpenSSH `BatchMode=yes`, so it fails instead of waiting for a password prompt. Configure the key and accept the remote host key before starting, for example:

```bash
# Run ssh-keygen once if root does not already have an SSH identity.
sudo ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519
sudo ssh-copy-id -i /root/.ssh/id_ed25519.pub root@old-mail.example.com
sudo ssh -o BatchMode=yes root@old-mail.example.com true
```

Run the verification as the same local account that runs the migration. When the migration runs through `sudo`, place the identity in root's SSH configuration or preserve a suitable agent with `sudo --preserve-env=SSH_AUTH_SOCK`. The remote account must be able to read `/etc/postfix`, all mailbox directories and, for account export, the shadow database.

Mailbox discovery scans every `/home/*/Maildir` directory, including empty Maildirs, but imports only directories whose parent path exactly matches a real account's home-directory field in `passwd`. This also handles accounts where the username and home-directory basename differ. Unrelated system accounts and orphaned Maildir directories are excluded. If a server stores home directories elsewhere, set `REMOTE_HOME_ROOT`, for example `sudo make import-users REMOTE=root@old-mail.example.com REMOTE_HOME_ROOT=/srv/home`, and use the same value for `make import-mail`.

### Password and account migration

Both Courier and SMTP AUTH use PAM against the target server's local Unix accounts. `make import-users` therefore stages the matching source entries as root-only files:

```text
/root/postfixer-migration/postfix-import/passwd.maildir-users
/root/postfixer-migration/postfix-import/shadow.maildir-users
/root/postfixer-migration/postfix-import/group.maildir-users
/root/postfixer-migration/postfix-import/maildir-paths.tsv
```

A password reset is normally not required when the original shadow password hash is installed on the new account. Preserve the username, UID, primary GID, home directory and shell when creating the target account, then preserve its complete shadow entry or encrypted password hash. Keeping UID/GID values aligned also keeps the transferred Maildir ownership correct.

Postfixer also exports the primary group records required by those GIDs. It does not copy supplementary group memberships, which avoids silently carrying old administrative privileges such as `sudo` to the new server. Add any genuinely required supplementary memberships only after review.

Postfixer deliberately does not overwrite `/etc/passwd`, `/etc/group` or `/etc/shadow` automatically. Review UID/GID conflicts, required groups, locked accounts, password expiry fields and hash compatibility on the new Ubuntu release before merging account data. Hashes beginning with `!` or `*` remain locked, and old or unsupported hash formats may require a password reset. The staged account files are mode `0600`, remain outside Git and must be deleted securely after migration.

```bash
sudo make import-fetch REMOTE=root@old-mail.example.com
sudo make import-users REMOTE=root@old-mail.example.com
sudo make import-mail REMOTE=root@old-mail.example.com
sudo make import-config
```

The normal Maildir step is a read-only pre-sync from the old server and uses resumable `rsync -aHAX --numeric-ids --partial` transfers over the same passwordless SSH session for each exported user. It does not delete files from staging, and the old server may remain live while this first large copy runs. Configuration and mail are staged outside Git. Modular map files are installed below `/etc/postfix/postfixer.d/imports`; credentials, `main.cf`, `master.cf`, private keys and generated databases are not activated automatically.

### Final cutover without lost mail

Do not perform the final account and Maildir import while the old server can still accept delivery or mailbox changes. Complete the installation and pre-sync first. During the short cutover window:

1. Stop Postfix and every Courier IMAP/POP service on the old server.
2. Verify that the old services are inactive and ports 25, 110, 143, 465, 587, 993 and 995 no longer accept connections.
3. Run the confirmed final Maildir sync. This adds `rsync --delete`, so staging becomes an exact copy of the frozen source.
4. Import the reviewed accounts and staged Maildirs on the new server, then validate ownership, authentication, SMTP, IMAP and POP.
5. Change MX only after the new server passes validation. Remote senders should retry while the old primary is stopped; also verify how any secondary MX queues and forwards mail.

Example source freeze and final sync:

```bash
# On the old server. Adjust Courier unit names if that installation differs.
sudo systemctl stop postfix courier-imap courier-imap-ssl courier-pop courier-pop-ssl
sudo systemctl is-active postfix courier-imap courier-imap-ssl courier-pop courier-pop-ssl

# On the new server, only after the old services have been verified inactive.
sudo make import-mail-final \
  REMOTE=root@old-mail.example.com \
  MIGRATION_NAME=postfix-import \
  FINAL_SYNC_CONFIRM=source-frozen
```

`import-mail-final` refuses to run without the exact confirmation value. Do not restart mail services on the old server after this point unless the migration is deliberately rolled back. MX is a separate, final operation and is never changed by the importer.

### Production migration runbook

This is the complete recommended sequence for replacing an existing mailbox server. Commands use `old-mail.example.com` and `mail-new.example.com` as placeholders. Keep the old server authoritative until the explicit freeze step.

#### Phase 1: prepare the target without changing MX

1. Create and verify the target A, AAAA and matching PTR records. Do not change MX yet.
2. Install a certificate that covers the final SMTP/IMAP hostname.
3. Clone Postfixer on the target and install the hybrid profile:

   ```bash
   sudo make install-server
   ```

4. Review `/etc/postfix/postfixer.d/postfixer.conf`, local domains, relay domains, relay recipients, transports, trusted networks and DKIM material.
5. Apply and verify the base server:

   ```bash
   sudo make apply
   sudo make restart
   sudo make check
   ```

6. If custom SpamAssassin rules, SQL preferences, Bayes storage, Razor or Pyzor are used, keep credentials and identities outside Git, link or copy them below `/etc/spamassassin`, and require a clean target-version lint:

   ```bash
   sudo spamassassin --lint
   printf 'From: test@example.net\nTo: test@example.net\nSubject: SA test\n\nTest.\n' |
     sudo spamc -c -d 127.0.0.1
   ```

7. Test SMTP, STARTTLS, AUTH, IMAP/POP and certificates directly against the target address or a temporary hosts-file entry. The production MX still points to the old server.

#### Phase 2: inventory and pre-sync while the source remains live

1. Configure passwordless root SSH or equivalent read access and verify `BatchMode=yes`.
2. Stage configuration, filtered account records and Maildirs outside Git:

   ```bash
   sudo make import-fetch \
     REMOTE=root@old-mail.example.com \
     MIGRATION_NAME=production-mail

   sudo make import-users \
     REMOTE=root@old-mail.example.com \
     MIGRATION_NAME=production-mail

   sudo make import-mail \
     REMOTE=root@old-mail.example.com \
     MIGRATION_NAME=production-mail
   ```

3. Review `passwd.maildir-users`, `shadow.maildir-users`, `group.maildir-users` and `maildir-paths.tsv` as root. Confirm that every imported account owns a real Maildir and that no unrelated system account is included.
4. Check every username, UID, primary GID and home path against `getent passwd` and `getent group` on the target. Resolve every collision before creating accounts.
5. Back up `/etc/passwd`, `/etc/group`, `/etc/shadow` and `/etc/gshadow`. Create missing primary groups and users with the staged numeric IDs, homes and shells. Install the staged encrypted password hashes without putting plaintext passwords on a command line. Preserve compatible shadow aging fields where required.
6. Do not overwrite an existing administrative account blindly. If an existing target account already has the same UID/GID/home but a different password hash, explicitly choose which password must remain valid.
7. Pre-copy staged Maildirs into their final target homes with numeric ownership preserved. Do not use `--delete` against final homes while the source remains live. Users and delivery must still use the old server at this stage.
8. Repeat `make import-mail` as needed; it is resumable and copies only deltas. Confirm adequate free space for both secure staging and final `/home` data.

#### Phase 3: freeze the old server

Schedule a short maintenance window. Immediately before the freeze, confirm that the target server, account plan, DNS records, certificate, filters and rollback backup are ready.

1. Stop Postfix and all Courier IMAP/POP services on the old server:

   ```bash
   sudo systemctl stop postfix courier-imap courier-imap-ssl courier-pop courier-pop-ssl
   ```

2. Verify that the source is inactive and no longer accepts mailbox changes:

   ```bash
   sudo systemctl is-active postfix courier-imap courier-imap-ssl courier-pop courier-pop-ssl
   sudo ss -lntp | grep -E ':(25|110|143|465|587|993|995)( |$)' || true
   ```

3. Also verify externally that the old address no longer accepts those ports. Remote SMTP senders should retry; understand how every secondary MX queues mail during the window.
4. Do not restart the old mail services unless deliberately rolling back.

#### Phase 4: final exact import

1. Refresh the frozen account export one last time:

   ```bash
   sudo make import-users \
     REMOTE=root@old-mail.example.com \
     MIGRATION_NAME=production-mail
   ```

2. Run the guarded final Maildir delta. This is the only source-sync action that uses `rsync --delete`:

   ```bash
   sudo make import-mail-final \
     REMOTE=root@old-mail.example.com \
     MIGRATION_NAME=production-mail \
     FINAL_SYNC_CONFIRM=source-frozen
   ```

3. Apply any final account changes, encrypted hashes and shadow aging fields.
4. Copy the exact staged Maildirs into the corresponding target home directories with `rsync -aHAX --numeric-ids --delete`. Use `maildir-paths.tsv` and the staged passwd home field rather than assuming the username equals the home-directory basename.
5. Verify account count, Maildir count, file count, numeric ownership, home permissions and available disk space.

`make import-mail-final` performs step 4 automatically. It resolves each target
home from the local passwd database, synchronizes the exact Maildir below that
home and applies the target user's UID/GID to the Maildir directory. The target
root can be changed with `TARGET_HOME_ROOT` and defaults to `/home`. Ownership
is applied recursively to the complete Maildir tree so migrated files and
Courier folders remain writable by the mailbox user.

#### Phase 5: validate before changing MX

1. Run:

   ```bash
   sudo make check
   sudo postqueue -p
   sudo spamassassin --lint
   ```

2. Test a migrated login through SMTP AUTH and IMAP/POP without exposing the password in process arguments or logs.
3. Deliver test messages through port 25 and submission, confirm Maildir delivery, SpamAssassin headers, DKIM signing/verification and outbound routing.
4. Confirm that local `spamd` is primary, any remote `spamd` is only failover, and mail still passes unfiltered if every `spamd` is intentionally stopped for the test.
5. Confirm the final hostname, forward DNS, reverse DNS, SMTP banner and certificate names.

#### Completed migration example: inbound.tornevall.net

The migration from `inbound-1` was completed with the following result:

- The target was installed as a hybrid Postfix/Courier server and renamed to `inbound.tornevall.net`.
- 24 Maildir-backed accounts were imported; discovery was restricted to users with a matching `/home/*/Maildir`.
- Maildirs were pre-synced while the source remained live, then the source Postfix and Courier services were stopped and masked.
- The final exact sync copied all 24 Maildirs into the target users' `/home` directories. A second rsync dry-run found zero differences and zero ownership errors.
- The target `make check` passed, SMTP port 25 returned the `inbound.tornevall.net` banner, and the target Postfix queue was empty.
- The old server retained six deferred outbound requests (16 KiB total). They were not deleted or mixed into the mailbox import.
- The authoritative MX changed from `inbound-1.tornevall.net` to `inbound.tornevall.net`; `smtp4.tornevall.net` remained the priority-20 secondary MX.
- Reverse DNS for `212.63.208.4` was changed to `inbound.tornevall.net` without changing MX before cutover.

The migration was performed by the importer and shell administration commands,
but the procedure above is the reproducible operator-facing description. Future
migrations must repeat the domain-map, queue, account-password and validation
reviews because source systems differ.

#### Phase 6: change MX last

1. Change MX only after all target checks pass. The importer never changes DNS.
2. Monitor authoritative DNS, target Postfix logs, queue depth, rejections, authentication, Courier and filtering.
3. Keep the old server frozen and intact during the rollback window. Drain or trigger any secondary-MX queue after the new primary is reachable.

#### Rollback and cleanup

- Before the new server has accepted mail, rollback can restart the old services and leave MX unchanged or restore the previous MX.
- After the new server has accepted mail, do not simply restart the old server. Freeze the new server first and reconcile its newly delivered mail back to the old server, otherwise the rollback loses messages.
- Keep `/root/postfixer-backup-*` and `/root/postfixer-migration/<name>` until account, mail, authentication, queue and DNS validation are complete.
- Staging contains password hashes, legacy configuration and possibly credentials. Remove it securely after the retention window, and rotate any credential that was exposed during migration or stored in old configuration.

## Related older documentation

- [The postfix-Maildir guide](https://www.tornevalls.se/the-postfix-maildir-guide/)
- [Postfix smtpauth and clients without imap/pop-auth](https://www.tornevalls.se/postfix-smtpauth-and-clients-without-imap-pop-auth/)

Those articles describe older generations of the setup that Postfixer is intended to replace.
