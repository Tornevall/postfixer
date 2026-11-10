# Postgrey local whitelists

Postgrey reads administrator additions from
`/etc/postgrey/whitelist_clients.local`. Keep package-owned defaults in
`whitelist_clients` unchanged.

The generic Postfixer installer does not select an external or site-specific
configuration tree. It backs up `/etc/postgrey` and `/etc/default/postgrey`,
then leaves existing regular files and symlinks intact.

Migration `--fetch` copies the content of the source
`/etc/postgrey/whitelist_clients.local`, following a symlink without importing
its host-specific target path. `--install-modular` stores the reviewed copy
below the migration import directory. If the target has no active local client
whitelist, the migration installs a regular file under `/etc/postgrey`. An
existing file or symlink always wins; differing imported rules remain staged
for manual review. Restart Postgrey after activating changed rules.

Postgrey client-domain entries match that domain and its subdomains. Prefer a
verified sending domain over recipient exceptions, because recipient entries
disable greylisting for every sender targeting that address.
