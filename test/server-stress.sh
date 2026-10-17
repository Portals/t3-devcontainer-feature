#!/usr/bin/env bash
set -euo pipefail
source /etc/t3-code.env
state=${T3CODE_HOME:-/var/lib/t3-code}
source /usr/local/share/t3-code/server-state.sh
root=$(mktemp -d /tmp/t3-server-stress-XXXXXX)
foreign_pid=
stop_foreign() {
    if [[ -n "$foreign_pid" && -r "/proc/$foreign_pid/cmdline" ]] && tr '\0' '\n' < "/proc/$foreign_pid/cmdline" | grep -Fx "$root/foreign" >/dev/null; then
        kill -TERM -- "-$foreign_pid" || true
        for _attempt in {1..100}; do
            [[ -r "/proc/$foreign_pid/stat" ]] || break
            [[ "$(awk '{print $3}' "/proc/$foreign_pid/stat")" != Z ]] || break
            sleep 0.1
        done
        if [[ -r "/proc/$foreign_pid/cmdline" ]] && tr '\0' '\n' < "/proc/$foreign_pid/cmdline" | grep -Fx "$root/foreign" >/dev/null; then
            kill -KILL -- "-$foreign_pid" 2>/dev/null || true
        fi
        wait "$foreign_pid" || true
    fi
    foreign_pid=
}
cleanup() {
    result=$?
    trap - EXIT
    stop_foreign
    t3-code-start >/dev/null || true
    if [[ "$result" == 0 ]]; then rm -rf "$root"; else echo "Stress failure logs retained at $root" >&2; fi
    exit "$result"
}
trap cleanup EXIT
identity=$(sha256sum "$state/userdata/environment-id")
t3-code-stop
mkdir "$root/foreign"
cp -a "$state/userdata" "$root/foreign/userdata"
nohup setsid env T3CODE_HOME="$root/foreign" t3 start --mode desktop --host 127.0.0.1 --port "$T3_PORT" --base-dir "$root/foreign" --no-browser /workspace > "$root/foreign.log" 2>&1 </dev/null &
foreign_pid=$!
for _attempt in {1..600}; do
    curl --max-time 2 -sf "http://127.0.0.1:$T3_PORT/" >/dev/null && break
    sleep 0.1
done
curl --max-time 2 -sf "http://127.0.0.1:$T3_PORT/" >/dev/null
echo "Standalone foreign T3 is ready; testing ownership rejection."
if t3-code-start > "$root/rejected-start" 2>&1; then echo 'Accepted an unmanaged endpoint.' >&2; exit 1; fi
if t3-code-status > "$root/rejected-status" 2>&1; then echo 'Reported an unmanaged endpoint as healthy.' >&2; exit 1; fi
if t3-code-stop > "$root/rejected-stop" 2>&1; then echo 'Accepted an unmanaged endpoint for shutdown.' >&2; exit 1; fi
kill -0 "$foreign_pid"
stop_foreign
for round in $(seq 1 "${ROUNDS:-20}"); do
    t3-code-stop
    workers=()
    for worker in {1..10}; do
        t3-code-start > "$root/start-$worker" 2>&1 &
        workers+=("$!")
    done
    for worker in "${workers[@]}"; do wait "$worker"; done
    t3-code-status > "$root/status"
    count=$(pgrep -u "$(id -u)" -fc '^bash /usr/local/bin/t3-code-run$')
    [[ "$count" == 1 ]]
    [[ "$(sha256sum "$state/userdata/environment-id")" == "$identity" ]]
    for _request in {1..10}; do curl -sf "http://127.0.0.1:$T3_PORT/" -o /dev/null; done
    printf 'Round %s: 10 concurrent starts, one supervisor, 10 HTTP requests, identity preserved.\n' "$round"
done
for browser in {1..10}; do t3-code-browser-check > "$root/browser-$browser"; done
printf 'PASS: unmanaged endpoint rejected; %s restart rounds; 10 sandboxed Chrome renders.\n' "${ROUNDS:-20}"
