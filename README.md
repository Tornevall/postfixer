# Postfixer

Postfixer is a mail server customizer for Ubuntu.

The goal is not to ship one hard-coded `main.cf` for one machine. The goal is to replace the different Postfix server variants that have accumulated over the years with one reproducible installation system that can build either a complete inbound/outbound mail server or a relay helper from the same repository.

The old Tornevall mail servers contain Postfix, local Maildir delivery, Courier, SMTP AUTH, SpamAssassin, SPF policy checks, OpenDKIM, OpenDMARC, relay domains, transport maps, sender-dependent relays and outbound fallback relays. Postfixer is intended to replace those installations without requiring a different source tree for every server.

## Node roles

Postfixer currently supports two primary roles.

### `inout`

A complete inbound/outbound server.

This node is allowed to be the final destination for mail and contains the services needed for local Maildir users:

- Postfix SMTP.
- Local Maildir delivery.
- Cyrus SASL and `saslauthd` for SMTP AUTH.
- Courier IMAP, IMAPS, POP3 and POP3S.
- Courier PAM authentication against local Unix accounts.
- SpamAssassin and `spamc`.
- ClamAV.
- SPF policy checks.
- Postgrey.
- OpenDKIM signing and verification.
- OpenDMARC.
- Fetchmail and Procmail.
- Relay domains and transport maps when this server also has to forward selected domains elsewhere.
- Externally managed Let's Encrypt certificates from `/etc/letsencrypt`.

### `relay`

A relay helper or MX gateway.

A relay node must not become a final Maildir destination just because Postfix is installed on it. The role therefore disables local mail delivery and does not install or enable the Courier IMAP/POP services.

It still provides the parts that belong on the SMTP path:

- Postfix SMTP.
- Trusted-network relay control.
- Relay domains and transport maps.
- Outbound primary and fallback relay routing.
- SpamAssassin.
- ClamAV.
- SPF policy checks.
- Postgrey.
- OpenDKIM signing and verification.
- OpenDMARC.
- TLS for SMTP.

A relay node can therefore accept mail for configured relay domains and forward it to the final `inout` server without ever writing incoming user mail to a local Maildir.

## What happens when the recipient does not exist locally?

There are two different cases and Postfixer deliberately does not mix them.

### On a relay node

The domain is a relay domain, not a local destination.

The relay accepts mail for configured domains and forwards it according to its transport map. This is the normal design for a relay or backup MX host.

For Internet-facing relays, `relay_recipient_maps` should contain the valid recipient addresses from the final delivery server. Without recipient validation a relay can accept mail for bogus recipients and only discover the error after it has already accepted the message, which can create backscatter.

The files are:

```text
/etc/postfixer/relay-domains
/etc/postfixer/relay-recipients
/etc/postfixer/transport
```

Example:

```text
# /etc/postfixer/relay-domains
example.com
```

```text
# /etc/postfixer/relay-recipients
alice@example.com OK
bob@example.com OK
postmaster@example.com OK
```

```text
# /etc/postfixer/transport
example.com relay:[mail-primary.example.com]
```

### On an inout node

A local domain is final delivery by default.

If `alice@example.com` exists locally, it is delivered locally. If an address in the same local domain does not exist, Postfixer currently rejects it instead of silently forwarding every unknown recipient to another server.

Postfix can implement split delivery with `fallback_transport`, `fallback_transport_maps` or `luser_relay`, but that changes local recipient validation and needs to be configured deliberately. It is not enabled as a default because disabling recipient validation on an Internet-facing final server can produce backscatter.

If split delivery is needed later, it should be added as an explicit profile or feature with a known recipient source rather than being hidden inside the normal `inout` role.

## Server-specific configuration lives in `/etc/postfixer`

The same repository should be usable on `relay-1`, `relay-2`, an inbound server and a replacement machine.

Server identity and routing therefore live outside the repository Postfix configuration:

```text
/etc/postfixer/
|-- postfixer.conf
|-- networks
|-- local-domains
|-- relay-domains
|-- relay-recipients
`-- transport
```

The main node configuration looks like this:

```bash
POSTFIXER_ROLE=inout
POSTFIXER_HOSTNAME=mail.example.com
POSTFIXER_MAIL_DOMAIN=example.com

