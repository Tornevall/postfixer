# Shared Postfix configuration

This directory is the repository-side source for Postfix files that should be common across mail nodes.

A fresh server does not need Postfix installed before this repository is cloned. `make install` installs Postfix first when `/etc/postfix/main.cf` does not exist, then applies this tree.

Server-specific identity and routing do not belong here. Configure those under `/etc/postfixer/` instead.

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

`README.md` and `.gitkeep` are never copied into `/etc/postfix`.

Do not commit passwords, private DKIM keys, private TLS keys, API tokens or other credentials to this repository.
