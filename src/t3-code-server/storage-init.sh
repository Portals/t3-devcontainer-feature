#!/usr/bin/env bash
set -euo pipefail
source /etc/t3-code.env
[[ "$(id -u)" == 0 ]]
state=${T3CODE_HOME:-/var/lib/t3-code}
uid=$(id -u "$T3_DEV_USER")
gid=$(id -g "$T3_DEV_USER")
[[ "$uid" != 0 && "$state" == /* && "$state" != / && ! -L "$state" ]]

repair_owned() {
    local directory=$1 marker=$2 old_uid old_gid temporary
    shift 2
    old_uid=$(stat -c %u "$directory")
    old_gid=$(stat -c %g "$directory")
    if [[ -e "$marker" ]]; then
        [[ ! -L "$marker" ]]
        read -r old_uid old_gid < <(jq -er 'select(.schema == 1 and .kind == "t3-code-owner") | [.uid,.gid] | @tsv' "$marker")
        [[ "$old_uid" =~ ^[0-9]+$ && "$old_gid" =~ ^[0-9]+$ ]]
    fi
    if [[ "$old_uid" != "$uid" || "$old_gid" != "$gid" ]]; then
        # A live supervisor/update owns this lock. Never change its files underneath it.
        if [[ -f "$state/run/server.lock" ]]; then
            exec 8>"$state/run/server.lock"
            flock -n 8 || { echo 'Stop T3 before changing its storage ownership.' >&2; exit 1; }
        fi
        for owned in "$@"; do
            [[ -d "$owned" && ! -L "$owned" ]] || continue
            if [[ "$old_uid" != "$uid" ]]; then
                find "$owned" -xdev -uid "$old_uid" -exec chown -h "$uid" {} +
            fi
            if [[ "$old_gid" != "$gid" ]]; then
                find "$owned" -xdev -gid "$old_gid" -exec chgrp -h "$gid" {} +
            fi
        done
        flock -u 8 2>/dev/null || true
        exec 8>&-
    fi
    temporary=$(mktemp "$(dirname "$marker")/.owner-XXXXXX")
    jq -n --argjson uid "$uid" --argjson gid "$gid" '{schema:1,kind:"t3-code-owner",uid:$uid,gid:$gid}' > "$temporary"
    chown "$uid:$gid" "$temporary"
    chmod 0600 "$temporary"
    mv -f "$temporary" "$marker"
}

mkdir -p "$state"
owned=()
for name in tools logs run worktrees runtime userdata; do owned+=("$state/$name"); done
repair_owned "$state" "$state/.t3-code-owner.json" "${owned[@]}"
install -d -o "$uid" -g "$gid" -m 0700 "$state"
for name in tools logs run worktrees; do install -d -o "$uid" -g "$gid" -m 0700 "$state/$name"; done

if [[ "${T3_REPAIR_HOME_OWNERSHIP:-false}" == true ]]; then
    case "$T3_DEV_HOME" in /|/home|/root|/usr|/var|/tmp|/opt|/etc|/bin|/sbin) echo 'Refusing to manage a shared/system home path.' >&2; exit 1 ;; esac
    [[ -d "$T3_DEV_HOME" && "$(readlink -f "$T3_DEV_HOME")" == "$T3_DEV_HOME" ]]
    repair_owned "$T3_DEV_HOME" "$T3_DEV_HOME/.t3-code-home-owner.json" "$T3_DEV_HOME"
    chown "$uid:$gid" "$T3_DEV_HOME"
fi
