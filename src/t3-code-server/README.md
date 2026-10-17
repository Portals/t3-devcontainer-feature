
# T3 Code Server (t3-code-server)

Project-independent T3 server with a prepared sandboxed browser and persistent worktrees.

## Example Usage

```json
"features": {
    "ghcr.io/portals/t3-devcontainer-feature/t3-code-server:1": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| version | Exact T3 runtime version, or latest to follow channel. Exact versions remain pinned at startup. | string | latest |
| channel | T3 release channel, resolved from published releases. | string | stable |
| autoUpdate | Check for a newer runtime on container startup. Updates restart only T3 and persist without rebuilding the container. | boolean | true |
| user | Existing non-root user; automatic uses the devcontainer remoteUser. | string | automatic |
| workspace | Repository path, or auto for /workspace or a single /workspaces checkout. | string | auto |
| port | Container server port. | string | 3773 |
| autoStart | Start the server on every container start. | boolean | true |
| startupUpdateTimeout | Maximum seconds for startup update preparation; activation and rollback finish separately. | string | 120 |
| installerSha256 | Optional SHA-256 required when downloading the official installer; empty follows the current official installer. | string | - |
| repairHomeOwnership | Explicitly repair UID/GID changes within the selected user home, for an opted-in persistent home mount. | boolean | false |

Use an existing non-root `remoteUser` on Debian/Ubuntu, amd64 or arm64. T3 and its sandboxed browser install through the official installer without installing or changing Node.js/npm.

Publish port 3773 on loopback, for example `"runArgs": ["--publish", "127.0.0.1::3773", "--shm-size=1g"]`. Pair the desktop app, then use **Open in this environment's browser** for development URLs.

`version: "latest"` follows `channel` (`stable` or `nightly`); an exact version stays pinned. Startup updates have a preparation-only deadline and preserve the installed runtime on failure. The host `update.sh PROJECT` updates a running server without rebuilding; activation can interrupt T3 tasks. Failed readiness restores the prior runtime and saved state.

The Feature mounts only `/var/lib/t3-code`. Add explicit per-project home/provider mounts when needed; the repository examples include a selected-user home volume. `repairHomeOwnership` opts into UID/GID repair of that selected home. Existing installations with the old `/home` volume should run `migrate-home.sh PROJECT` to review the migration, then `--apply`, before rebuilding.

`t3-code-status --json` reports the installation receipt and last update. `t3-code-prune` previews conservative retention; `--apply` removes only expired attributable artifacts. Unknown caches and recovery data remain protected.

Chrome retains its own sandbox. `seccomp=unconfined` permits browser user namespaces; no privileged mode or extra capabilities are requested. A tighter host-provided seccomp policy requires separate compatibility validation.

When combined with Docker-in-Docker, that other Feature requests privileged mode. On Ubuntu hosts with AppArmor's unprivileged-user-namespace restriction, privileged containers can lose Chrome's usable namespace sandbox. Configure a suitable host AppArmor/user-namespace policy before combining these Features. The CI Docker composition job permits user namespaces on its disposable runner and restores the original policy afterward; the T3 Feature never changes host policy or disables Chrome's sandbox.

T3 product telemetry is disabled by default through `containerEnv.T3CODE_TELEMETRY_ENABLED="false"`. The examples set it explicitly too. Recreate existing containers to apply this environment default; updating the T3 runtime alone does not change their environment.


---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/Portals/t3-devcontainer-feature/blob/main/src/t3-code-server/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
