# Postfixer

Postfixer is an installer and configuration scaffold for a Postfix Maildir server on Ubuntu.

The project is a replacement for the older Tornevall Postfix Maildir setup. Its purpose is to make the complete mail stack reproducible instead of spreading required fixes across several old guides and server-local scripts.

## What it installs

The installer prepares:

- Postfix for SMTP and local mail transport.
- Cyrus SASL and `saslauthd` for authenticated SMTP against local Unix accounts.
- Courier IMAP, IMAPS, POP3, and POP3S.
- Courier PAM authentication against local Unix accounts.
- SpamAssassin and `spamc`.
- ClamAV.
- SPF policy support.
- Postgrey.
- OpenDKIM and OpenDMARC.
- Fetchmail and Procmail.
- Postfix hash maps and aliases.
- Courier TLS deployment from certificates already synchronized to `/etc/letsencrypt`.

Certbot is intentionally not run by Postfixer. In this environment certificates are issued or renewed elsewhere and synchronized to this server under `/etc/letsencrypt`.

## Supported Ubuntu releases

The installer currently has release handlers for:

- Ubuntu 18.04 LTS.
- Ubuntu 20.04 LTS.
- Ubuntu 22.04 LTS.
- Ubuntu 24.04 LTS.

18.04 and 20.04 are legacy releases and require working package repositories or Ubuntu ESM where applicable.

Ubuntu 24.04 does not normally provide `courier-imap` and `courier-pop` binary packages in the standard archive. Its release handler therefore contains a source-package fallback for Courier.

## Repository layout

```text
postfixer/
|-- Makefile
|-- README.md
|-- WP.md
|-- bin/
|   |-- install.sh
|   |-- common.sh
|   |-- 18.04.sh
|   |-- 20.04.sh
|   |-- 22.04.sh
|   |-- 24.04.sh
|   `-- saslauthd-prepare.sh
`-- etc-postfix/
    `-- README.md
```

`etc-postfix/` is deliberately separate from `/etc/postfix`. A new server does not need Postfix to be installed before this repository is cloned.

The installer installs Postfix first. Configuration files placed in `etc-postfix/` can then be copied into `/etc/postfix` with `make apply`.

## Installation

Clone the repository and run:

```bash
git clone https://github.com/Tornevall/postfixer.git
cd postfixer
sudo make install
```

The installer detects the Ubuntu release and loads the matching script from `bin/`.

Before changing existing mail configuration it creates a timestamped backup under `/root/postfixer-backup-*`.

## Authentication flows

SMTP authentication:

```text
Postfix -> Cyrus SASL -> saslauthd -> PAM -> local Unix accounts
```

IMAP and POP3 authentication:

```text
Courier -> authpam -> PAM -> local Unix accounts
```

The `postfix` user is added to the `sasl` group and the saslauthd socket is placed inside the Postfix chroot at:

```text
/var/spool/postfix/var/run/saslauthd/mux
```

## Courier configuration

Postfixer does not assume that Courier always uses `/etc/courier`.

It detects known Courier configuration layouts, including:

```text
/etc/courier
/usr/lib/courier-imap/etc
/usr/lib/courier/etc
```

When `.dist` configuration templates and `sysconftool` are available, Courier's own upgrade mechanism is used. Otherwise a missing active configuration file can be initialized from its `.dist` template.

The shared folder index is created below the detected Courier configuration directory as `shared/index`.

## Certificates

Postfixer does not obtain Let's Encrypt certificates locally.

Certificates are expected under:

```text
/etc/letsencrypt/live/DOMAIN/fullchain.pem
/etc/letsencrypt/live/DOMAIN/privkey.pem
```

`make cert` validates the certificate and private key, builds Courier PEM files atomically, and only restarts Courier when the PEM content changed.

The certificate domain is resolved in this order:

1. `CERT_DOMAIN` environment variable.
2. The domain in Postfix `smtpd_tls_cert_file` when it points into `/etc/letsencrypt/live/`.
3. The server FQDN.

Example:

```bash
sudo make cert CERT_DOMAIN=mail.example.com
```

After an external certificate synchronization job completes, it can simply call `make cert` in this repository.

## Make targets

| Target | Function |
| --- | --- |
| `make install` | Install and configure the complete mail stack. |
| `make apply` | Apply `etc-postfix/`, rebuild maps, validate and reload Postfix. |
| `make maps` | Rebuild configured Postfix `hash:` maps. |
| `make aliases` | Rebuild aliases and reload Postfix. |
| `make cert` | Deploy the externally managed certificate to Courier. |
| `make check` | Check Postfix, services, SASL socket and listening mail ports. |
| `make restart` | Restart installed mail services and run checks. |
| `make reload` | Validate and reload Postfix. |

The hash-map builder reads the active Postfix configuration. `hash:` maps are rebuilt with `postmap`, while alias maps use `postalias`. `regexp:` and other lookup types are not blindly hashed.

## Adding your Postfix configuration

Place the configuration tree under `etc-postfix/` and run:

```bash
sudo make apply
```

For example:

```text
etc-postfix/
|-- main.cf
|-- master.cf
|-- aliases
|-- access-inbound
|-- header_checks
|-- transport
|-- virtual_domains
`-- sasl/
    `-- smtpd.conf
```

Sensitive data should stay outside Git or be injected through a separate deployment mechanism.

## Useful checks

```bash
sudo make check
postconf -n
postfix check
```

Manual SASL test:

```bash
testsaslauthd \
  -f /var/spool/postfix/var/run/saslauthd/mux \
  -u USERNAME \
  -p PASSWORD
```

Service inspection:

```bash
systemctl status postfix saslauthd courier-imap courier-authdaemon
journalctl -u postfix -u saslauthd -u courier-imap -u courier-authdaemon
```

## Related older documentation

- [The postfix-Maildir guide](https://www.tornevalls.se/the-postfix-maildir-guide/)
- [Postfix smtpauth and clients without imap/pop-auth](https://www.tornevalls.se/postfix-smtpauth-and-clients-without-imap-pop-auth/)

Those articles describe the older server generations that Postfixer is intended to replace.
