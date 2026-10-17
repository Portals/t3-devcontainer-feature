#!/usr/bin/env bash
set -euo pipefail
source /etc/t3-code.env
[[ "$(id -un)" == "$T3_DEV_USER" && "$(id -u)" != 0 ]]
[[ "$PWD" == /workspace ]]
for _attempt in {1..60}; do
    if t3-code-status >/dev/null 2>&1; then break; fi
    sleep 1
done
t3-code-status
fallback=$(cat /usr/local/share/t3-code/fallback)
[[ -x "$fallback" && -r "$(dirname "$fallback")/.install-complete" ]]
"$fallback" --version
[[ -d "$T3CODE_HOME/worktrees" && -w "$T3CODE_HOME/worktrees" ]]
curl --silent --show-error --fail --max-time 5 "http://127.0.0.1:$T3_PORT/" >/dev/null
t3-code-browser-check
pid=$(cat "$T3CODE_HOME/run/server.pid")
[[ "$(ps -o user= -p "$pid" | xargs)" == "$T3_DEV_USER" ]]
[[ "$(readlink "/proc/$pid/cwd")" == /workspace ]]
tr '\0' ' ' < "/proc/$pid/cmdline" | grep -F 't3-code-run' >/dev/null
[[ -r "$HOME/.agents/skills/worktree-cleanup/SKILL.md" ]]
echo 'Non-root server, workspace, state volume, browser, and cleanup skill checks passed.'
