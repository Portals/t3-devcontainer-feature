#!/usr/bin/env bash
set -euo pipefail
source /etc/t3-code.env
[[ "$(id -un)" == "$T3_DEV_USER" ]] || { echo "Run as $T3_DEV_USER" >&2; exit 1; }
selector=${1:-${T3_VERSION:-latest}}
if [[ "$selector" == latest ]]; then selector=${T3_UPDATE_CHANNEL:-stable}; fi
policy=${2:-${T3_UPDATE_CHANNEL:-stable}}
state=${T3CODE_HOME:-/var/lib/t3-code}
support=/usr/local/share/t3-code
runtime="$state/runtime"
umask 077
mkdir -p "$runtime/versions" "$state/run"
if [[ "${T3_UPDATE_LOCK_FD:-}" == 7 ]]; then
    [[ "$(readlink /proc/$$/fd/7)" == "$runtime/update.lock" ]] || { echo 'Invalid inherited update lock.' >&2; exit 1; }
else
    exec 7>"$runtime/update.lock"
fi
flock -n 7 || { echo 'Another runtime update is running.' >&2; exit 1; }
staging=$(mktemp -d "$runtime/.update-XXXXXX")
previous=$(readlink "$runtime/current" 2>/dev/null || true)
snapshot=
activated=false
committed=false
outcome=failed
started_at=$(date -u +%FT%TZ)
stopped=false
was_running=false
if t3-code-status >/dev/null 2>&1; then was_running=true; fi
should_start=$was_running
if [[ "${T3_AUTOSTART_OVERRIDE:-${T3_AUTOSTART:-false}}" == true ]]; then should_start=true; fi

