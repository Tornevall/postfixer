#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d /tmp/postfixer-postgrey-test.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
log() { :; }
warn() { printf '%s\n' "$*" >&2; }
die() { fail "$@"; }

source "${ROOT_DIR}/bin/postgrey.sh"

source_rules="$tmp/source/whitelist_clients.local"
active_rules="$tmp/etc/postgrey/whitelist_clients.local"
mkdir -p "$(dirname "$source_rules")"
printf '# Canonical SMTP relays used by Launchpad.\ncanonical.com\n' > "$source_rules"
export POSTFIXER_POSTGREY_WHITELIST_CLIENTS="$active_rules"

# A neutral target gets a regular local file and repeat runs preserve it.
install_postgrey_client_whitelist "$source_rules"
[[ -f "$active_rules" && ! -L "$active_rules" ]] || fail "neutral whitelist was not installed"
cmp "$active_rules" "$source_rules"
install_postgrey_client_whitelist "$source_rules"

# An externally managed link is preserved, even when imported rules differ.
rm "$active_rules"
shared_rules="$tmp/shared/whitelist_clients.local"
mkdir -p "$(dirname "$shared_rules")"
cp "$source_rules" "$shared_rules"
ln -s "$shared_rules" "$active_rules"
install_postgrey_client_whitelist "$source_rules"
[[ "$(readlink "$active_rules")" == "$shared_rules" ]] || fail "external whitelist link was replaced"
printf 'different.example\n' > "$source_rules"
install_postgrey_client_whitelist "$source_rules" 2> "$tmp/preserve.warning"
grep -qx 'canonical.com' "$active_rules" || fail "external whitelist content was overwritten"
grep -q 'Preserving active Postgrey client whitelist' "$tmp/preserve.warning" || fail "difference warning missing"

# A broken custom link must fail closed.
rm "$active_rules"
ln -s "$tmp/missing" "$active_rules"
if (install_postgrey_client_whitelist "$source_rules") 2>/dev/null; then
    fail "broken Postgrey whitelist link was accepted"
fi

# Migration fetch dereferences the source link and modular install respects the target link.
rm "$active_rules"
mkdir -p "$tmp/mock-bin"
cat > "$tmp/mock-bin/ssh" <<'EOF_SSH'
#!/usr/bin/env bash
case "$*" in
    *'/etc/postgrey/whitelist_clients.local'*) cat "$POSTGREY_FIXTURE" ;;
    *) : ;;
esac
EOF_SSH
cat > "$tmp/mock-bin/rsync" <<'EOF_RSYNC'
#!/usr/bin/env bash
exit 0
EOF_RSYNC
cat > "$tmp/mock-bin/postconf" <<'EOF_POSTCONF'
#!/usr/bin/env bash
printf '\n'
EOF_POSTCONF
chmod +x "$tmp/mock-bin/"*
export PATH="$tmp/mock-bin:$PATH"
export POSTGREY_FIXTURE="$shared_rules"
export REMOTE=root@source.example.test
export STAGING_DIR="$tmp/staging"
export IMPORT_TARGET="$tmp/imported"
importer="$ROOT_DIR/examples/migrations/import-postfix-server.sh"

bash "$importer" --fetch > "$tmp/fetch.log" 2>&1
fetched_rules="$STAGING_DIR/fetched/postgrey/whitelist_clients.local"
[[ -f "$fetched_rules" && ! -L "$fetched_rules" ]] || fail "source whitelist link was not dereferenced"
cmp "$fetched_rules" "$shared_rules"

bash "$importer" --install-modular > "$tmp/import.log" 2>&1
cmp "$active_rules" "$shared_rules"

rm "$active_rules"
printf 'target.example\n' > "$tmp/target-shared"
ln -s "$tmp/target-shared" "$active_rules"
bash "$importer" --install-modular >> "$tmp/import.log" 2>&1
[[ "$(readlink "$active_rules")" == "$tmp/target-shared" ]] || fail "migration replaced target whitelist link"
grep -qx 'target.example' "$active_rules" || fail "migration overwrote target whitelist"
cmp "$IMPORT_TARGET/postgrey/whitelist_clients.local" "$shared_rules"

# Missing source rules clear stale staging instead of reusing an earlier whitelist.
: > "$POSTGREY_FIXTURE"
bash "$importer" --fetch >> "$tmp/fetch.log" 2>&1
[[ ! -e "$fetched_rules" ]] || fail "stale Postgrey whitelist remained staged"
grep -q 'No source Postgrey client whitelist found' "$tmp/fetch.log" || fail "missing whitelist warning absent"

printf 'postgrey migration tests passed\n'
