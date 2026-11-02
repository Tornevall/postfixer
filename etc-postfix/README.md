# Shared Postfix configuration

This directory is the repository-side source for Postfix files that should be common across mail nodes.

A fresh server does not need Postfix installed before this repository is cloned. `make install` installs Postfix first when `/etc/postfix/main.cf` does not exist, then applies this tree.

Server-specific identity and routing do not belong here. Configure those under `/etc/postfix/postfixer.d/` instead.

Typical shared files may include:

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

The managed customizer reapplies node-specific settings after this directory is copied into `/etc/postfix`.

Do not rely on old SMTP AUTH or submission settings in a copied `main.cf`, `master.cf` or `sasl/smtpd.conf`. Postfixer deliberately normalizes the active Cyrus SASL configuration and manages port 587 after this overlay is applied.

`sudo make apply` copies the directory tree into `/etc/postfix`, rebuilds referenced `hash:` maps, reapplies node and submission settings, validates Postfix, and reloads the service.

`make maps` is the canonical rebuild operation after changing virtual aliases,
transport routes or other hash-backed maps. `make check` verifies that active
map sources exist, generated `.db` files exist and are not older than their
sources. Plain list files such as
`virtual_alias_domains = /etc/postfix/postfixer.d/virtual/domains` intentionally
do not have a `.db` companion.

The installed `/etc/postfix/Makefile` is the single maintenance entry point for
local tools and future ToolsAPI integration:

```bash
sudo make -C /etc/postfix       # rebuild maps, validate and reload
sudo make -C /etc/postfix maps  # rebuild generated databases only
sudo make -C /etc/postfix check
```

Postfix does not watch these source files. Changes to `virtual/aliases`,
`/etc/aliases` or `transport` require the corresponding map rebuild; changes to
plain virtual-domain or regexp lists require a Postfix reload.

`README.md` and `.gitkeep` are never copied into `/etc/postfix`.

Do not commit passwords, private DKIM keys, private TLS keys, API tokens or other credentials to this repository.
