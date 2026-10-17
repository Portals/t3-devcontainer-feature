// Only the two package names explicitly retired by the repository owner.
const repository='Portals/t3-devcontainer-feature';
if(process.env.GITHUB_REPOSITORY!==repository || process.env.GITHUB_REF!=='refs/heads/main') throw new Error('Cleanup is restricted to this repository on main.');
for(const name of ['t3-devcontainer-feature/t3-code','t3-devcontainer-feature']) {
    const url='https://api.github.com/users/Portals/packages/container/'+encodeURIComponent(name);
    const headers={Accept:'application/vnd.github+json',Authorization:`Bearer ${process.env.GITHUB_TOKEN}`};
    const response=await fetch(url,{headers,signal:AbortSignal.timeout(30000)});
    if(response.status===404){console.log(`${name}: already absent`);continue;}
    if(!response.ok)throw new Error(`${name}: metadata HTTP ${response.status}`);
    const metadata=await response.json();
    if(metadata.repository?.full_name?.toLowerCase()!==repository.toLowerCase())throw new Error(`${name}: repository ownership could not be confirmed`);
    const deleted=await fetch(url,{method:'DELETE',headers,signal:AbortSignal.timeout(30000)});
    if(deleted.status!==204)throw new Error(`${name}: deletion HTTP ${deleted.status}`);
    console.log(`${name}: removed`);
}
