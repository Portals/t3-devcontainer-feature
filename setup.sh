#!/usr/bin/env bash
set -euo pipefail
source_root=$(cd "$(dirname "$0")" && pwd)
command -v node >/dev/null || { echo 'Setup requires Node.js, also used by Dev Container tooling.' >&2; exit 1; }
project=${1:?Usage: ./setup.sh /absolute/path/to/project}
[[ -d "$project" ]] || { echo 'Project directory does not exist.' >&2; exit 1; }
project=$(cd "$project" && pwd)
[[ ! -e "$project/.devcontainer/devcontainer.json" && ! -e "$project/.devcontainer.json" ]] || {
    echo 'An existing devcontainer configuration was found; add src/t3-code-server as a local feature to that configuration.' >&2
    exit 1
}
[[ ! -e "$project/.devcontainer/features/t3-code-server" ]] || { echo 'Feature destination already exists.' >&2; exit 1; }
mkdir -p "$project/.devcontainer/features"
cp -R "$source_root/src/t3-code-server" "$project/.devcontainer/features/t3-code-server"
cp "$source_root/examples/devcontainer.json" "$project/.devcontainer/devcontainer.json"
node - "$project/.devcontainer/devcontainer.json" <<'JS'
const fs = require('node:fs');
const net = require('node:net');
const path = process.argv[2];
const config = JSON.parse(fs.readFileSync(path, 'utf8'));
const listener = net.createServer();
listener.on('error', error => { console.error(error.message); process.exitCode = 1; });
listener.listen(0, '127.0.0.1', () => {
    config.runArgs[1] = `127.0.0.1:${listener.address().port}:3773`;
    listener.close(() => fs.writeFileSync(path, JSON.stringify(config, null, 2) + '\n'));
});
JS
printf 'Configured %s\n' "$project"
