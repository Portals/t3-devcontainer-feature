# T3 Code Server devcontainer feature

Run T3 and its sandboxed browser inside a project container on Debian/Ubuntu, amd64 or arm64. The Feature uses the [official standalone installer](https://t3.codes/install.sh); it does not install or change Node.js/npm. Host setup/update helpers use Node.js.

Add the Feature to an existing devcontainer with a non-root `remoteUser`:

```json
"features": {
  "ghcr.io/portals/t3-devcontainer-feature/t3-code-server:1": {
    "channel": "nightly",
    "version": "latest",
    "autoUpdate": true
  }
},
"runArgs": ["--publish", "127.0.0.1::3773", "--shm-size=1g"]
```

[Full configuration](examples/ghcr-devcontainer.json) · [All Feature arguments](src/t3-code-server/README.md)

For a local copy, run `./setup.sh /path/to/project`. Then:

```sh
devcontainer up --workspace-folder /path/to/project
./pair.sh /path/to/project
devcontainer exec --workspace-folder /path/to/project bash
```

Add the pairing URL in the desktop app. Use `exec` to enter the container and start commands, including installing tools you need. The examples choose a free loopback port. Open development URLs with **Open in this environment's browser**. Match the desktop and server release channels.

`channel` accepts `stable` or `nightly`. With `version: "latest"`, startup follows that channel without a new Feature release. An exact `version` pins the runtime at build time, startup and in the host updater. `autoUpdate: false` disables channel checks; an exact pin is still reconciled at startup. `startupUpdateTimeout` defaults to 120 seconds and bounds preparation only; activation and rollback are never force-killed by this deadline.

Update T3 in a running container:

```sh
./update.sh /path/to/project
```

The updater verifies the standalone runtime and matching browser, snapshots T3 state and restarts T3 without rebuilding the container. This can interrupt active T3 tasks and terminals. Failed readiness restores the previous runtime and saved state. `--check` makes no changes (exit 2 means an update is available); `--version VERSION` selects a one-time exact release. `--channel stable|nightly` overrides channel selection when `version` is `latest`; a configured exact pin takes precedence. Editing Feature update arguments and running `update.sh` applies those settings without a rebuild.

The Feature mounts only `/var/lib/t3-code`, preserving T3 history, pairing, browser data, worktrees and runtime recovery data. The examples explicitly mount the selected user's home to retain user-installed tools and provider logins. Set `repairHomeOwnership: true` for that private home volume when UID/GID changes are expected. Other users' homes are left alone. Put system packages in the image or other Features.

**Existing installations:** before rebuilding an old container that mounted all of `/home`, preserve its exact volume:

```sh
./migrate-home.sh /path/to/project          # review the plan
./migrate-home.sh /path/to/project --apply  # back up config and add explicit mount
```

The existing container must be running. Migration retains its named volume without copying or deleting data, saves the original configuration, and does not rebuild. Local Feature users receive the updated source; `--local` also selects a local copy for registry users.

Inside the container, `t3-code-status --json` reports the last update and install receipt. Receipts record the bootstrap script hash and compare GitHub's archive digest with the vendor's `SHA256SUMS`; archive verification is performed by the official installer. Set `installerSha256` to pin the bootstrap script itself. Reapplying the Feature on a prebuilt image verifies and reuses an identical runtime.

`t3-code-prune` previews expired managed runtimes, browser archives and committed backups, retaining the newest three of each. `--keep N --apply` performs cleanup. Active/rollback versions, live browsers, retained-backup dependencies, incomplete recovery and unknown legacy artifacts are protected. Worktrees and user data are never pruning targets. Cleanup is manual.

The bundled `$worktree-cleanup` skill tracks resources owned by individual worktrees and preserves unfinished work and shared environments. It installs into `~/.agents/skills` on first start and preserves customizations. Chrome retains its sandbox; the Feature requests `seccomp=unconfined` to allow user namespaces, without privileged mode. A tighter host seccomp policy needs separate validation.

[GitHub Actions tests](.github/workflows/test.yaml) cover both channels, Ubuntu/Debian, amd64/arm64, persistence, prebuilt image reuse, compatibility and failure recovery. [Run checks locally](test/README.md).

## Publishing

Change the Feature's `version` for subsequent Feature releases; new T3 releases do not require this. Generate the reference with:

```sh
devcontainer features generate-docs --project-folder ./src --namespace portals/t3-devcontainer-feature --github-owner Portals --github-repo t3-devcontainer-feature
```

Run **Release features** on `main`. All tests pass before the official `devcontainers/action` publishes the Feature and version aliases. A fresh registry install then verifies the browser and updater. Publishing uses the repository's scoped `GITHUB_TOKEN`.

The manual `replaceOriginalRelease` flag is restricted to replacing the approved original `t3-code-server` 1.0.0 digest/tag after tests pass; it refuses any other published digest. Normal releases leave it off.

Previously published as `t3-code`; update helpers still recognize that reference in existing configurations. The obsolete package and collection index are removed after publishing, leaving only `t3-code-server` in GHCR.
