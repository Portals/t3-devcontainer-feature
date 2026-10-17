#!/usr/bin/env bash
set -euo pipefail
verify=false
if [[ "${1:-}" == --verify ]]; then verify=true; shift; fi
destination=${1:?Runtime destination required}
manifest=${2:?Resolved version manifest required}
version=$(jq -er '.t3' "$manifest")
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][a-zA-Z0-9.-]+)?$ ]]
case "$(uname -m)" in
    x86_64) architecture=linux-x64 ;;
    aarch64|arm64) architecture=linux-arm64 ;;
    *) echo 'Unsupported architecture.' >&2; exit 1 ;;
esac
expected=$(jq -er --arg architecture "$architecture" '.t3Archives[$architecture].sha256' "$manifest")
[[ "$expected" =~ ^[a-f0-9]{64}$ ]]
if [[ "$verify" == true ]]; then
    [[ -d "$destination" && ! -L "$destination" && -r "$destination/.checksums" && -r "$destination/.archive-sha256" ]]
    [[ "$(cat "$destination/.archive-sha256")" == "$expected" ]]
    (cd "$destination"; sha256sum --check --status .checksums)
    [[ "$(timeout 30 "$destination/t3" --version)" == "t3 v$version" ]]
    exit 0
fi
[[ ! -e "$destination" && ! -L "$destination" ]]
mkdir -p "$(dirname "$destination")"
temporary=$(mktemp -d "$(dirname "$destination")/.runtime-XXXXXX")
installer_pid=
finish() {
    result=$?
    trap - EXIT INT TERM
    if [[ -n "$installer_pid" ]]; then
        kill -TERM "$installer_pid" 2>/dev/null || true
        wait "$installer_pid" || true
    fi
    rm -rf "$temporary"
    exit "$result"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
archive="t3-$version-$architecture.tar.gz"
release_url="https://github.com/pingdotgg/t3code/releases/download/v$version"
curl --fail --show-error --silent --location --retry 2 --max-time 60 \
    "$release_url/SHA256SUMS" -o "$temporary/SHA256SUMS"
release_sha=$(awk -v archive="$archive" '{ name=$2; sub(/^\*/, "", name); if (name==archive) print $1 }' "$temporary/SHA256SUMS")
[[ "$release_sha" == "$expected" ]] || { echo 'Release checksums disagree with the resolved API digest.' >&2; exit 1; }
curl --fail --show-error --silent --location --retry 2 --max-time 60 \
    https://t3.codes/install.sh -o "$temporary/install.sh"
installer_sha=$(sha256sum "$temporary/install.sh" | cut -d' ' -f1)
if [[ -n "${T3_INSTALLER_SHA256:-}" ]]; then
    [[ "$T3_INSTALLER_SHA256" =~ ^[a-f0-9]{64}$ && "$installer_sha" == "$T3_INSTALLER_SHA256" ]] || {
        echo 'Official installer digest does not match installerSha256.' >&2; exit 1;
    }
fi
timeout --kill-after=5 600 env -u T3CODE_RELEASE_BASE_URL T3CODE_VERSION="$version" T3CODE_CHANNEL=stable \
    T3CODE_HOME="$temporary/home" T3CODE_INSTALL_BIN_DIR="$temporary/bin" \
    sh "$temporary/install.sh" &
installer_pid=$!
wait "$installer_pid"
installer_pid=
prepared="$temporary/home/runtime/versions/$version"
[[ "$(timeout 30 "$prepared/t3" --version)" == "t3 v$version" ]]
[[ "$(cat "$prepared/.install-complete")" == "$version" ]]
chmod 0755 "$prepared"
printf '%s\n' "$expected" > "$prepared/.archive-sha256"
cp "$manifest" "$prepared/.resolved-version.json"
jq -n --arg version "$version" --arg architecture "$architecture" --arg archive "$release_url/$archive" \
    --arg expected "$expected" --arg release "$release_sha" --arg bootstrap "$installer_sha" \
    --arg created "$(date -u +%FT%TZ)" --arg pin "${T3_INSTALLER_SHA256:-}" \
    '{schema:1,kind:"t3-code-runtime",version:$version,architecture:$architecture,createdAt:$created,
      archive:{url:$archive,apiExpectedSha256:$expected,releaseChecksumSha256:$release},
      bootstrap:{url:"https://t3.codes/install.sh",sha256:$bootstrap,pinned:($pin!="")},
      verification:{apiMatchesReleaseChecksum:true,archive:"delegated-to-official-installer-sha256sums",files:".checksums"}}' \
    > "$prepared/.install-receipt.json"
(cd "$prepared"; find . -type f -print0 | sort -z | xargs -0 sha256sum) > "$temporary/checksums"
mv "$temporary/checksums" "$prepared/.checksums"
mv -T "$prepared" "$destination"
