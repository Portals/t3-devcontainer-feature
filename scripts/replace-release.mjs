// One-time replacement requested by the repository owner. Never runs on normal releases.
import fs from 'node:fs';
const repository = 'Portals/t3-devcontainer-feature';
if (process.env.GITHUB_REPOSITORY !== repository || process.env.GITHUB_REF !== 'refs/heads/main') throw new Error('Replacement is restricted to this repository on main.');
const version = JSON.parse(fs.readFileSync('src/t3-code-server/devcontainer-feature.json')).version;
if (version !== '1.0.0') throw new Error('Only the original 1.0.0 release can be replaced.');
const oldDigest = 'sha256:16656ba4139035adf160ad87c3d3ecfd9273d9cc20490b2a6a3c3ff042402eea';
const packagePath = '/users/Portals/packages/container/t3-devcontainer-feature%2Ft3-code-server';
async function api(endpoint, method = 'GET', missing = false) {
    const response = await fetch('https://api.github.com' + endpoint, {
        method, headers: {Accept:'application/vnd.github+json', Authorization:`Bearer ${process.env.GITHUB_TOKEN}`},
        signal:AbortSignal.timeout(30000)
    });
    if (missing && response.status === 404) return null;
    if (!response.ok) {
        const detail = await response.json().catch(() => ({}));
        throw new Error(`${method} ${endpoint}: HTTP ${response.status} ${detail.message ?? ''}`);
    }
    return response.status === 204 ? null : response.json();
}
const versions = [];
for (let page=1;page<=100;page++) {
    const batch = await api(`${packagePath}/versions?per_page=100&page=${page}`);
    versions.push(...batch); if (batch.length<100) break;
}
const tagged = versions.filter(item => item.metadata?.container?.tags?.includes(version));
if (tagged.length>1 || (tagged.length && tagged[0].name!==oldDigest)) throw new Error('The published version differs from the explicitly approved original; refusing to delete it.');
const tag = `feature_t3-code-server_${version}`;
const reference = await api(`/repos/${repository}/git/ref/tags/${tag}`, 'GET', true);
if (reference && reference.object.sha !== 'f2277d790cdbaa8df2cb57c35733c9fe17e26b7d') throw new Error('Release tag changed; refusing to delete it.');
const release = await api(`/repos/${repository}/releases/tags/${tag}`, 'GET', true);
if (tagged.length) {
    // GHCR rejects deleting the last version separately. Delete the package only
    // when its sole version is the exact original digest approved above.
    if (versions.length === 1 && versions[0].name === oldDigest) await api(packagePath, 'DELETE');
    else await api(`${packagePath}/versions/${tagged[0].id}`, 'DELETE');
}
if (release) await api(`/repos/${repository}/releases/${release.id}`, 'DELETE');
if (reference) await api(`/repos/${repository}/git/refs/tags/${tag}`, 'DELETE');
console.log('Original t3-code-server 1.0.0 package version and tag removed; ready to publish replacement.');