POSTFIXER_RELAYHOST=
POSTFIXER_FALLBACK_RELAYS=

POSTFIXER_CERT_DOMAIN=mail.example.com

POSTFIXER_NETWORKS_FILE=/etc/postfixer/networks
POSTFIXER_LOCAL_DOMAINS_FILE=/etc/postfixer/local-domains
POSTFIXER_RELAY_DOMAINS_FILE=/etc/postfixer/relay-domains
POSTFIXER_RELAY_RECIPIENTS_FILE=/etc/postfixer/relay-recipients
POSTFIXER_TRANSPORT_FILE=/etc/postfixer/transport
POSTFIXER_DKIM_DIR=/etc/opendkim
```

An example is included as `etc-postfixer/postfixer.conf.example`.

If `/etc/postfixer/postfixer.conf` does not exist, an interactive installation creates it.

## Hostname and SMTP identity

The hostname that Postfix presents in SMTP is a property of the node, not of the shared `main.cf`.

Postfixer therefore stores the desired hostname in:

```text
/etc/postfixer/postfixer.conf
```

For example:

```bash
POSTFIXER_HOSTNAME=relay-1.example.com
```

The installer applies it as the system hostname. An explicit `myhostname` setting is removed from `/etc/postfix/main.cf`, allowing Postfix to use its normal system-FQDN based `$myhostname` value.

The generic banner can therefore remain identical everywhere:

```text
smtpd_banner = $myhostname ESMTP $mail_name
```

`POSTFIXER_MAIL_DOMAIN` is written to `/etc/mailname` and used as the node's default mail domain.

## Primary relays and fallback relays

Relay routing is also node-specific.

A server must never point at itself as its primary or fallback relay. Postfixer validates this when it loads the node configuration.

Example for `relay-1.example.com`:

```bash
POSTFIXER_HOSTNAME=relay-1.example.com
POSTFIXER_RELAYHOST='[relay-2.example.com]:587'
POSTFIXER_FALLBACK_RELAYS='[relay-3.example.com]:587 [relay-4.example.com]:587'
```

The configuration source remains `/etc/postfixer/postfixer.conf`. Postfixer materializes the values into the active Postfix runtime configuration after the shared repository configuration has been applied.

The primary outbound route becomes Postfix `relayhost` and the fallback list becomes `smtp_fallback_relay`.

These settings are for ordinary outbound SMTP delivery. Relay domains for which the server acts as an MX or gateway should use `/etc/postfixer/transport` to reach their final server.

That distinction is important. A backup MX should queue mail when its final server is unavailable rather than blindly looping the message through another MX node.

## Trusted networks

Trusted relay clients are defined in:

```text
/etc/postfixer/networks
```

Postfix uses the file directly through:

```text
mynetworks = /etc/postfixer/networks
```

The file can contain IPv4 addresses, IPv4 networks and IPv6 entries. IPv6 values may use the bracket notation expected by Postfix.

Example:

```text
127.0.0.0/8
[::1]/128
10.0.0.0/8
172.16.0.0/12
192.168.0.0/16
```

Do not treat this file as a generic allowlist. An address in `mynetworks` is trusted to relay mail through Postfix.

## OpenDKIM on every SMTP node

OpenDKIM is enabled for both `inout` and `relay` profiles.

The migrated configuration model uses:

```text
KeyTable        /etc/opendkim/key.table
SigningTable    refile:/etc/opendkim/signing.table
ExternalIgnoreList /etc/opendkim/trusted.hosts
InternalHosts   /etc/opendkim/trusted.hosts
Mode            sv
Socket          inet:18891@localhost
```

Postfixer configures both Postfix milter paths:

```text
smtpd_milters = inet:127.0.0.1:18891
non_smtpd_milters = inet:127.0.0.1:18891
```

`Mode sv` means the same OpenDKIM process can sign mail that qualifies as internal/originating mail and verify mail arriving from external systems.

The trusted host file is generated from the node identity and `/etc/postfixer/networks`.

DKIM tables and keys live under:

```text
/etc/opendkim/
|-- key.table
|-- signing.table
|-- trusted.hosts
`-- keys/
```

Private keys are not committed to this repository. Existing keys from an old server must be migrated separately. Postfixer normalizes private key permissions to `0600` and the key directory to a restricted OpenDKIM-owned directory.

