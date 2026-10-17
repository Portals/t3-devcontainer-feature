#!/usr/bin/env bash
set -euo pipefail
fixture="$T3CODE_HOME/worktrees/feature-smoke"
linked="$T3CODE_HOME/worktrees/feature-smoke-linked"
marker="$linked/feature-smoke-persistence.txt"
case "${1:-}" in
    prepare)
        [[ ! -e "$fixture" && ! -e "$linked" ]]
        git clone --quiet --depth 1 https://github.com/octocat/Hello-World.git "$fixture"
        git -C "$fixture" worktree add --detach "$linked" HEAD
        printf 'persistent worktree edit\n' > "$marker"
        printf 'persistent home state\n' > "$HOME/.t3-feature-persistence-check"
        ;;
    verify)
        [[ "$(cat "$marker")" == 'persistent worktree edit' ]]
        [[ "$(cat "$HOME/.t3-feature-persistence-check")" == 'persistent home state' ]]
        [[ "$(git -C "$linked" rev-parse --git-common-dir)" == "$fixture/.git" ]]
        git -C "$linked" status --short
        echo 'Linked worktree and its uncommitted edit persisted.'
        ;;
    cleanup)
        [[ "$(cat "$marker")" == 'persistent worktree edit' ]]
        rm "$marker"
        rm "$HOME/.t3-feature-persistence-check"
        git -C "$fixture" worktree remove "$linked"
        rm -rf "$fixture"
        ;;
    *) echo 'Usage: test/persistence.sh prepare|verify|cleanup' >&2; exit 1 ;;
esac
