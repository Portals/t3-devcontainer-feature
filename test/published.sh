#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/t3-ghcr-smoke-XXXXXX")
cleanup() {
    result=$?
    trap - EXIT
    container=$(docker ps -aq --filter "label=devcontainer.local_folder=$scratch")
    if [[ -n "$container" && "$container" != *$'\n'* ]]; then
        docker inspect --format '{{json .Mounts}}' "$container" > "$scratch/mounts.json"
        docker stop --time 30 "$container" || true
        docker rm --volumes "$container"
        while IFS= read -r volume; do
            if [[ -z "$(docker ps -aq --filter "volume=$volume")" ]]; then docker volume rm "$volume"; fi
        done < <(jq -r '.[] | select(.Type == "volume" and (.Destination == "/var/lib/t3-code" or .Destination == "/home/vscode")) | .Name' "$scratch/mounts.json")
    elif [[ "$container" == *$'\n'* ]]; then
        echo 'Unexpected multiple smoke containers; preserving them for inspection.' >&2
        result=1
    fi
    rm -rf "$scratch"
    exit "$result"
}
trap cleanup EXIT
mkdir "$scratch/.devcontainer"
node - "$root" "$scratch" <<'JS'
const fs = require('node:fs');
const [root, scratch] = process.argv.slice(2);
const config = JSON.parse(fs.readFileSync(`${root}/examples/ghcr-devcontainer.json`, 'utf8'));
const { version } = JSON.parse(fs.readFileSync(`${root}/src/t3-code-server/devcontainer-feature.json`, 'utf8'));
config.features = { [`ghcr.io/portals/t3-devcontainer-feature/t3-code-server:${version}`]: { channel: 'nightly', autoUpdate: false } };
fs.writeFileSync(`${scratch}/.devcontainer/devcontainer.json`, JSON.stringify(config, null, 2) + '\n');
JS
devcontainer up --workspace-folder "$scratch"
devcontainer exec --workspace-folder "$scratch" bash -lc '
    for _attempt in {1..60}; do
        if t3-code-status >/dev/null 2>&1; then exit 0; fi
        sleep 1
    done
    t3-code-status
    tail -80 /var/lib/t3-code/logs/server.log >&2
    exit 1
'
devcontainer exec --workspace-folder "$scratch" bash -lc '
    set -euo pipefail
    [[ "$(id -u)" != 0 ]]
    ! command -v node
    ! command -v npm
    [[ -r "$HOME/.agents/skills/worktree-cleanup/SKILL.md" ]]
    t3-code-browser-check
'
version=$(devcontainer exec --workspace-folder "$scratch" t3 --version | sed -nE 's/^t3 v?([^[:space:]]+)$/\1/p')
[[ -n "$version" ]]
"$root/update.sh" "$scratch" --check --version "$version"
"$root/update.sh" "$scratch" --version "$version"
devcontainer exec --workspace-folder "$scratch" t3-code-status
echo 'PASS: published Feature built, sandboxed browser rendered, and GHCR configuration worked with the runtime updater.'
