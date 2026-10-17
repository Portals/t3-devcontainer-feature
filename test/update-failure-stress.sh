#!/usr/bin/env bash
set -euo pipefail
source /etc/t3-code.env
state=${T3CODE_HOME:-/var/lib/t3-code}
current_version=$(t3 --version | sed -nE 's/^t3 v?([^[:space:]]+)$/\1/p')
rollback_version=${1:?Pass a different cached T3 version for the rollback test}
[[ "$rollback_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][a-zA-Z0-9.-]+)?$ && "$rollback_version" != "$current_version" ]]
root=$(mktemp -d /tmp/t3-update-failure-XXXXXX)
file=$(readlink -f "$state/runtime/current/client/index.html")
target="$state/runtime/versions/$rollback_version/t3"
mode=$(stat -c %a "$target")
marker="$state/userdata/.feature-rollback-${root##*/}"
cc -Wall -Wextra -Werror "$(dirname "$0")/lease-gate.c" -o "$root/lease-gate"
cp -p "$file" "$root/index.html"
cleanup() {
    result=$?
    trap - EXIT
    cp -p "$root/index.html" "$file"
    chmod "$mode" "$target"
    for worker in $(jobs -pr); do kill -TERM "$worker" 2>/dev/null || true; done
    rm -f "$marker"
    if [[ "$result" == 0 ]]; then rm -rf "$root"; else echo "Failure-test logs retained at $root" >&2; fi
    exit "$result"
}
trap cleanup EXIT
pid=$(cat "$state/run/server.pid")
identity=$(sha256sum "$state/userdata/environment-id")
printf '\n' >> "$file"
if bash /usr/local/share/t3-code/runtime-update.sh "$current_version" > "$root/corrupt.log" 2>&1; then
    echo 'Corrupted current runtime was incorrectly accepted.' >&2
    exit 1
fi
grep -F 'Runtime cache integrity failed' "$root/corrupt.log" >/dev/null
[[ "$(cat "$state/run/server.pid")" == "$pid" ]]
cp -p "$root/index.html" "$file"
echo 'PASS: an already-current but corrupted cache was rejected without stopping the server.'
previous=$(readlink "$state/runtime/current")
"$root/lease-gate" "$marker" > "$root/lease.log" 2>&1 &
lease=$!
for _attempt in {1..500}; do
    grep -Fx ready "$root/lease.log" >/dev/null && break
    kill -0 "$lease"
    sleep 0.01
done
grep -Fx ready "$root/lease.log" >/dev/null
bash /usr/local/share/t3-code/runtime-update.sh "$rollback_version" > "$root/rollback.log" 2>&1 &
updater=$!
for _attempt in {1..6000}; do
    grep -Fx blocked "$root/lease.log" >/dev/null && break
    kill -0 "$updater"
    sleep 0.01
done
grep -Fx blocked "$root/lease.log" >/dev/null
[[ ! -e "$state/run/server.pid" ]]
chmod a-x "$target"
kill -USR1 "$lease"
wait "$lease"
for _attempt in {1..1000}; do
    [[ "$(readlink "$state/runtime/current")" == "versions/$rollback_version" ]] && break
    kill -0 "$updater"
    sleep 0.01
done
[[ "$(readlink "$state/runtime/current")" == "versions/$rollback_version" ]]
printf 'after-activation\n' > "$marker"
if wait "$updater"; then echo 'The execution fault did not cause an update failure.' >&2; exit 1; fi
chmod "$mode" "$target"
grep -F 'restoring the previous runtime and saved state' "$root/rollback.log" >/dev/null
[[ "$(readlink "$state/runtime/current")" == "$previous" ]]
[[ "$(sha256sum "$state/userdata/environment-id")" == "$identity" ]]
[[ "$(cat "$marker")" == before-rollback ]]
t3-code-status
(cd "$state/runtime/versions/$rollback_version"; sha256sum --check --status .checksums)
echo 'PASS: real post-activation execution failure restored the prior runtime, state and healthy server.'
