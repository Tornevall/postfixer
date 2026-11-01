# Postfixer reference samples

These files are inert references installed below `/etc/postfix/samples-postfixer`.
Postfix does not load them automatically. Active node data belongs below
`/etc/postfix/postfixer.d`, while Postfixer applies managed `main.cf` and
`master.cf` settings with `postconf`.

Never copy credentials, private keys, generated database files or host-specific
identity from an old server into these samples.
