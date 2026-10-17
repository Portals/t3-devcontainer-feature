Use an existing non-root `remoteUser` on Debian/Ubuntu, amd64 or arm64. T3 and its sandboxed browser install through the official installer without installing or changing Node.js/npm.

Publish port 3773 on loopback, for example `"runArgs": ["--publish", "127.0.0.1::3773", "--shm-size=1g"]`. Pair the desktop app, then use **Open in this environment's browser** for development URLs.

`version: "latest"` follows `channel` (`stable` or `nightly`); an exact version stays pinned. Startup updates have a preparation-only deadline and preserve the installed runtime on failure. The host `update.sh PROJECT` updates a running server without rebuilding; activation can interrupt T3 tasks. Failed readiness restores the prior runtime and saved state.

The Feature mounts only `/var/lib/t3-code`. Add explicit per-project home/provider mounts when needed; the repository examples include a selected-user home volume. `repairHomeOwnership` opts into UID/GID repair of that selected home. Existing installations with the old `/home` volume should run `migrate-home.sh PROJECT` to review the migration, then `--apply`, before rebuilding.

`t3-code-status --json` reports the installation receipt and last update. `t3-code-prune` previews conservative retention; `--apply` removes only expired attributable artifacts. Unknown caches and recovery data remain protected.

Chrome retains its own sandbox. `seccomp=unconfined` permits browser user namespaces; no privileged mode or extra capabilities are requested. A tighter host-provided seccomp policy requires separate compatibility validation.

When combined with Docker-in-Docker, that other Feature requests privileged mode. On Ubuntu hosts with AppArmor's unprivileged-user-namespace restriction, privileged containers can lose Chrome's usable namespace sandbox. Configure a suitable host AppArmor/user-namespace policy before combining these Features. The CI Docker composition job permits user namespaces on its disposable runner and restores the original policy afterward; the T3 Feature never changes host policy or disables Chrome's sandbox.

T3 product telemetry is disabled by default through `containerEnv.T3CODE_TELEMETRY_ENABLED="false"`. The examples set it explicitly too. Recreate existing containers to apply this environment default; updating the T3 runtime alone does not change their environment.
