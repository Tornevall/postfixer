#!/bin/bash
# Separate Tornevall mail backup for Postfix/Courier servers.
# Maildirs and mail configuration are independent from file and SQL backups.

set -u
PATH="$PATH:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin"
me=$(hostname)
etcpath=/var/tornevall/system/etc
defaultbackupstore="$etcpath/default-backup-store"
backupremote=play.tornevall.net
backupstorebase=/mnt/SuperStore

if [[ -f "$defaultbackupstore" ]]; then
    mapfile -t storeconfig < <(grep -v '^[[:space:]]*$' "$defaultbackupstore")
    [[ -n "${storeconfig[0]:-}" ]] && backupremote="${storeconfig[0]}"
    [[ -n "${storeconfig[1]:-}" ]] && backupstorebase="${storeconfig[1]%/}"
fi

for flag in nobackup nobackup.mail; do
    if [[ -f "/etc/firewall/${me}/${flag}" || -f "$etcpath/firewall/${me}/${flag}" ]]; then
        echo "No mail backup allowed for this host."
        exit 0
    fi
done

force=0
dryrun=0
[[ "${1:-}" == -forcebackup ]] && force=1
[[ "${1:-}" == --dry-run ]] && dryrun=1
currentdate=$(date +%Y%m%d)
timestamp=$(date +%Y%m%d-%H%M%S)
backupdir="$backupstorebase/Backup/Auto/$me/mail"
lastfile="$etcpath/backups/$me/last.mail"
localtmp="/data/backup/$me/mail"

mkdir -p "$(dirname "$lastfile")"
if [[ "$force" != 1 && -f "$lastfile" && "$(head -n 1 "$lastfile")" == "$currentdate" ]]; then
    echo "Mail backup already completed today for $me."
    exit 0
fi

list=$(mktemp)
configlist=$(mktemp)
cleanup() { rm -f "$list" "$configlist"; }
trap cleanup EXIT
find /home -mindepth 2 -maxdepth 2 -type d -name Maildir -printf '%h\n' 2>/dev/null |
    sed 's#^/##' | sort -u > "$list"

if [[ ! -s "$list" ]]; then
    echo "No /home/*/Maildir accounts found; refusing to create an empty mail backup."
    exit 1
fi

for path in \
    /etc/postfix /etc/courier /etc/courier-imap /etc/opendkim /etc/spamassassin \
    /etc/pam.d/smtp /etc/default/saslauthd /etc/mailname /etc/passwd /etc/group \
    /etc/shadow /etc/gshadow /etc/letsencrypt; do
    [[ -e "$path" || -L "$path" ]] && printf '%s\n' "${path#/}" >> "$configlist"
done

mailtar="$localtmp/${me}-mail-${timestamp}.tar"
configtar="$localtmp/${me}-mail-config-${timestamp}.tar"
mkdir -p "$localtmp"
if [[ "$dryrun" == 1 ]]; then
    echo "DRY RUN: would archive $(wc -l < "$list") Maildir account(s) to $backupdir"
    exit 0
fi

tar -C / -cf "$mailtar" --numeric-owner --acls --xattrs --files-from="$list" || exit 1
tar -C / -cf "$configtar" --numeric-owner --acls --xattrs --ignore-failed-read --files-from="$configlist" || exit 1
xz -T0 -ev "$mailtar" "$configtar" || exit 1
chmod 0600 "$mailtar.xz" "$configtar.xz"

if [[ -d "$backupstorebase" ]]; then
    mkdir -p "$backupdir"
    mv "$mailtar.xz" "$configtar.xz" "$backupdir/"
else
    ssh "root@$backupremote" "mkdir -p '$backupdir'" || exit 1
    scp -C "$mailtar.xz" "$configtar.xz" "root@$backupremote:$backupdir/" || exit 1
    rm -f "$mailtar.xz" "$configtar.xz"
fi

printf '%s\n' "$currentdate" > "$lastfile"
chmod 0600 "$lastfile"
echo "Mail backup completed for $me: $backupdir"
