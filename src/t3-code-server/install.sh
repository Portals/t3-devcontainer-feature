#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

[[ "$(id -u)" == 0 ]] || { echo 'Feature installation requires root.' >&2; exit 1; }
distro=$(. /etc/os-release; printf '%s:%s' "$ID" "${ID_LIKE:-}")
case "$distro" in
    debian:*|ubuntu:*|*:debian*) ;;
    *) echo 'Supported images: Debian and Ubuntu, amd64 or arm64.' >&2; exit 1 ;;
esac

case "$(uname -m)" in
    x86_64|aarch64|arm64) ;;
    *) echo 'Supported architectures: amd64 and arm64.' >&2; exit 1 ;;
esac

dev_user=${USER:-automatic}
if [[ "$dev_user" == automatic ]]; then
    dev_user=${_REMOTE_USER:-vscode}
fi
if ! dev_uid=$(id -u -- "$dev_user") || [[ "$dev_uid" == 0 ]]; then
    echo 'Set remoteUser (or the feature user option) to an existing non-root account.' >&2
    exit 1
fi

port=${PORT:-3773}
if ! [[ "$port" =~ ^[0-9]{1,5}$ ]] || ! (( 10#$port > 0 && 10#$port < 65536 )); then
    echo 'port must be between 1 and 65535.' >&2
    exit 1
fi

channel=${CHANNEL:-stable}
[[ "$channel" == stable || "$channel" == nightly ]]
version=${VERSION:-latest}
[[ "$version" == latest || "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][a-zA-Z0-9.-]+)?$ ]] || {
    echo 'version must be latest or an exact runtime version.' >&2; exit 1;
}
startup_timeout=${STARTUPUPDATETIMEOUT:-120}
[[ "$startup_timeout" =~ ^[1-9][0-9]{0,4}$ ]] || { echo 'startupUpdateTimeout must be 1–99999 seconds.' >&2; exit 1; }
export T3_INSTALLER_SHA256=${INSTALLERSHA256:-}
[[ -z "$T3_INSTALLER_SHA256" || "$T3_INSTALLER_SHA256" =~ ^[a-f0-9]{64}$ ]] || { echo 'installerSha256 must be empty or 64 lowercase hex characters.' >&2; exit 1; }
for boolean in "${AUTOSTART:-true}" "${AUTOUPDATE:-true}" "${REPAIRHOMEOWNERSHIP:-false}"; do
    [[ "$boolean" == true || "$boolean" == false ]] || { echo 'Expected a boolean feature option.' >&2; exit 1; }
done

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl jq libatomic1 procps unzip util-linux
if ! command -v git >/dev/null 2>&1; then apt-get install -y --no-install-recommends git; fi
bash install-browser-libraries.sh

runtime=/usr/local/share/t3-code
install -d "$runtime"
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
selector=$version
if [[ "$selector" == latest ]]; then selector=$channel; fi
bash resolve-version.sh "$selector" "$temporary/versions.json"
case "$(uname -m)" in x86_64) architecture=linux-x64 ;; *) architecture=linux-arm64 ;; esac
resolved=$(jq -er '.t3' "$temporary/versions.json")
digest=$(jq -er --arg architecture "$architecture" '.t3Archives[$architecture].sha256' "$temporary/versions.json")
fallback="$runtime/image-runtimes/$resolved-$digest"
if [[ -e "$fallback" || -L "$fallback" ]]; then
    bash install-runtime.sh --verify "$fallback" "$temporary/versions.json" || { echo 'Existing image runtime failed integrity verification.' >&2; exit 1; }
else
    bash install-runtime.sh "$fallback" "$temporary/versions.json"
fi
printf '%s\n' "$fallback/t3" > "$runtime/fallback.new"
mv -f "$runtime/fallback.new" "$runtime/fallback"
for helper in t3-launcher resolve-version.sh install-runtime.sh install-browser.sh runtime-update.sh runtime-prepare.sh storage-init.sh server-state.sh; do
    install -m 0755 "$helper" "$runtime/$helper"
done
ln -sf "$runtime/t3-launcher" /usr/local/bin/t3

install -m 0755 container-entrypoint.sh "$runtime/container-entrypoint.sh"
install -d "$runtime/skills"
cp -R skills/worktree-cleanup "$runtime/skills/"
for tool in t3-code-start t3-code-run t3-code-status t3-code-stop t3-code-browser-check t3-code-prune; do
    install -m 0755 "$tool" "/usr/local/bin/$tool"
done
install -m 0644 "$temporary/versions.json" "$runtime/versions.json"
bash install-browser.sh "$runtime/browser-cache" "$temporary/versions.json"

dev_home=$(getent passwd "$dev_user" | cut -d: -f6)
{
    printf 'T3_DEV_USER=%q\n' "$dev_user"
    printf 'T3_DEV_HOME=%q\n' "$dev_home"
    printf 'T3_AUTOSTART=%q\n' "${AUTOSTART:-true}"
    printf 'T3_PORT=%q\n' "$((10#$port))"
    printf 'T3_DEFAULT_WORKSPACE=%q\n' "${WORKSPACE:-auto}"
    printf 'T3_UPDATE_CHANNEL=%q\n' "$channel"
    printf 'T3_AUTO_UPDATE=%q\n' "${AUTOUPDATE:-true}"
    printf 'T3_VERSION=%q\n' "$version"
    printf 'T3_STARTUP_UPDATE_TIMEOUT=%q\n' "$startup_timeout"
    printf 'T3_INSTALLER_SHA256=%q\n' "$T3_INSTALLER_SHA256"
    printf 'T3_REPAIR_HOME_OWNERSHIP=%q\n' "${REPAIRHOMEOWNERSHIP:-false}"
} > /etc/t3-code.env
chmod 0644 /etc/t3-code.env
rm -rf /var/lib/apt/lists/*
timeout 30 t3 --version
