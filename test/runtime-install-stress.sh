#!/usr/bin/env bash
set -euo pipefail
manifest=${1:?Pass a resolved real release manifest}
helper=/usr/local/share/t3-code/install-runtime.sh
root=$(mktemp -d /tmp/t3-official-installer-check-XXXXXX)
worker=
cleanup() {
    result=$?
    trap - EXIT
    if [[ -n "$worker" ]] && kill -0 "$worker" 2>/dev/null; then
        kill -TERM -- "-$worker" 2>/dev/null || true
        wait "$worker" || true
    fi
    if [[ "$result" == 0 ]]; then rm -rf "$root"; else echo "Installer check logs retained at $root" >&2; fi
    exit "$result"
}
trap cleanup EXIT
version=$(jq -er '.t3' "$manifest")
pid=$(cat "$T3CODE_HOME/run/server.pid")
setsid bash "$helper" "$root/interrupted" "$manifest" > "$root/interrupted.log" 2>&1 &
worker=$!
for _attempt in {1..1200}; do
    if find "$root" -name '*.tar.gz' -size +0c | grep -q .; then break; fi
    kill -0 "$worker"
    sleep 0.1
done
find "$root" -name '*.tar.gz' -size +0c | grep -q .
kill -TERM -- "-$worker"
if wait "$worker"; then echo 'Interrupted installation unexpectedly succeeded.' >&2; exit 1; fi
worker=
[[ ! -e "$root/interrupted" ]]
[[ -z "$(find "$root" -maxdepth 1 -type d -name '.runtime-*' -print -quit)" ]]
[[ "$(cat "$T3CODE_HOME/run/server.pid")" == "$pid" ]]
t3-code-status >/dev/null
echo 'PASS: interrupted official installation published no runtime, removed staging, and preserved the running server.'
T3CODE_RELEASE_BASE_URL=https://invalid.invalid bash "$helper" "$root/complete" "$manifest" > "$root/complete.log" 2>&1
[[ "$("$root/complete/t3" --version)" == "t3 v$version" ]]
[[ "$(cat "$root/complete/.install-complete")" == "$version" ]]
(cd "$root/complete"; sha256sum --check --status .checksums)
[[ "$(cat "$T3CODE_HOME/run/server.pid")" == "$pid" ]]
t3-code-status >/dev/null
echo "PASS: official installer prepared real T3 $version, ignored an inherited release mirror, verified cached files, and preserved the running server."
