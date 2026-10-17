#!/usr/bin/env bash
set -euo pipefail
source_skill=/usr/local/share/t3-code/skills/worktree-cleanup
installed="$HOME/.agents/skills/worktree-cleanup"
cmp "$source_skill/SKILL.md" "$installed/SKILL.md"
cmp "$source_skill/agents/openai.yaml" "$installed/agents/openai.yaml"
[[ "$(stat -c %U "$installed")" == "$(id -un)" ]]
temporary=$(mktemp -d)
cp "$installed/agents/openai.yaml" "$temporary/original.yaml"
trap 'cp "$temporary/original.yaml" "$installed/agents/openai.yaml"; rm -rf "$temporary"' EXIT
printf '\n# Local customization preservation check\n' >> "$installed/agents/openai.yaml"
cp "$installed/agents/openai.yaml" "$temporary/customized.yaml"
sudo env T3_AUTOSTART_OVERRIDE=false /usr/local/share/t3-code/container-entrypoint.sh
cmp "$temporary/customized.yaml" "$installed/agents/openai.yaml"
echo 'Bundled skill installed with correct ownership; existing customization was preserved.'
