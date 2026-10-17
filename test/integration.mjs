import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const repo = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const mode = process.argv[2] ?? 'core';
const runId = `t3-test-${mode}-${crypto.randomBytes(6).toString('hex')}`;
const scratch = fs.realpathSync(fs.mkdtempSync(path.join(process.env.RUNNER_TEMP ?? os.tmpdir(), `${runId}-`)));
const evidenceDir = process.env.T3_TEST_EVIDENCE ?? path.join(repo,'test','.work');
fs.mkdirSync(evidenceDir,{recursive:true});
const manifestPath = path.join(evidenceDir,`${runId}.json`);
const manifest = {runId,mode,scratch,daemon:null,containers:[],volumes:[],images:[],status:'active',checks:[]};
const projects=[];
const save=()=>fs.writeFileSync(manifestPath,JSON.stringify(manifest,null,2)+'\n');
const assert=(condition,message)=>{if(!condition)throw new Error(message);};
function run(command,args,{allowFailure=false,stream=false,timeout=1800000,input}={}) {
    const r=spawnSync(command,args,stream?{stdio:'inherit',timeout}:{encoding:'utf8',timeout,input,maxBuffer:8*1024*1024});
    if(r.error)throw r.error;
    if(r.status!==0&&!allowFailure)throw new Error(`${command} ${args[0]} failed (${r.status}): ${r.stderr?.trim()??''} ${r.stdout?.slice(-6000)??''}`);
    return {ok:r.status===0,code:r.status,out:r.stdout?.trim()??''};
}
function checkpoint(name){manifest.checks.push(name);save();console.log(`PASS: ${name}`);}
function register() {
    const ids=run('docker',['ps','-aq','--filter',`label=worktree.cleanup.run=${runId}`]).out.split(/\s+/).filter(Boolean);
    for(const id of ids){
        const info=JSON.parse(run('docker',['inspect',id]).out)[0];
        if(!manifest.containers.some(x=>x.id===info.Id))manifest.containers.push({id:info.Id,project:info.Config.Labels['devcontainer.local_folder'],removed:false});
        for(const mount of info.Mounts.filter(m=>m.Type==='volume'))if(!manifest.volumes.some(x=>x.name===mount.Name))manifest.volumes.push({name:mount.Name,target:mount.Destination,disposable:true,removed:false});
        if(!manifest.images.some(x=>x.id===info.Image))manifest.images.push({id:info.Image,disposable:true,removed:false});
    }
    save();
}
function project(name,{channel='stable',version='latest',image=process.env.T3_TEST_IMAGE??'mcr.microsoft.com/devcontainers/base:ubuntu-24.04',custom=false,features={},home=false,legacy=false}={}){
    const directory=path.join(scratch,name);
    fs.mkdirSync(path.join(directory,'.devcontainer','features'),{recursive:true});
    const workspace=path.join(directory,'workspace');fs.mkdirSync(workspace,{mode:0o777});fs.chmodSync(workspace,0o777);
    fs.cpSync(path.join(repo,'test'),path.join(workspace,'tests'),{recursive:true,filter:p=>!p.includes(`${path.sep}.work`)});
    const featureDirectory=path.join(directory,'.devcontainer','features','t3-code-server');
    fs.cpSync(path.join(repo,'src','t3-code-server'),featureDirectory,{recursive:true});
    if(legacy){
        // Reproduce the original storage contract without retaining old Git history.
        const metadataPath=path.join(featureDirectory,'devcontainer-feature.json');
        const metadata=JSON.parse(fs.readFileSync(metadataPath));
        metadata.mounts=JSON.parse(fs.readFileSync(path.join(repo,'test','fixtures','legacy-persistence.json'))).mounts;
        fs.writeFileSync(metadataPath,JSON.stringify(metadata,null,2)+'\n');
    }
    const config={name:`T3 integration ${name}`,image,remoteUser:custom?'builder':'vscode',updateRemoteUserUID:!custom,
      workspaceMount:`source=${workspace},target=/workspace,type=bind`,workspaceFolder:'/workspace',
      features:{...features,['./features/t3-code-server']:
        legacy?{channel,autoUpdate:false}:{channel,version,autoUpdate:version!=='latest',repairHomeOwnership:home}},
      runArgs:['--publish','127.0.0.1::3773','--shm-size=1g','--label',`worktree.cleanup.run=${runId}`]};
    if(image.startsWith('debian:'))config.features={'ghcr.io/devcontainers/features/common-utils:2':{username:'vscode',installZsh:false,installOhMyZsh:false,installOhMyZshConfig:false,upgradePackages:false},...config.features};
    if(custom){
        delete config.image;
        config.build={dockerfile:'Dockerfile',args:{TEST_UID:'1234'}};
        fs.writeFileSync(path.join(directory,'.devcontainer','Dockerfile'),`FROM ${image}\nARG TEST_UID=1234\nRUN useradd -m -u $TEST_UID -d /customHome -s /bin/bash builder\n`);
    }
    if(home)config.mounts=[{source:`${runId}-${name}-home`,target:custom?'/customHome':'/home/vscode',type:'volume'}];
    fs.writeFileSync(path.join(directory,'.devcontainer','devcontainer.json'),JSON.stringify(config,null,2)+'\n');
    const p={directory,config,custom};projects.push(p);return p;
}
function up(p,rebuild=false){
    try{run('devcontainer',['up','--workspace-folder',p.directory,...(rebuild?['--remove-existing-container']:[])],{stream:true});}
    finally{register();}
    const ready=run('devcontainer',['exec','--workspace-folder',p.directory,'bash','-lc','for attempt in {1..180}; do if t3-code-status >/dev/null 2>&1; then exit 0; fi; sleep 1; done; exit 1'],{stream:true,allowFailure:true});
    if(!ready.ok){
        const id=run('docker',['ps','-aq','--filter',`label=worktree.cleanup.run=${runId}`,'--filter',`label=devcontainer.local_folder=${p.directory}`]).out;
        if(id&&!id.includes('\n')){run('docker',['logs','--tail','150',id],{stream:true,allowFailure:true});run('docker',['exec','-u','0',id,'bash','-lc','ps -ef; for log in /tmp/dockerd.log /tmp/containerd.log /var/lib/t3-code/logs/server.log; do if [[ -r "$log" ]]; then echo "$log"; tail -60 "$log"; fi; done'],{stream:true,allowFailure:true});}
        throw new Error('Managed T3 server failed readiness; see startup diagnostics above');
    }
}
function exec(p,command,{allowFailure=false,root=false}={}){
    if(root){
        const id=run('docker',['ps','-q','--filter',`label=worktree.cleanup.run=${runId}`,'--filter',`label=devcontainer.local_folder=${p.directory}`]).out;
        assert(id&&!id.includes('\n'),'Expected one owned test container');
        return run('docker',['exec','-u','0',id,'bash','-lc',command],{allowFailure});
    }
    return run('devcontainer',['exec','--workspace-folder',p.directory,'bash','-lc',command],{allowFailure});
}
function cleanup(){
    register();
    for(const item of manifest.containers){
        if(!run('docker',['inspect',item.id],{allowFailure:true}).ok){item.removed=true;continue;}
        const label=run('docker',['inspect','--format','{{index .Config.Labels "worktree.cleanup.run"}}',item.id]).out;
        assert(label===runId,'Container ownership changed');
        run('docker',['stop','--timeout','30',item.id],{allowFailure:true});
        const r=run('docker',['rm','--volumes',item.id],{allowFailure:true});item.removed=r.ok;
    }
    for(const item of manifest.volumes){
        if(!run('docker',['volume','inspect',item.name],{allowFailure:true}).ok){item.removed=true;continue;}
        if(run('docker',['ps','-aq','--filter',`volume=${item.name}`]).out){item.retained='still attached';continue;}
        item.removed=run('docker',['volume','rm',item.name],{allowFailure:true}).ok;
    }
    for(const item of manifest.images){
        if(run('docker',['ps','-aq','--filter',`ancestor=${item.id}`]).out){item.retained='still used';continue;}
        item.removed=run('docker',['image','rm',item.id],{allowFailure:true}).ok;
    }
    fs.rmSync(scratch,{recursive:true,force:true});save();
    assert(manifest.containers.every(item=>item.removed),'Owned test containers remain; inspect the manifest');
    assert(manifest.volumes.every(item=>item.removed),'Owned test volumes remain; inspect the manifest');
}
async function main(){
    manifest.daemon=run('docker',['context','show']).out;save();
    if(mode==='prebuilt'){
        const context=path.join(scratch,'image');fs.mkdirSync(context);
        fs.cpSync(path.join(repo,'src','t3-code-server'),path.join(context,'feature'),{recursive:true});
        fs.writeFileSync(path.join(context,'Dockerfile'),'FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04\nCOPY feature /tmp/feature\nRUN cd /tmp/feature && _REMOTE_USER=vscode USER=automatic VERSION=0.1.0 AUTOUPDATE=false bash install.sh && rm -rf /tmp/feature\n');
        const image=runId+':base';run('docker',['build','--tag',image,context],{stream:true});
        manifest.images.push({id:run('docker',['image','inspect','--format','{{.Id}}',image]).out,disposable:true,removed:false});save();
        const original=run('docker',['run','--rm','--entrypoint','bash',image,'-lc','cat "$(dirname "$(cat /usr/local/share/t3-code/fallback)")/.install-receipt.json"']).out;
        const p=project('reused-image',{image,version:'0.1.0'});up(p);
        assert(exec(p,'cat "$(dirname "$(cat /usr/local/share/t3-code/fallback)")/.install-receipt.json"').out===original,'Reapplying feature replaced its verified runtime');
        const q=project('changed-image',{image,channel:'nightly'});up(q);
        exec(q,'[[ "$(find /usr/local/share/t3-code/image-runtimes -mindepth 1 -maxdepth 1 -type d | wc -l)" == 2 ]]');
        assert(JSON.parse(exec(q,'t3-code-status --json').out).receipt.version!=='0.1.0','Changed options reused the wrong runtime');
        checkpoint('prebuilt image reuses a verified runtime and supports changed options');return;
    }
    if(mode==='migration'){

        const p=project('legacy',{legacy:true});up(p);
        exec(p,'printf legacy-home > "$HOME/.t3-migration-test"; mkdir -p "$T3CODE_HOME/userdata"; printf legacy-state > "$T3CODE_HOME/userdata/.t3-migration-test"');
        const configPath=path.join(p.directory,'.devcontainer','devcontainer.json');const before=fs.readFileSync(configPath,'utf8');
        const dry=JSON.parse(run('node',[path.join(repo,'scripts/migrate-home.mjs'),p.directory,'--local']).out);
        assert(dry.mode==='dry-run'&&fs.readFileSync(configPath,'utf8')===before,'Migration dry-run changed the configuration');
        run('node',[path.join(repo,'scripts/migrate-home.mjs'),p.directory,'--local','--apply'],{stream:true});
        up(p,true);
        exec(p,'[[ "$(cat "$HOME/.t3-migration-test")" == legacy-home && "$(cat "$T3CODE_HOME/userdata/.t3-migration-test")" == legacy-state ]]');
        checkpoint('v1 home/state volumes survive the backed-up configuration migration');
        return;
    }
    const features=mode==='node-java'?{
      'ghcr.io/devcontainers/features/node:2':{version:'20',nodeGypDependencies:false,pnpmVersion:'none'},
      'ghcr.io/devcontainers/features/java:1':{version:'25',jdkDistro:'tem'}
    }:mode==='docker'?{'ghcr.io/devcontainers/features/docker-in-docker:4':{}}:{};
    const p=project(mode,{channel:process.env.T3_TEST_CHANNEL??'stable',version:mode==='contracts'?'0.1.0':'latest',custom:mode==='node-java'||mode==='uid',home:mode==='contracts'||mode==='uid',features});
    up(p);
    const status=JSON.parse(exec(p,'t3-code-status --json').out);
    assert(status.ready&&status.receipt?.verification.apiMatchesReleaseChecksum,'Missing ready server or verification receipt');
    assert(status.receipt.bootstrap.sha256.length===64,'Missing bootstrap digest');
    exec(p,'t3-code-browser-check');checkpoint('non-root server, sandboxed browser and verification receipt');
    if(mode==='node-java'){
        exec(p,'[[ "$(id -un)" == builder && "$HOME" == /customHome ]]; node --version | grep "^v20\\."; java --version | grep "^openjdk 25"');
        checkpoint('Node 20 and Java 25 coexist with T3 under a custom user/home');return;
    }
    if(mode==='docker'){
        exec(p,'for attempt in {1..60}; do if timeout 10 docker info >/dev/null 2>&1; then exit 0; fi; sleep 1; done; exit 1');
        checkpoint('Docker-in-Docker entrypoint composition and non-root engine access');return;
    }
    if(mode==='uid'){
        exec(p,'mkdir -p "$T3CODE_HOME/userdata"; printf saved > "$T3CODE_HOME/userdata/uid-test"; printf saved > "$HOME/uid-test"');
        p.config.build.args.TEST_UID='2345';fs.writeFileSync(path.join(p.directory,'.devcontainer','devcontainer.json'),JSON.stringify(p.config,null,2)+'\n');
        up(p,true);
        exec(p,'[[ "$(id -u)" == 2345 && "$(cat "$HOME/uid-test")" == saved && "$(cat "$T3CODE_HOME/userdata/uid-test")" == saved ]]; [[ "$(stat -c %u "$HOME/uid-test")" == 2345 && "$(stat -c %u "$T3CODE_HOME/userdata/uid-test")" == 2345 ]]; [[ "$(stat -c %u /home/vscode)" == 1000 ]]');
        checkpoint('persistent custom home and T3 state survive UID changes without changing another user home');return;
    }
    exec(p,'if command -v node || command -v npm; then exit 1; fi');
    if(mode==='contracts'){
        assert(status.configuredVersion==='0.1.0'&&status.receipt.version==='0.1.0','Startup ignored the configured pin');
        run('node',[path.join(repo,'scripts/update.mjs'),p.directory,'--check'],{stream:true});
        exec(p,'sudo apt-get update >/dev/null && sudo apt-get install -y --no-install-recommends gcc >/dev/null');
        // Reapply the image installer with a changed pin, then repeat it to verify reuse.
        const source=path.join(p.directory,'.devcontainer','features','t3-code-server');
        fs.cpSync(source,path.join(p.directory,'workspace','feature'),{recursive:true});
        exec(p,'cd /workspace/feature; _REMOTE_USER=vscode USER=automatic VERSION=0.1.0 AUTOUPDATE=false REPAIRHOMEOWNERSHIP=true bash install.sh; first=$(cat /usr/local/share/t3-code/fallback); receipt=$(sha256sum "$(dirname "$first")/.install-receipt.json"); _REMOTE_USER=vscode USER=automatic VERSION=0.1.0 AUTOUPDATE=false REPAIRHOMEOWNERSHIP=true bash install.sh; [[ "$(cat /usr/local/share/t3-code/fallback)" == "$first" && "$(sha256sum "$(dirname "$first")/.install-receipt.json")" == "$receipt" ]]',{root:true});
        checkpoint('verified build-time reuse preserves the installation receipt');
        exec(p,'bash /workspace/tests/preparation-timeout.sh');checkpoint('preparation deadline preserves server/state and records a deferred result');
        exec(p,'bash /usr/local/share/t3-code/runtime-update.sh nightly');
        const updated=JSON.parse(exec(p,'t3-code-status --json').out);
        assert(updated.receipt.version!=='0.1.0'&&updated.lastUpdate.status==='updated','Changed-version update did not activate');
        exec(p,'bash /usr/local/share/t3-code/runtime-update.sh 0.1.0; bash /usr/local/share/t3-code/runtime-update.sh nightly');
        exec(p,'bash /workspace/tests/update-failure-stress.sh 0.1.0');checkpoint('changed-version update, cache corruption rejection and deterministic post-activation rollback');
        exec(p,'bash /workspace/tests/prune.sh');checkpoint('retention protects active/rollback/runtime recovery, live browsers, unknown data and worktrees');
        run('node',[path.join(repo,'scripts/update.mjs'),p.directory],{stream:true});
        const pinned=JSON.parse(exec(p,'t3-code-status --json').out);assert(pinned.receipt.version==='0.1.0','Host updater ignored configured pin');
        checkpoint('host updater applies the configured exact version without rebuilding');
        run('node',[path.join(repo,'scripts/update.mjs'),p.directory,'--version',updated.receipt.version],{stream:true});
        exec(p,'sed -i "s/^T3_AUTO_UPDATE=.*/T3_AUTO_UPDATE=false/" /etc/t3-code.env; bash /usr/local/share/t3-code/container-entrypoint.sh',{root:true});
        assert(JSON.parse(exec(p,'t3-code-status --json').out).receipt.version==='0.1.0','Startup failed to reconcile the exact pin with automatic channel updates disabled');
        checkpoint('exact pin is restored at startup even when automatic channel updates are disabled');
    }
}
try{await main();manifest.status='passed';}
catch(error){manifest.status='failed';manifest.error=error.message;console.error(error.stack);process.exitCode=1;}
finally{try{cleanup();}catch(error){manifest.cleanupError=error.message;save();console.error(error);process.exitCode=1;}console.log(`Evidence: ${manifestPath}`);}
