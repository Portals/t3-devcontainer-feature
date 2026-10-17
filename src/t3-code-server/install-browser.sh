#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
cache=${1:?Browser cache destination required}
manifest=${2:?Resolved version manifest required}
case "$(uname -m)" in
    x86_64) platform=linux64 ;;
    aarch64|arm64) platform=linux-arm64 ;;
    *) echo 'Unsupported browser architecture.' >&2; exit 1 ;;
esac
version=$(jq -er '.browser' "$manifest")
bytes=$(jq -er --arg platform "$platform" '.archives[$platform].bytes' "$manifest")
sha256=$(jq -er --arg platform "$platform" '.archives[$platform].sha256' "$manifest")
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && "$sha256" =~ ^[a-f0-9]{64}$ && "$bytes" =~ ^[1-9][0-9]+$ ]]
parent="$cache/tools/chrome-headless-shell/$platform"
mkdir -p "$parent"
exec 6>"$parent/.install-$version.lock"
flock -w 300 6
destination="$parent/$version"
if [[ -x "$destination/chrome-headless-shell" && -r "$destination/.archive-sha256" ]] && [[ "$(cat "$destination/.archive-sha256")" == "$sha256" ]]; then
    printf 'Browser %s is already prepared.\n' "$version"
    exit 0
fi
temporary=$(mktemp -d "$parent/.install-$version-XXXXXX")
previous=
finish() {
    result=$?
    trap - EXIT INT TERM
    if [[ -n "$previous" && ! -e "$destination" ]]; then mv -T "$previous" "$destination"; fi
    rm -rf "$temporary"
    exit "$result"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
archive="$temporary/browser.zip"
url="https://storage.googleapis.com/chrome-for-testing-public/$version/$platform/chrome-headless-shell-$platform.zip"
curl --fail --show-error --silent --location --retry 3 --max-time 300 "$url" -o "$archive"
[[ "$(stat -c %s "$archive")" == "$bytes" ]] || { echo 'Browser archive size mismatch.' >&2; exit 1; }
printf '%s  %s\n' "$sha256" "$archive" | sha256sum --check --status
unzip -q "$archive" -d "$temporary/unpacked"
prepared="$temporary/unpacked/chrome-headless-shell-$platform"
chmod 0755 "$prepared/chrome-headless-shell"
printf '%s\n' "$sha256" > "$prepared/.archive-sha256"
jq -n --arg version "$version" --arg platform "$platform" --arg sha "$sha256" --arg url "$url" \
    --arg created "$(date -u +%FT%TZ)" --argjson bytes "$bytes" \
    '{schema:1,kind:"t3-code-browser",version:$version,platform:$platform,createdAt:$created,
      archive:{url:$url,verifiedSha256:$sha,bytes:$bytes},verification:"sha256-and-size-before-extraction"}' \
    > "$prepared/.install-receipt.json"
if [[ -e "$destination" ]]; then
    previous="$temporary/previous"
    mv -T "$destination" "$previous"
fi
mv -T "$prepared" "$destination"
printf 'Prepared browser %s (%s)\n' "$version" "$platform"
