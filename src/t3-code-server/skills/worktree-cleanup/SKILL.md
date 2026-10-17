---
name: worktree-cleanup
description: Track and clean up resources owned by Git worktrees when starting or finishing worktree-based tasks, including development servers, disposable databases, containers, and temporary files. Use for worktree teardown and orphaned worktree resources while preserving unfinished work and shared environments.
---

# Worktree cleanup

Keep each worktree's runtime resources accountable from creation through teardown. Apply this workflow when starting work in a worktree and when finishing or explicitly cleaning it up. Respect requests to keep a preview running or retain a checkout for review. A skill guides the agent; it does not run as a background collector or guarantee cleanup after a crash.

## Track ownership as resources start

Identify the absolute worktree path, Git common directory, branch, execution environment, and whether an app manages the worktree. Distinguish newly created resources from anything already running.

Keep a small resource manifest outside the checkout, at `${XDG_STATE_HOME:-$HOME/.local/state}/worktree-cleanup/<run-id>.json`. Record the worktree path and, as applicable:

- Processes: PID, process start identity/time, process group, working directory, and log paths. Use a separate process group for long-running commands when practical.
- Containers, networks, and volumes: exact IDs/names, owning Docker daemon/context, and whether their data is disposable. Label newly created Docker resources with `worktree.cleanup.run=<run-id>` when the launcher supports labels.
- Databases: exact local database/schema or container, disposal policy, and whether another task uses it.
- Temporary files and browser tabs: exact paths or tab IDs created by this task.

Record no credentials or tokens. Preserve an existing manifest when resuming. If attaching to an existing resource, mark it shared or externally owned unless ownership is established. With concurrent worktrees, an unfiltered before/after container list is not proof of ownership.

## Clean runtime resources after verification

Unless the user wants a live preview, stop this task's development servers, watchers, and terminals after their checks finish. Keep the checkout available when the code still needs review.

Use recorded process identities and verify them against the current process before signaling. Prefer graceful termination of the owned process group; wait for shutdown before escalating. A PID or listening port alone is insufficient because either can be reused. Never use a broad process-name kill or kill whatever happens to occupy a port. If ownership is uncertain, leave it running and report the exact uncertainty.

Allow runtime-managed cleanup to finish, then inspect for leftovers. For Testcontainers, let the application's shutdown/reaper remove its disposable services; target only verified containers from this run if any remain. Use the same Docker daemon that created them, which may be inside the development container.

Remove owned disposable containers, networks, volumes, database/schema instances, temporary files, and task-only browser tabs. Verify resources are no longer present. Persistent data needs an explicit disposal instruction; retain it otherwise. Do not stop a shared database or delete another worktree's schema. Never run a global Docker prune or bring down an entire shared Compose project to clean one worktree.

## Decide whether the checkout can be removed

Use `git worktree list --porcelain` and inspect tracked edits, untracked files, ignored files, branch reachability, and active users of the checkout. A clean `git status` does not protect ignored `.env` files, local databases, or valuable generated artifacts.

- Retain unfinished edits and non-disposable ignored files unless the user explicitly authorized their discard or an authorized, verified recovery copy exists. Do not create a commit as a cleanup side effect, especially during a no-commit task.
- Retain a detached checkout whose commits lack a durable reference. Removing a clean branch checkout may be safe when its branch and commits remain available; do not delete that branch as an incidental cleanup action.
- Preserve primary checkouts and worktrees still used by another task, chat, terminal, or preview.

For an app-managed worktree, use its removal/archive mechanism when available, respecting any snapshot-commit behavior and the user's commit restrictions. Otherwise use `git worktree remove` for the verified target. Do not substitute recursive directory deletion, forced removal, reset, or clean for unresolved local changes. Never prune worktree metadata merely because a path on another host/container is unavailable here.

## Shared development containers

Worktrees may share one repository container. Keep that container, its T3 server, history, pairing, credentials, browser profiles, home volume, worktree volume, and shared caches. Remove only resources owned by the completed worktree. A worktree being deleted does not make a repository-wide volume disposable.

A tool's automatic worktree retention policy can complement this skill, but it does not establish ownership of servers or databases. Do not enable automatic removal of dirty worktrees as a substitute for runtime cleanup.

Finish with a concise account of what stopped, what was removed, what was retained and why, and any confirmed leftovers. Mark completed manifest entries instead of silently forgetting retained resources. Do not claim complete cleanup when ownership or verification remains unresolved.
