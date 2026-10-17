#!/usr/bin/env bash
set -euo pipefail
root=$(mktemp -d /tmp/t3-prune-test-XXXXXX)
worker=
cleanup() {
    result=$?
    trap - EXIT
    if [[ -n "$worker" ]] && kill -0 "$worker" 2>/dev/null; then kill -TERM -- "-$worker"; wait "$worker" || true; fi
    rm -rf "$root"
    exit "$result"
}
trap cleanup EXIT
state="$root/state"
mkdir -p "$state/runtime/versions" "$state/runtime/backups" "$state/worktrees"
printf 'unfinished work\n' > "$state/worktrees/keep"
browser_version=$(jq -r .browser /usr/local/share/t3-code/versions.json)
for version in 1.0.0 1.0.1 0.9.9 0.9.8; do
    directory="$state/runtime/versions/$version"
    mkdir -p "$directory"
    jq -n --arg version "$version" '{schema:1,kind:"t3-code-runtime",createdAt:"2026-01-01T00:00:00Z",version:$version}' > "$directory/.install-receipt.json"
    jq -n --arg browser "$browser_version" '{browser:$browser}' > "$directory/.resolved-version.json"
done
ln -s versions/1.0.0 "$state/runtime/current"
ln -s versions/1.0.1 "$state/runtime/previous"
for status in committed pending; do
    mkdir "$state/runtime/backups/$status"
    from=0.9.9
    if [[ "$status" == pending ]]; then from=0.9.8; fi
    jq -n --arg status "$status" --arg from "$from" \
        '{schema:1,kind:"t3-code-backup",createdAt:"2026-01-01T00:00:00Z",status:$status,fromVersion:$from,toVersion:"1.0.0"}' \
        > "$state/runtime/backups/$status/.backup.json"
done
case "$(uname -m)" in x86_64) platform=linux64 ;; *) platform=linux-arm64 ;; esac
parent="$state/tools/chrome-headless-shell/$platform"
mkdir -p "$parent/998.0.0.0" "$parent/997.0.0.0"
jq -n '{schema:1,kind:"t3-code-browser",createdAt:"2026-01-01T00:00:00Z",version:"998.0.0.0"}' > "$parent/998.0.0.0/.install-receipt.json"
printf 'unknown cache\n' > "$parent/997.0.0.0/keep"
real_state=${T3CODE_HOME:-/var/lib/t3-code}
cp -a "$real_state/tools/chrome-headless-shell/$platform/$browser_version" "$parent/999.0.0.0"
jq '.version="999.0.0.0"' "$parent/999.0.0.0/.install-receipt.json" > "$root/receipt"
mv "$root/receipt" "$parent/999.0.0.0/.install-receipt.json"
setsid "$parent/999.0.0.0/chrome-headless-shell" --headless --disable-gpu --disable-dev-shm-usage --no-first-run \
    --user-data-dir="$root/profile" --remote-debugging-port=0 'data:text/html,<p>owned cleanup test</p>' > "$root/browser.log" 2>&1 &
worker=$!
for _attempt in {1..100}; do
    if grep -q 'DevTools listening' "$root/browser.log"; then break; fi
    kill -0 "$worker"
    sleep 0.1
done
grep -q 'DevTools listening' "$root/browser.log"
T3CODE_HOME="$state" t3-code-prune --keep 0 > "$root/dry.json"
jq -e '[.entries[] | select(.action=="remove") | .path | split("/")[-1]] | sort == ["0.9.9","998.0.0.0","committed"]' "$root/dry.json"
[[ -d "$state/runtime/versions/0.9.9" && -d "$parent/998.0.0.0" ]]
T3CODE_HOME="$state" t3-code-prune --keep 0 --apply > "$root/applied.json"
[[ ! -e "$state/runtime/versions/0.9.9" && ! -e "$parent/998.0.0.0" ]]
[[ -d "$state/runtime/versions/1.0.0" && -d "$state/runtime/versions/1.0.1" && -d "$state/runtime/versions/0.9.8" ]]
[[ -d "$parent/999.0.0.0" && -r "$parent/997.0.0.0/keep" && -d "$state/runtime/backups/pending" ]]
[[ "$(cat "$state/worktrees/keep")" == 'unfinished work' ]]
kill -0 "$worker"
mkdir "$state/runtime/backups/legacy"
T3CODE_HOME="$state" t3-code-prune --keep 0 > "$root/legacy.json"
jq -e 'all(.entries[] | select(.kind=="runtime"); .action=="keep")' "$root/legacy.json"
exec 7>"$state/runtime/update.lock"
flock -n 7
if T3CODE_HOME="$state" t3-code-prune --apply > "$root/locked.log" 2>&1; then echo 'Prune ignored an update lock.' >&2; exit 1; fi
grep -F 'Another update or cleanup' "$root/locked.log"
flock -u 7
echo 'PASS: dry-run/apply, active and rollback runtimes, failed recovery, live browser, unknown data, worktrees and update lock protections.'
