state=${T3CODE_HOME:-/var/lib/t3-code}

t3_supervisor_pid() {
    local pid
    [[ -r "$state/run/server.pid" ]] || return 1
    read -r pid < "$state/run/server.pid"
    [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/cmdline" ]] || return 1
    [[ "$(stat -c %u "/proc/$pid")" == "$(id -u "$T3_DEV_USER")" ]] || return 1
    tr '\0' '\n' < "/proc/$pid/cmdline" | grep -Eq '(^|/)t3-code-run$' || return 1
    [[ "$(ps -o pgid= -p "$pid" | xargs)" == "$pid" ]] || return 1
    printf '%s\n' "$pid"
}

t3_listener_inodes() {
    local port
    printf -v port '%04X' "$T3_PORT"
    awk -v port="$port" '$4 == "0A" { split($2, address, ":"); if (address[2] == port) print $10 }' /proc/net/tcp /proc/net/tcp6
}

t3_server_ready() {
    local pid member descriptor target inode
    local -a inodes members
    pid=$(t3_supervisor_pid) || return 1
    mapfile -t inodes < <(t3_listener_inodes)
    [[ "${#inodes[@]}" -gt 0 ]] || return 1
    mapfile -t members < <(ps -eo pid=,pgid= | awk -v group="$pid" '$2 == group { print $1 }')
    for member in "${members[@]}"; do
        for descriptor in /proc/"$member"/fd/*; do
            target=$(readlink "$descriptor" 2>/dev/null) || continue
            for inode in "${inodes[@]}"; do
                if [[ "$target" == "socket:[$inode]" ]]; then
                    curl --silent --fail --max-time 2 "http://127.0.0.1:$T3_PORT/" >/dev/null
                    return "$?"
                fi
            done
        done
    done
    return 1
}
