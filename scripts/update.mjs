import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const exactVersion = /^\d+\.\d+\.\d+(?:[-+][a-zA-Z0-9.-]+)?$/;
function invoke(command, args, { allowFailure = false, stream = false, input } = {}) {
    const result = spawnSync(command, args, stream ? { stdio: 'inherit' } : { encoding: 'utf8', timeout: 60000, input });
    if (result.error) throw result.error;
    if (result.status !== 0 && !allowFailure) throw new Error(`${command} failed: ${result.stderr?.trim() || result.signal || result.status}`);
    return { ok: result.status === 0, output: result.stdout?.trim() ?? '' };
}
async function publishedVersion(selector) {
    if (!exactVersion.test(selector) && !['stable', 'nightly'].includes(selector)) throw new Error('Use stable, nightly, or an exact version.');
    const base = 'https://api.github.com/repos/pingdotgg/t3code/releases';
    const url = selector === 'nightly' ? `${base}?per_page=20` : selector === 'stable' ? `${base}/latest` : `${base}/tags/v${selector}`;
    const response = await fetch(url, { signal: AbortSignal.timeout(30000), headers: { 'User-Agent': 't3-devcontainer-feature' } });
    if (!response.ok) {
        const reset = response.headers.get('x-ratelimit-reset');
        if (response.status === 403 && response.headers.get('x-ratelimit-remaining') === '0' && /^\d+$/.test(reset ?? '')) {
            throw new Error(`GitHub API rate limit reached; retry after ${new Date(Number(reset) * 1000).toISOString()}. Installed T3 is unchanged.`);
        }
        throw new Error(`Release metadata unavailable (HTTP ${response.status}).`);
    }
    const data = await response.json();
    const release = selector === 'nightly' ? data.find(item => !item.draft && item.prerelease && item.tag_name.includes('-nightly.') &&
        ['linux-arm64', 'linux-x64'].every(arch => item.assets.some(asset => asset.name.endsWith(`-${arch}.tar.gz`) && /^sha256:[a-f0-9]{64}$/.test(asset.digest)))) : data;
    const version = release?.tag_name?.replace(/^v/, '');
    if (!exactVersion.test(version ?? '') || (exactVersion.test(selector) && selector !== version)) throw new Error('No complete matching release found.');
    return version;
}
async function main() {
    const selected = {};
    const args = process.argv.slice(2);
    for (let index = 0; index < args.length; index++) {
        const arg = args[index];
        if (arg === '--check') selected.check = true;
        else if (arg === '--version' || arg === '--channel') {
            const value = args[++index];
            if (!value || value.startsWith('--')) throw new Error(`${arg} requires a value.`);
            selected[arg.slice(2)] = value;
        } else if (!arg.startsWith('-') && !selected.project) selected.project = arg;
        else throw new Error(`Unknown argument: ${arg}`);
    }
    if (!selected.project) throw new Error('Usage: ./update.sh PROJECT [--check] [--channel stable|nightly] [--version VERSION]');
    const project = fs.realpathSync(selected.project);
    const configuration = JSON.parse(invoke('devcontainer', ['read-configuration', '--workspace-folder', project]).output).configuration;
    const configPath = configuration.configFilePath.fsPath;
    const registryFeature = /^ghcr\.io\/portals\/t3-devcontainer-feature\/t3-code(?:-server)?(?::[\w][\w.-]{0,127}|@sha256:[a-f0-9]{64})?$/;
    const features = Object.entries(configuration.features ?? {}).flatMap(([key, settings]) => {
        if (!key.startsWith('./') && !registryFeature.test(key)) return [];
        const directory = key.startsWith('./') ? path.resolve(path.dirname(configPath), key) : path.join(root, 'src/t3-code-server');
        const metadata = JSON.parse(fs.readFileSync(path.join(directory, 'devcontainer-feature.json'), 'utf8'));
        return ['t3-code-server', 't3-code'].includes(metadata.id) ? [{ settings, metadata }] : [];
    });
    if (features.length !== 1) throw new Error('Expected one local or GHCR T3 Code Server feature.');
    const configuredChannel = features[0].settings.channel ?? features[0].metadata.options?.channel?.default ?? 'stable';
    const autoUpdate = features[0].settings.autoUpdate ?? features[0].metadata.options?.autoUpdate?.default ?? true;
    const configuredVersion = features[0].settings.version ?? features[0].metadata.options?.version?.default ?? 'latest';
    const startupTimeout = String(features[0].settings.startupUpdateTimeout ?? features[0].metadata.options?.startupUpdateTimeout?.default ?? '120');
    const installerSha = features[0].settings.installerSha256 ?? '';
    const repairHome = features[0].settings.repairHomeOwnership ?? false;
    if (configuredVersion !== 'latest' && !exactVersion.test(configuredVersion)) throw new Error('version must be latest or an exact runtime version.');
    if (!/^[1-9][0-9]{0,4}$/.test(startupTimeout)) throw new Error('startupUpdateTimeout must be 1–99999 seconds.');
    if (!/^(?:[a-f0-9]{64})?$/.test(installerSha)) throw new Error('Invalid installerSha256.');
    if (typeof repairHome !== 'boolean') throw new Error('repairHomeOwnership must be a boolean.');
    const channel = selected.channel ?? configuredChannel;
    if (![channel, configuredChannel].every(value => ['stable', 'nightly'].includes(value))) throw new Error('channel must be stable or nightly.');
    if (typeof autoUpdate !== 'boolean') throw new Error('autoUpdate must be a boolean.');
    if (selected.version && !exactVersion.test(selected.version)) throw new Error('--version requires an exact version.');
    const target = selected.version ?? (configuredVersion === 'latest' ? await publishedVersion(channel) : configuredVersion);
    const ids = invoke('docker', ['ps', '-q', '--filter', `label=devcontainer.local_folder=${project}`,
        '--filter', `label=devcontainer.config_file=${configPath}`]).output.split(/\s+/).filter(Boolean);
    if (ids.length !== 1) throw new Error('Start the project container first; expected one running container.');
    const id = ids[0];
    const info = JSON.parse(invoke('docker', ['inspect', id]).output)[0];
    const context = JSON.parse(invoke('docker', ['exec', '-u', '0', id, 'bash', '-c',
        'source /etc/t3-code.env; jq -cn --arg user "$T3_DEV_USER" --arg home "$T3_DEV_HOME" --arg state "${T3CODE_HOME:-/var/lib/t3-code}" \'{user:$user,home:$home,state:$state}\'']).output);
    const remote = (script, values = [], options = {}) => invoke('docker', ['exec', '-u', context.user,
        '-e', `HOME=${context.home}`, '-e', `T3CODE_HOME=${context.state}`,
        id, 'bash', '-c', script, 'bash', ...values], options);
    const version = () => remote('t3 --version').output.match(/^t3 v?(\S+)$/m)?.[1];
    console.log(`T3: ${version()} → ${target} (${channel}).`);
    if (selected.check) { process.exitCode = version() === target ? 0 : 2; return; }
    const state = context.state;
    if (!info.Mounts.some(mount => state === mount.Destination || state.startsWith(mount.Destination.replace(/\/$/, '') + '/'))) {
        throw new Error('T3 state needs a persistent mount before updating.');
    }
    const temporary = `/tmp/t3-runtime-update-${crypto.randomBytes(8).toString('hex')}`;
    invoke('docker', ['exec', '-u', '0', id, 'mkdir', '-m', '0755', temporary]);
    try {
        for (const file of ['t3-launcher', 'resolve-version.sh', 'install-runtime.sh', 'install-browser.sh', 'runtime-update.sh', 'runtime-prepare.sh', 'storage-init.sh', 'container-entrypoint.sh', 'server-state.sh', 't3-code-prune', 't3-code-start', 't3-code-stop', 't3-code-status']) {
            invoke('docker', ['exec', '-i', '-u', '0', id, 'bash', '-c',
                'set -e; cat > "$1"; chmod 0644 "$1"', 'bash', `${temporary}/${file}`],
                { input: fs.readFileSync(path.join(root, 'src/t3-code-server', file)) });
        }
        invoke('docker', ['exec', '-u', '0', id, 'bash', '-c', `set -euo pipefail
            source /etc/t3-code.env
            state=\${T3CODE_HOME:-/var/lib/t3-code}
            runuser -u "$T3_DEV_USER" -- env T3CODE_HOME="$state" bash -c '
                mkdir -p "$T3CODE_HOME/runtime"
                touch "$T3CODE_HOME/runtime/update.lock"
            '
            exec 7>"$state/runtime/update.lock"
            flock -n 7 || { echo "Another runtime update is running." >&2; exit 1; }
            support=/usr/local/share/t3-code
            if [[ ! -s "$support/fallback" ]]; then
                original=$(readlink -f /usr/local/bin/t3)
                [[ "$original" != "$support/t3-launcher" && -x "$original" ]]
                printf "%s\\n" "$original" > "$support/fallback"
            fi
            for file in server-state.sh t3-launcher resolve-version.sh install-runtime.sh install-browser.sh runtime-update.sh runtime-prepare.sh storage-init.sh container-entrypoint.sh; do
                install -m 0755 "$1/$file" "$support/$file.new"
                mv -f "$support/$file.new" "$support/$file"
            done
            for file in t3-code-start t3-code-stop t3-code-status t3-code-prune; do
                install -m 0755 "$1/$file" "/usr/local/bin/$file.new"
                mv -f "/usr/local/bin/$file.new" "/usr/local/bin/$file"
            done
            ln -sfn "$support/t3-launcher" /usr/local/bin/t3
            awk "!/^T3_UPDATE_CHANNEL=/ && !/^T3_AUTO_UPDATE=/ && !/^T3_VERSION=/ && !/^T3_STARTUP_UPDATE_TIMEOUT=/ && !/^T3_INSTALLER_SHA256=/ && !/^T3_REPAIR_HOME_OWNERSHIP=/" /etc/t3-code.env > /etc/t3-code.env.new
            printf "T3_UPDATE_CHANNEL=%s\\nT3_AUTO_UPDATE=%s\\n" "$2" "$3" >> /etc/t3-code.env.new
            printf 'T3_VERSION=%q\\nT3_STARTUP_UPDATE_TIMEOUT=%q\\nT3_INSTALLER_SHA256=%q\\nT3_REPAIR_HOME_OWNERSHIP=%q\\n' "$6" "$7" "$8" "$9" >> /etc/t3-code.env.new
            chmod 0644 /etc/t3-code.env.new
            mv -f /etc/t3-code.env.new /etc/t3-code.env

            runuser -u "$T3_DEV_USER" -- env HOME="$T3_DEV_HOME" PATH="$PATH" T3CODE_HOME="$state" T3_UPDATE_LOCK_FD=7 \
                bash /usr/local/share/t3-code/runtime-update.sh "$4" "$5"`,
            'bash', temporary, configuredChannel, String(autoUpdate), target, channel, configuredVersion, startupTimeout, installerSha, String(repairHome)], { stream: true });
        if (version() !== target) throw new Error('Updated binary version does not match the requested release.');
        if (!invoke('docker', ['inspect', '--format', '{{.State.Running}}', id]).output.includes('true')) throw new Error('Container stopped unexpectedly.');
        console.log(`T3 ${target} installed. Container ${id} stayed running.`);
    } finally {
        invoke('docker', ['exec', '-u', '0', id, 'rm', '-rf', temporary], { allowFailure: true });
    }
}
main().catch(error => { console.error(error.message); process.exitCode = 1; });
