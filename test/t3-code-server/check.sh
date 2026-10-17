#!/usr/bin/env bash
set -euo pipefail
source /etc/t3-code.env
[[ "$(id -un)" == "$T3_DEV_USER" && "$(id -u)" != 0 ]]
for _attempt in {1..60}; do
    if t3-code-status >/dev/null 2>&1; then break; fi
    sleep 1
done
t3-code-status
fallback=$(cat /usr/local/share/t3-code/fallback)
[[ -x "$fallback" && -r "$(dirname "$fallback")/.install-complete" ]]
version=$("$fallback" --version)
case "$T3_UPDATE_CHANNEL" in
    stable) [[ "$version" =~ ^t3\ v[0-9]+\.[0-9]+\.[0-9]+$ ]] ;;
    nightly) [[ "$version" == *-nightly.* ]] ;;
    *) exit 1 ;;
esac
if command -v node >/dev/null || command -v npm >/dev/null; then
    echo 'The feature unexpectedly installed Node.js/npm.' >&2
    exit 1
fi
[[ -w "$T3CODE_HOME/worktrees" ]]
[[ -r "$HOME/.agents/skills/worktree-cleanup/SKILL.md" ]]
t3-code-browser-check
echo "PASS: $T3_UPDATE_CHANNEL official runtime, non-root server, persistent state, cleanup skill and sandboxed browser."