## Spam, SPF and mail policy

Spam and authentication policy belongs on every SMTP entry/relay point, not only on the final Maildir server.

Both profiles install the common policy stack:

- SpamAssassin and `spamc`.
- ClamAV.
- Postgrey.
- `postfix-policyd-spf-python`.
- OpenDKIM.
- OpenDMARC.

The shared Postfix configuration can then define the exact content-filter path and policy order once for all nodes. Existing server-specific Postfix configuration can still be placed in `etc-postfix/` while the old setup is migrated into the common profile.

## Existing Postfix installations

Postfixer can be used both on an empty server and during migration.

If this file exists:

```text
/etc/postfix/main.cf
```

Postfixer assumes that Postfix already exists and treats the machine as an existing installation. The configuration is backed up before customization.

If `/etc/postfix/main.cf` does not exist, Postfix is installed as part of the mail stack before the customizer applies its profile.

This allows the same installer to be used when rebuilding an existing mail server and when starting from a clean Ubuntu installation.

## Repository configuration versus node configuration

`etc-postfix/` contains configuration that should be common and version controlled.

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

It is deliberately separate from `/etc/postfix` because a fresh machine may not have Postfix installed yet.

The order is:

```text
install packages
    -> create /etc/postfix if needed
    -> apply etc-postfix/
    -> apply /etc/postfixer/postfixer.conf node settings
    -> rebuild maps
    -> validate
    -> restart/reload services
```

This means a shared `main.cf` can be checked into Git while node-specific hostname and relay routing still differ between servers.

## Supported Ubuntu releases

Release handlers currently exist for:

- Ubuntu 18.04 LTS.
- Ubuntu 20.04 LTS.
- Ubuntu 22.04 LTS.
- Ubuntu 24.04 LTS.

18.04 and 20.04 are legacy releases and require working package repositories or Ubuntu ESM where applicable.

Ubuntu 24.04 does not normally provide `courier-imap` and `courier-pop` binary packages in the standard archive. The `inout` profile therefore contains a Courier source-package fallback for Noble. The `relay` profile skips Courier entirely.

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
|   |-- 18.04.sh
|   |-- 20.04.sh
|   |-- 22.04.sh
|   |-- 24.04.sh
|   `-- saslauthd-prepare.sh
|-- etc-postfix/
|   `-- README.md
`-- etc-postfixer/
    |-- postfixer.conf.example
    |-- networks.example
    |-- local-domains.example
    |-- relay-domains.example
    |-- relay-recipients.example
    `-- transport.example
