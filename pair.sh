#!/usr/bin/env bash
set -euo pipefail
project=${1:?Usage: ./pair.sh /absolute/path/to/project}
project=$(cd "$project" && pwd)
container=$(docker ps -q --filter "label=devcontainer.local_folder=$project")
[[ -n "$container" && "$container" != *$'\n'* ]] || { echo 'Expected one running devcontainer for this project.' >&2; exit 1; }
container_port=$(docker exec "$container" bash -c 'source /etc/t3-code.env; printf "%s" "$T3_PORT"')
[[ "$container_port" =~ ^[0-9]+$ ]]
endpoint=$(docker port "$container" "$container_port/tcp")
[[ "$endpoint" =~ ^127\.0\.0\.1:([0-9]+)$ ]] || { echo 'Expected a loopback-only published T3 port.' >&2; exit 1; }
base_url="http://127.0.0.1:${BASH_REMATCH[1]}"
docker exec "$container" bash -c '
    set -euo pipefail
    source /etc/t3-code.env
    exec runuser -u "$T3_DEV_USER" -- env HOME="$T3_DEV_HOME" T3CODE_HOME=/var/lib/t3-code \
        t3 auth pairing create --base-dir /var/lib/t3-code --base-url "$1" --ttl 5m
' bash "$base_url"
