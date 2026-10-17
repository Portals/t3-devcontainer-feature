#!/usr/bin/env bash
set -euo pipefail
source /etc/t3-code.env
root=$(mktemp -d /tmp/t3-preparation-budget-XXXXXX)
resolver=/usr/local/share/t3-code/resolve-version.sh
cp -p "$resolver" "$root/resolver"
cleanup() {
    result=$?
    trap - EXIT
    sudo cp -p "$root/resolver" "$resolver"
    rm -rf "$root"
    exit "$result"
}
trap cleanup EXIT
pid=$(cat "$T3CODE_HOME/run/server.pid")
identity=$(sha256sum "$T3CODE_HOME/userdata/environment-id")
printf '#!/bin/bash\nprintf "%%s\\n" "$$" > "$T3_TEST_PREP_PID"\nexec sleep 60\n' > "$root/slow"
sudo install -m 0755 "$root/slow" "$resolver"
result=0
T3_PREPARE_TIMEOUT=1 T3_TEST_PREP_PID="$root/worker" bash /usr/local/share/t3-code/runtime-update.sh nightly > "$root/timeout.log" 2>&1 || result=$?
[[ "$result" == 124 ]]
jq -e '.status=="deferred" and .phase=="resolving" and .exitCode==124' "$T3CODE_HOME/runtime/last-update.json"
[[ "$(cat "$T3CODE_HOME/run/server.pid")" == "$pid" && "$(sha256sum "$T3CODE_HOME/userdata/environment-id")" == "$identity" ]]
worker=$(cat "$root/worker")
if kill -0 "$worker" 2>/dev/null; then echo 'Preparation worker survived cancellation.' >&2; exit 1; fi
t3-code-status
echo 'PASS: preparation deadline left the running server and state untouched, recorded a deferred outcome, and stopped its worker.'