```

## Installation

Clone the repository:

```bash
git clone https://github.com/Tornevall/postfixer.git
cd postfixer
sudo make install
```

On the first installation, Postfixer asks for:

- Node role: `inout` or `relay`.
- SMTP/server hostname.
- Default mail domain.
- Optional primary outbound relay.
- Optional fallback outbound relays.
- Certificate domain under `/etc/letsencrypt/live`.

The result is stored in `/etc/postfixer/postfixer.conf` so subsequent runs are repeatable.

Before changing an existing mail configuration, Postfixer creates a timestamped backup under `/root/postfixer-backup-*`.

## Example: complete inbound/outbound server

```bash
POSTFIXER_ROLE=inout
POSTFIXER_HOSTNAME=mail-primary.example.com
POSTFIXER_MAIL_DOMAIN=example.com
POSTFIXER_RELAYHOST='[relay-1.example.com]:587'
POSTFIXER_FALLBACK_RELAYS='[relay-2.example.com]:587'
POSTFIXER_CERT_DOMAIN=mail-primary.example.com
```

Local final-delivery domains are placed in:

```text
/etc/postfixer/local-domains
```

Courier and SMTP AUTH are enabled.

## Example: relay helper

```bash
POSTFIXER_ROLE=relay
POSTFIXER_HOSTNAME=relay-1.example.com
POSTFIXER_MAIL_DOMAIN=example.com
POSTFIXER_RELAYHOST='[relay-2.example.com]:587'
POSTFIXER_FALLBACK_RELAYS='[relay-3.example.com]:587'
POSTFIXER_CERT_DOMAIN=relay-1.example.com
```

A relayed domain is then routed to the final server:

```text
# /etc/postfixer/relay-domains
example.com
```

```text
# /etc/postfixer/transport
example.com relay:[mail-primary.example.com]
```

The node keeps an SMTP queue but does not become a Maildir destination.

## Certificates

Postfixer does not obtain Let's Encrypt certificates locally.

Certificates are expected under:

```text
/etc/letsencrypt/live/DOMAIN/fullchain.pem
/etc/letsencrypt/live/DOMAIN/privkey.pem
```

The certificate is produced or renewed on another server and synchronized here.

`POSTFIXER_CERT_DOMAIN` selects the certificate used by the current node.

On an `inout` server, `make cert` also creates the combined Courier PEM files atomically and restarts Courier only when their contents changed.

## Make targets

| Target | Function |
| --- | --- |
| `make install` | Install/customize the selected mail server role. |
| `make apply` | Apply `etc-postfix/`, reapply node settings, rebuild maps, validate and reload Postfix. |
| `make maps` | Rebuild configured Postfix `hash:` maps. |
| `make aliases` | Rebuild aliases and reload Postfix. |
| `make cert` | Apply the externally managed TLS certificate. |
| `make check` | Check Postfix and services appropriate for the configured role. |
| `make restart` | Restart services appropriate for the configured role and run checks. |
| `make reload` | Validate and reload Postfix. |

The map builder reads the active Postfix configuration. `hash:` maps are rebuilt with `postmap`, alias maps use `postalias`, and `regexp:` maps are not blindly hashed.

## Authentication flows on an `inout` node

SMTP authentication:

```text
Postfix -> Cyrus SASL -> saslauthd -> PAM -> local Unix accounts
```

IMAP and POP3 authentication:

```text
Courier -> authpam -> PAM -> local Unix accounts
```

The saslauthd socket is placed inside the Postfix chroot:

```text
/var/spool/postfix/var/run/saslauthd/mux
```

A `relay` node does not enable this local user authentication stack by default. Relay permission is based on its trusted networks and configured relay destinations.

## Courier configuration

Courier is only required by the `inout` role.

Postfixer detects known Courier configuration layouts including:

```text
/etc/courier
/usr/lib/courier-imap/etc
/usr/lib/courier/etc
```

When `.dist` files and `sysconftool` are available, Courier's own configuration upgrade mechanism is used.

## Useful checks

```bash
sudo make check
postconf -n
postfix check
```

Manual SASL test on an `inout` server:

```bash
testsaslauthd \
  -f /var/spool/postfix/var/run/saslauthd/mux \
  -u USERNAME \
  -p PASSWORD
```

Service inspection:

```bash
systemctl status postfix opendkim opendmarc postgrey
journalctl -u postfix -u opendkim -u opendmarc -u postgrey
```

For an `inout` server, also inspect:

```bash
systemctl status saslauthd courier-imap courier-authdaemon
```

## Migration notes

The old server tree contains more than `main.cf` and `master.cf`. It also contains relay-domain lists, recipient maps, transport rules, virtual aliases, sender-dependent relay maps, SpamAssassin piping and DKIM tables.

Those pieces should be migrated by purpose instead of copied blindly:

- Node identity and primary/fallback relay routing -> `/etc/postfixer/postfixer.conf`.
- Trusted relay networks -> `/etc/postfixer/networks`.
- Final local domains -> `/etc/postfixer/local-domains`.
- Relay domains -> `/etc/postfixer/relay-domains`.
- Valid relay recipients -> `/etc/postfixer/relay-recipients`.
- Node/domain transport routing -> `/etc/postfixer/transport` or shared `etc-postfix/transport`.
- Generic Postfix rules -> `etc-postfix/`.
- DKIM tables and keys -> `/etc/opendkim`, with private keys migrated outside Git.

This is how Postfixer can replace the old inbound/outbound server and the relay helpers without turning every node into a local mailbox server.

## Related older documentation

- [The postfix-Maildir guide](https://www.tornevalls.se/the-postfix-maildir-guide/)
- [Postfix smtpauth and clients without imap/pop-auth](https://www.tornevalls.se/postfix-smtpauth-and-clients-without-imap-pop-auth/)

Those articles describe older generations of the setup that Postfixer is intended to replace.
