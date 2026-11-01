# The new Postfix Maildir all-in-one solution

Time flies, and what worked back then definitely does not work now - especially when the original instructions were already missing details that later had to be covered in additional posts.

The first version of this setup was documented in [The postfix-Maildir guide](https://www.tornevalls.se/the-postfix-maildir-guide/) in 2019. It got the basic Postfix, Maildir, Courier, SpamAssassin, SPF, DKIM and DMARC stack running, but it was not the whole story.

One of the things that happened after the first document was that SMTP authentication needed its own follow-up: [Postfix smtpauth and clients without imap/pop-auth](https://www.tornevalls.se/postfix-smtpauth-and-clients-without-imap-pop-auth/).

So now I am doing it again.

This time the goal is not another collection of commands that happens to work on one server. The goal is a complete Postfix mail-server customizer that can reproduce the different roles I have been using over the years.

The same installer should be able to build either:

- A complete inbound/outbound server with local Maildir delivery, Courier and authenticated SMTP submission.
- A relay helper or backup MX that can queue and forward mail without ever becoming a local Maildir destination.

The project is called [Postfixer](https://github.com/Tornevall/postfixer).

## One installer, different mail-server roles

The complete server uses Postfix for inbound and outbound SMTP, Courier for IMAP and POP, Cyrus SASL for authenticated message submission, SpamAssassin, ClamAV, SPF policy checks, Postgrey, OpenDKIM and OpenDMARC.

Relay helpers use the same SMTP filtering and signing stack, but they do not need Courier or local mailbox delivery. If the final server is unavailable, mail may stay in the Postfix queue until delivery is possible again. It should not disappear into a local Maildir on a relay machine.

Server-specific settings also no longer belong in a shared `main.cf`. Hostname, trusted networks, relay routing and certificate identity are stored under `/etc/postfix/postfixer.d` and applied by the customizer.

That means `relay-1` can use `relay-2` as an outbound helper without forcing a separate copy of the entire Postfix configuration for every host.

## SMTP AUTH should not be another follow-up article

One of the recurring problems with the older setup was that installing SASL packages did not automatically mean SMTP AUTH was actually usable.

A working setup needs the whole chain:

```text
Postfix submission :587
    -> Cyrus SASL
    -> saslauthd
    -> PAM
    -> local Unix account
```

It also needs a real submission service in `master.cf`, a working saslauthd socket inside the Postfix chroot and the correct PAM service.

Postfixer manages that instead of assuming an old configuration is still valid.

Port 587 requires STARTTLS. AUTH is not advertised before encryption and only `PLAIN` and `LOGIN` are offered inside the encrypted session. Those mechanisms are appropriate here because the password is protected by TLS and `saslauthd` supports them against the local authentication backend.

The ordinary SMTP service on port 25 does not become an end-user authentication service just because the full server supports SMTP AUTH. Port 25 remains SMTP transport, while port 587 is message submission.

This also fixes an old configuration trap: with Cyrus SASL, Postfix `smtpd_sasl_path` is the SASL application name `smtpd`. It is not the path to the saslauthd mux socket. Cyrus reads `smtpd.conf` and communicates with saslauthd separately.

The installer also validates the result. It checks that port 587 is listening, advertises STARTTLS before encryption, does not advertise AUTH before STARTTLS and offers `AUTH PLAIN` and `LOGIN` after TLS has been established.

## Relay servers are not mailbox servers

A relay helper can accept mail for configured relay domains and forward it to the final delivery server.

For public-facing MX relays, valid recipients should be synchronized from the final server. Otherwise a backup MX can accept mail for recipients that do not exist and discover the problem too late.

That is separate from local delivery.

On the final inbound/outbound server, known local users are delivered to Maildir. Unknown local recipients are rejected by default. If I later need split delivery, where some addresses in the same domain live elsewhere, that should be a deliberate routing feature rather than a side effect of disabling recipient checks.

## Relay-to-relay traffic is not submission

Another distinction that is easy to lose in one large `main.cf` is the difference between server-to-server relaying and user submission.

Port 587 is for authenticated mail clients.

Trusted Postfix relay nodes normally talk to each other over SMTP on port 25. Their relay permission comes from the trusted network configuration and the domains they are allowed to relay.

A relay domain can then be routed to the final server with Postfix transport rules. This keeps backup MX traffic separate from the ordinary outbound relay and fallback path.

## DKIM, SPF and spam handling belong on the SMTP path

Spam filtering and authentication checks should not only happen on the machine that happens to contain the Maildir.

Both full servers and relay helpers can process SpamAssassin, ClamAV, SPF, Postgrey, DKIM and DMARC before the message continues through the system.

OpenDKIM runs in signing and verification mode. Trusted or authenticated originating mail can be signed, while external mail can be verified. Existing DKIM private keys are migrated separately and are not stored in the repository.

## Certificates are managed elsewhere

Postfixer does not run Certbot on every mail server.

Certificates are issued or renewed elsewhere and synchronized into `/etc/letsencrypt` on the mail nodes.

The selected node certificate is then used by Postfix and, on a full server, converted into the combined PEM format Courier requires.

The submission service fails closed if its certificate is missing. A server should not appear successfully installed while authenticated SMTP is actually unusable or sending credentials without the intended TLS protection.

## Ubuntu versions

The installer currently has handlers for Ubuntu 18.04, 20.04, 22.04 and 24.04.

The older releases are there because old mail servers do not magically disappear just because a new LTS is released. The installer separates release-specific package handling from the shared mail-stack configuration so an old server can be migrated without turning every Ubuntu difference into another copy of the installer.

Ubuntu 24.04 also needs special handling for Courier when the expected IMAP/POP packages are not available directly from the configured archive.

## The point this time

The old guides were useful, but the setup grew beyond them. SMTP AUTH alone became a second article, and server-local fixes accumulated after that.

Postfixer is intended to make the installer itself carry that knowledge.

A clean machine should be able to become a complete mail server. An existing Postfix machine should be backed up and normalized instead of being trusted simply because `/etc/postfix/main.cf` already exists. A relay helper should remain a relay helper. TLS and authentication should be tested as part of the installation rather than discovered as broken when a mail client gets "Relay access denied".

There will still be configuration that is specific to my environment - domains, networks, DKIM keys and routing destinations - but those values now have a defined place outside the shared Postfix configuration.

That is the part the old installation never really had.
