import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { parseJSONC } from './jsonc.mjs';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
function invoke(command, args) {
    const result = spawnSync(command, args, { encoding: 'utf8', timeout: 60000 });
    if (result.error) throw result.error;
    if (result.status !== 0) throw new Error(`${command} failed: ${result.stderr.trim()}`);
    return result.stdout.trim();
}
function target(mount) {
    if (typeof mount !== 'string') return mount.target;
    const fields = Object.fromEntries(mount.split(',').map(field => {
        const index = field.indexOf('='); return [field.slice(0,index),field.slice(index+1)];
    }));
    return fields.target ?? fields.dst ?? fields.destination;
}
function main() {
    const args = process.argv.slice(2);
    const apply = args.includes('--apply');
    const local = args.includes('--local');
    const projects = args.filter(arg => !['--apply','--local'].includes(arg));
    if (projects.length !== 1 || projects[0].startsWith('-')) throw new Error('Usage: ./migrate-home.sh PROJECT [--apply] [--local]');
    const project = fs.realpathSync(projects[0]);
    const configuration = JSON.parse(invoke('devcontainer', ['read-configuration','--workspace-folder',project])).configuration;
    const configPath = configuration.configFilePath.fsPath;
    if (fs.lstatSync(configPath).isSymbolicLink()) throw new Error('Use a regular configuration file for migration.');
    const original = fs.readFileSync(configPath, 'utf8');
    const config = parseJSONC(original);
    const features = Object.keys(config.features ?? {}).filter(key => {
        if (/^ghcr\.io\/portals\/t3-devcontainer-feature\/t3-code(?:-server)?(?::[^@]+|@sha256:[a-f0-9]{64})?$/.test(key)) return true;
        if (!key.startsWith('./')) return false;
        const metadata = JSON.parse(fs.readFileSync(path.resolve(path.dirname(configPath),key,'devcontainer-feature.json'),'utf8'));
        return ['t3-code','t3-code-server'].includes(metadata.id);
    });
    if (features.length !== 1) throw new Error('Expected one T3 feature.');
    const oldKey = features[0];
    const ids = invoke('docker',['ps','-q','--filter',`label=devcontainer.local_folder=${project}`,'--filter',`label=devcontainer.config_file=${configPath}`]).split(/\s+/).filter(Boolean);
    if (ids.length !== 1) throw new Error('Start the existing project container first; migration needs its exact home-volume identity.');
    const info = JSON.parse(invoke('docker',['inspect',ids[0]]))[0];
    const home = invoke('docker',['exec','-u','0',ids[0],'bash','-c','source /etc/t3-code.env; printf "%s" "$T3_DEV_HOME"']);
    const mounts = info.Mounts.filter(m => m.Type==='volume' && (home===m.Destination || home.startsWith(m.Destination+'/'))).sort((a,b)=>b.Destination.length-a.Destination.length);
    if (!mounts.length) throw new Error('The running user home has no persistent named volume to migrate. Configure a home/provider mount explicitly before rebuilding.');
    const volume = mounts[0];
    const homeMount = { source: volume.Name, target: volume.Destination, type: 'volume' };
    config.mounts = [...(config.mounts ?? []).filter(m => target(m)!==volume.Destination), homeMount];
    const localFeature = local || oldKey.startsWith('./');
    const destination = path.join(project,'.devcontainer','features','t3-code-server');
    const newKey = localFeature ? './'+path.relative(path.dirname(configPath),destination).split(path.sep).join('/') : 'ghcr.io/portals/t3-devcontainer-feature/t3-code-server:1';
    const settings = { ...config.features[oldKey], repairHomeOwnership:true };
    delete config.features[oldKey]; config.features[newKey] = settings;
    const plan = { mode:apply?'apply':'dry-run',config:configPath,from:oldKey,to:newKey,homeMount,repairSelectedHomeOwnership:true,rebuild:false };
    if (!apply) { console.log(JSON.stringify(plan,null,2)); return; }
    if (fs.readFileSync(configPath,'utf8')!==original) throw new Error('Configuration changed during review; retry.');
    const backup = path.join(path.dirname(configPath),`.t3-migration-${Date.now()}-${crypto.randomBytes(4).toString('hex')}`);
    fs.mkdirSync(backup,{mode:0o700});
    fs.writeFileSync(path.join(backup,'.gitignore'),'*\n');
    fs.writeFileSync(path.join(backup,path.basename(configPath)),original,{mode:fs.statSync(configPath).mode & 0o777});
    let replaced = false, hadDestination = false;
    const staged = destination+`.migration-${crypto.randomBytes(4).toString('hex')}`;
    const temporary = configPath+`.migration-${crypto.randomBytes(4).toString('hex')}`;
    try {
        if (localFeature) {
            fs.mkdirSync(path.dirname(destination),{recursive:true});
            if (fs.existsSync(destination)) {
                if (fs.lstatSync(destination).isSymbolicLink()) throw new Error('Refusing a symlink feature destination.');
                hadDestination=true;
                fs.cpSync(destination,path.join(backup,'feature'),{recursive:true});
            }
            fs.cpSync(path.join(root,'src','t3-code-server'),staged,{recursive:true});
            if (hadDestination) fs.renameSync(destination,path.join(backup,'replaced-feature'));
            fs.renameSync(staged,destination); replaced=true;
        }
        fs.writeFileSync(temporary,JSON.stringify(config,null,2)+'\n',{mode:fs.statSync(configPath).mode & 0o777});
        fs.renameSync(temporary,configPath);
    } catch (error) {
        if (replaced) fs.rmSync(destination,{recursive:true,force:true});
        if (hadDestination && fs.existsSync(path.join(backup,'replaced-feature'))) fs.renameSync(path.join(backup,'replaced-feature'),destination);
        throw error;
    } finally {
        fs.rmSync(staged,{recursive:true,force:true}); fs.rmSync(temporary,{force:true});
    }
    console.log(JSON.stringify({...plan,backup},null,2));
}
try { main(); } catch (error) { console.error(error.message); process.exitCode=1; }
