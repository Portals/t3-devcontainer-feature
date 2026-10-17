#!/usr/bin/env bash
set -euo pipefail
installer=${1:?Installer path required}
manifest=/usr/local/share/t3-code/versions.json
root=$(mktemp -d /tmp/t3-browser-stress-XXXXXX)
cleanup() {
    result=$?
    trap - EXIT
    rm -rf "$root"
    exit "$result"
}
trap cleanup EXIT
version=$(jq -er '.browser' "$manifest")
case "$(uname -m)" in
    aarch64|arm64) platform=linux-arm64 ;;
    x86_64) platform=linux64 ;;
esac
setsid bash "$installer" "$root/cache" "$manifest" > "$root/interrupted.log" 2>&1 &
worker=$!
for _attempt in {1..100}; do
    if find "$root/cache" -name '*.zip' -print -quit 2>/dev/null | grep -q .; then break; fi
    sleep 0.1
done
kill -TERM -- "-$worker"
wait "$worker" || true
[[ ! -e "$root/cache/tools/chrome-headless-shell/$platform/$version" ]]
[[ -z "$(find "$root/cache" -type d -name '.install-*' -print -quit)" ]]
echo 'Interrupted download left no published browser or staging directory.'
bash "$installer" "$root/cache" "$manifest" > "$root/first.log" 2>&1 &
first=$!
bash "$installer" "$root/cache" "$manifest" > "$root/second.log" 2>&1 &
second=$!
wait "$first"
wait "$second"
cat "$root/first.log" "$root/second.log"
browser="$root/cache/tools/chrome-headless-shell/$platform/$version/chrome-headless-shell"
sha=$(jq -er --arg platform "$platform" '.archives[$platform].sha256' "$manifest")
[[ "$(cat "$(dirname "$browser")/.archive-sha256")" == "$sha" ]]
timeout 30 "$browser" --headless --disable-gpu --disable-dev-shm-usage --no-first-run --user-data-dir="$root/profile" --dump-dom 'data:text/html,<p>browser installation stress passed</p>' > "$root/dom" 2> "$root/browser.log"
grep -F 'browser installation stress passed' "$root/dom" >/dev/null
[[ -z "$(find "$root/cache" -type d -name '.install-*' -print -quit)" ]]
echo 'PASS: interrupted install cleanup, two concurrent installers, archive verification and sandboxed rendering.'
