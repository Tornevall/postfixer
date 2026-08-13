# etc-postfix

This directory is the repository-side source for Postfix configuration.

Postfixer installs the Ubuntu Postfix package first. The package-generated `/etc/postfix` is therefore allowed to exist before anything from this directory is applied.

Add real configuration files here when they are ready, for example:

```text
etc-postfix/
|-- main.cf
|-- master.cf
|-- aliases
|-- header_checks
|-- transport
|-- virtual_domains
`-- sasl/
    `-- smtpd.conf
```

`sudo make apply` copies the directory tree into `/etc/postfix`, rebuilds referenced `hash:` maps, validates Postfix, and reloads the service.

`README.md` and `.gitkeep` are never copied into `/etc/postfix`.

Do not commit private keys, SASL passwords, API tokens, or other credentials to this repository.
