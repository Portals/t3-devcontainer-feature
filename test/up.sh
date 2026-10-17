#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
if [[ ! -f "$root/.devcontainer/devcontainer.json" ]]; then
    "$root/setup.sh" "$root"
fi
feature=$(node - "$root/.devcontainer/devcontainer.json" <<'NODE'
const fs = require('node:fs');
const { features = {} } = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const keys = Object.keys(features).filter(key => ['./features/t3-code-server', './features/t3-code'].includes(key));
if (keys.length !== 1) throw new Error('Expected one local T3 Code Server feature.');
process.stdout.write(keys[0].split('/').pop());
NODE
)
mkdir -p "$root/.devcontainer/features/$feature"
cp -R "$root/src/t3-code-server/." "$root/.devcontainer/features/$feature/"
devcontainer up --workspace-folder "$root" "$@"