record_outcome() {
    local resolved= phase=initializing temporary
    if [[ -r "$staging/versions.json" ]]; then resolved=$(jq -r '.t3 // ""' "$staging/versions.json"); fi
    if [[ -r "$staging/phase" ]]; then read -r phase < "$staging/phase"; fi
    temporary=$(mktemp "$runtime/.outcome-XXXXXX")
    jq -n --arg requested "$selector" --arg resolved "$resolved" --arg policy "$policy" --arg phase "$phase" \
        --arg status "$outcome" --arg started "$started_at" --arg finished "$(date -u +%FT%TZ)" --argjson code "$1" \
        '{schema:1,requested:$requested,resolved:$resolved,channel:$policy,status:$status,phase:$phase,exitCode:$code,startedAt:$started,finishedAt:$finished}' > "$temporary"
    mv -f "$temporary" "$runtime/last-update.json"
}
backup_status() {
    [[ -n "$snapshot" && -r "$snapshot/.backup.json" ]] || return 0
    jq --arg status "$1" --arg finished "$(date -u +%FT%TZ)" '.status=$status | .finishedAt=$finished' "$snapshot/.backup.json" > "$snapshot/.backup.json.new"
    mv -f "$snapshot/.backup.json.new" "$snapshot/.backup.json"
}
finish() {
    result=$?
    trap - EXIT INT TERM
    set +e
    if [[ "$activated" == true && "$committed" != true ]]; then
        echo 'New T3 failed readiness; restoring the previous runtime and saved state.' >&2
        if ! t3-code-stop; then
            echo "Cannot confirm shutdown; keeping recovery data at $snapshot" >&2
            outcome=recovery-required
            backup_status recovery-required
            record_outcome "$result"
            rm -rf "$staging"
            exit "$result"
        fi
        exec 8>"$state/run/server.lock"
        if flock -w 30 8; then
            restored=true
            if [[ -n "$previous" ]]; then
                ln -s "$previous" "$staging/previous" && mv -Tf "$staging/previous" "$runtime/current" || restored=false
            else
                rm -f "$runtime/current" || restored=false
            fi
            if [[ -d "$state/userdata" ]]; then
                [[ ! -e "$snapshot/failed-userdata" ]] && mv "$state/userdata" "$snapshot/failed-userdata" || restored=false
            fi
            if [[ -d "$snapshot/userdata" && "$restored" == true ]]; then
                mv "$snapshot/userdata" "$state/userdata" || restored=false
            fi
            flock -u 8
            outcome=recovery-required
            if [[ "$restored" == true ]]; then
                outcome=rolled-back
                if [[ "$should_start" == true ]]; then t3-code-start 7>&- 8>&- || outcome=recovery-required; fi
            fi
            backup_status "$outcome"
        else
            outcome=recovery-required
            backup_status recovery-required
            echo "Could not stop the failed runtime safely. State snapshot: $snapshot" >&2
        fi
    elif [[ "$stopped" == true && "$committed" != true && "$should_start" == true ]]; then
        flock -u 8 2>/dev/null || true
        t3-code-start 7>&- 8>&- || true
    fi
    if [[ "$committed" != true && -n "$snapshot" && "$outcome" == failed ]]; then backup_status incomplete; fi
    record_outcome "$result"
    rm -rf "$staging"
    exit "$result"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

current=$(timeout 30 t3 --version | sed -nE 's/^t3 v?([^[:space:]]+)$/\1/p')
prepare_timeout=${T3_PREPARE_TIMEOUT:-0}
[[ "$prepare_timeout" =~ ^[0-9]{1,5}$ ]] || { echo 'Invalid preparation timeout.' >&2; exit 1; }
prepare_result=0
if (( 10#$prepare_timeout > 0 )); then
    timeout --kill-after=10 "$prepare_timeout" bash "$support/runtime-prepare.sh" "$selector" "$staging" "$current" "$previous" || prepare_result=$?
else
    bash "$support/runtime-prepare.sh" "$selector" "$staging" "$current" "$previous" || prepare_result=$?
fi
if [[ "$prepare_result" != 0 ]]; then
    if [[ "$prepare_result" == 124 || "$prepare_result" == 137 ]]; then outcome=deferred; fi
    exit "$prepare_result"
fi
version=$(jq -er '.version' "$staging/prepared.json")
if [[ "$(jq -r '.changed' "$staging/prepared.json")" == false ]]; then
    printf '%s\n' "$policy" > "$runtime/channel"
    committed=true
    outcome=unchanged
    echo "T3 $version is already current for $selector."
    exit 0
fi
printf 'shutdown\n' > "$staging/phase"
stopped=true
t3-code-stop
exec 8>"$state/run/server.lock"
flock -w 30 8
mkdir -p "$runtime/backups"
snapshot=$(mktemp -d "$runtime/backups/before-$version-XXXXXX")
jq -n --arg created "$(date -u +%FT%TZ)" --arg from "$current" --arg to "$version" --arg previous "$previous" \
    '{schema:1,kind:"t3-code-backup",status:"pending",createdAt:$created,fromVersion:$from,toVersion:$to,previousRuntime:$previous}' > "$snapshot/.backup.json"
printf 'backup\n' > "$staging/phase"
if [[ -d "$state/userdata" ]]; then cp -a "$state/userdata" "$snapshot/userdata"; fi
printf '%s\n' "$previous" > "$snapshot/previous-runtime"
printf 'activation\n' > "$staging/phase"
activated=true
ln -s "versions/$version" "$staging/current"
mv -Tf "$staging/current" "$runtime/current"
flock -u 8
if [[ "$should_start" == true ]]; then
    t3-code-start 7>&- 8>&-
fi
last_good=$previous
if [[ -z "$last_good" ]]; then last_good=$(dirname "$(cat "$support/fallback")"); fi
ln -s "$last_good" "$staging/last-good"
mv -Tf "$staging/last-good" "$runtime/previous"
committed=true
outcome=updated
backup_status committed
printf 'ready\n' > "$staging/phase"
printf '%s\n' "$policy" > "$runtime/channel"
echo "Updated T3 $current -> $version. Container unchanged. State snapshot: $snapshot"
