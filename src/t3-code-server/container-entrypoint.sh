#!/usr/bin/env bash
set -euo pipefail
source /etc/t3-code.env

export T3CODE_HOME=${T3CODE_HOME:-/var/lib/t3-code}
dev_group=$(id -gn "$T3_DEV_USER")
bash /usr/local/share/t3-code/storage-init.sh

source_cache=/usr/local/share/t3-code/browser-cache/tools/chrome-headless-shell
while IFS= read -r -d '' executable; do
    relative=${executable#"$source_cache"/}
    release=${relative%/chrome-headless-shell}
    destination="$T3CODE_HOME/tools/chrome-headless-shell/$release"
    if [[ ! -x "$destination/chrome-headless-shell" ]]; then
        install -d "$(dirname "$destination")"
        chown "$T3_DEV_USER:$dev_group" "$(dirname "$destination")"
        staging=$(mktemp -d "$(dirname "$destination")/.seed-XXXXXX")
        cp -a "$(dirname "$executable")/." "$staging/"
        chown -R "$T3_DEV_USER:$dev_group" "$staging"
        mv -T "$staging" "$destination"
    fi
done < <(find "$source_cache" -type f -name chrome-headless-shell -print0)
chown "$T3_DEV_USER:$dev_group" "$T3CODE_HOME/tools/chrome-headless-shell"

target="$T3_DEV_HOME/.agents/skills/worktree-cleanup"
if [[ ! -e "$target" && ! -L "$target" ]]; then
    runuser -u "$T3_DEV_USER" -- mkdir -p "$(dirname "$target")"
    runuser -u "$T3_DEV_USER" -- cp -R /usr/local/share/t3-code/skills/worktree-cleanup "$target"
fi

if [[ "${T3_AUTO_UPDATE:-false}" == true || "${T3_VERSION:-latest}" != latest ]]; then
    selector=${T3_VERSION:-latest}
    if [[ "$selector" == latest ]]; then selector=${T3_UPDATE_CHANNEL:-stable}; fi
    runuser -u "$T3_DEV_USER" -- env HOME="$T3_DEV_HOME" PATH="$PATH" T3CODE_HOME="$T3CODE_HOME" \
        T3_PREPARE_TIMEOUT="${T3_STARTUP_UPDATE_TIMEOUT:-120}" \
        bash /usr/local/share/t3-code/runtime-update.sh "$selector" "${T3_UPDATE_CHANNEL:-stable}" || \
        echo 'T3 update failed; continuing with the installed runtime.' >&2
fi

if [[ "${T3_AUTOSTART_OVERRIDE:-$T3_AUTOSTART}" == true ]]; then
    runuser -u "$T3_DEV_USER" -- env HOME="$T3_DEV_HOME" PATH="$PATH" T3CODE_HOME="$T3CODE_HOME" t3-code-browser-check
    runuser -u "$T3_DEV_USER" -- env HOME="$T3_DEV_HOME" PATH="$PATH" T3CODE_HOME="$T3CODE_HOME" t3-code-start
fi

if [[ "$#" -gt 0 ]]; then exec "$@"; fi
