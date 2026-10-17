#!/usr/bin/env bash
set -euo pipefail
source /etc/t3-code.env
[[ "$(id -un)" == "$T3_DEV_USER" ]]
selector=${1:?Selector required}
staging=${2:?Staging required}
current=${3:?Current version required}
previous=${4:-}
state=${T3CODE_HOME:-/var/lib/t3-code}
support=/usr/local/share/t3-code
[[ "$(readlink /proc/$$/fd/7)" == "$state/runtime/update.lock" ]]
export T3_INSTALLER_SHA256=${T3_INSTALLER_SHA256:-}
printf 'resolving\n' > "$staging/phase"
bash "$support/resolve-version.sh" "$selector" "$staging/versions.json"
version=$(jq -er '.t3' "$staging/versions.json")
case "$(uname -m)" in
    x86_64) browser_platform=linux64 ;;
    aarch64|arm64) browser_platform=linux-arm64 ;;
    *) exit 1 ;;
esac
destination="$state/runtime/versions/$version"
if [[ "$current" != "$version" || -n "$previous" ]]; then
    printf 'runtime\n' > "$staging/phase"
    if [[ -e "$destination" || -L "$destination" ]]; then
        bash "$support/install-runtime.sh" --verify "$destination" "$staging/versions.json" || {
            echo "Runtime cache integrity failed: $destination. Server and state were not changed." >&2; exit 1;
        }
    else
        bash "$support/install-runtime.sh" "$destination" "$staging/versions.json"
    fi
fi
changed=false
if [[ "$current" != "$version" ]]; then
    changed=true
    printf 'browser-install\n' > "$staging/phase"
    browser_version=$(jq -er '.browser' "$staging/versions.json")
    browser="$state/tools/chrome-headless-shell/$browser_platform/$browser_version/chrome-headless-shell"
    if [[ ! -x "$browser" ]]; then bash "$support/install-browser.sh" "$state" "$staging/versions.json"; fi
    printf 'browser-preflight\n' > "$staging/phase"
    fc-match sans-serif
    if ! timeout 30 "$browser" --headless --disable-gpu --disable-dev-shm-usage --no-first-run \
        --user-data-dir="$staging/browser-profile" --dump-dom 'data:text/html,<p>T3 update ready</p>' \
        > "$staging/dom" 2> "$staging/browser.log"; then
        cat "$staging/browser.log" >&2
        exit 1
    fi
    grep -F 'T3 update ready' "$staging/dom" >/dev/null
fi
jq -n --arg version "$version" --argjson changed "$changed" '{version:$version,changed:$changed}' > "$staging/prepared.json"
printf 'prepared\n' > "$staging/phase"
