/** Local recovery metadata; disk images are never copied, opened or modified. */
import YAML from 'yaml';
import {volumeSource, volumeTarget, volumeReadOnly} from './compose-volumes';
import type {ComposeConfig} from '../types';
const fs:typeof import('fs')=require('fs');
const path:typeof import('path')=require('path');
const crypto:typeof import('crypto')=require('crypto');
export const RECOVERY_FOLDER='.winboat-recovery';
const metadata='vm.json';
const assetNames=['oem','shared-folder-runtime','ApplicationProfiles'];
export type VmRecovery={compose:ComposeConfig; preferences:Record<string,unknown>; storage:string; source:string; disks:string[]; assets:Record<string,string>};
const diskPattern=/^(?:data\d*|windows|system)\.(?:img|qcow2?|raw|vhdx?|vmdk)$/i;
export function existingVmDisks(directory:string):string[]{
 return fs.existsSync(directory)?fs.readdirSync(directory).filter(name=>diskPattern.test(name)):[];
}
function read(file:string):string{
 const st=fs.lstatSync(file);if(!st.isFile()||st.isSymbolicLink()||st.size>16*1024*1024)throw Error('Invalid or oversized VM configuration file.');
 return fs.readFileSync(file,'utf8');
}
function atomic(file:string,value:string):void{
 if(Buffer.byteLength(value)>16*1024*1024)throw Error('VM recovery metadata exceeds the supported size.');
 const temporary=file+'.'+crypto.randomBytes(8).toString('hex');
 try{fs.writeFileSync(temporary,value,{flag:'wx',mode:0o600});fs.renameSync(temporary,file);}finally{fs.rmSync(temporary,{force:true});}
}
function sourcePath(source:string,base:string):string{
 const expanded=source.replace(/\$\$|\$\{HOME\}|\$HOME\b|\$(?:\{[^}]*\}|[A-Za-z_]\w*)/g,token=>{
  if(token==='$$')return '$';
  if(token==='$HOME'||token==='${HOME}')return require('os').homedir();
  throw Error('Unresolved variable in VM mount: '+source);
 });
 return path.resolve(base,expanded);
}
function checkedCompose(value:unknown):ComposeConfig{
 const c=value as ComposeConfig;
 if(!c||typeof c!=='object'||!c.services||Object.keys(c.services).join()!=='windows'||c.services.windows?.container_name!=='WinBoat')throw Error('Select an original WinBoat configuration with one Windows service.');
 const s=c.services.windows;
 if(typeof s.image!=='string'||!s.environment||!Array.isArray(s.volumes)||!Array.isArray(s.ports))throw Error('Incomplete WinBoat VM configuration.');
 if(Object.keys(c).some(k=>!['name','services','volumes','version'].includes(k))||'build' in s||'extends' in s||'env_file' in s)throw Error('External Compose includes, build steps and environment files are not supported for import.');
 if(s.volumes.filter(v=>volumeTarget(v)==='/storage').length!==1)throw Error('Exactly one VM storage folder is required.');
 return c;
}
function storagePath(compose:ComposeConfig,base:string):string{
 const mount=compose.services.windows.volumes.find(v=>volumeTarget(v)==='/storage')!;
 const source=volumeSource(mount);
 if(!source||(!source.startsWith('/')&&!source.startsWith('.')))throw Error('Select a VM using a storage folder. Docker named-volume import is not supported.');
 return sourcePath(source,base);
}
/** Keep a private OEM copy: its originals may disappear with the application configuration. */
function copyAssets(source:string,target:string):void{
 const st=fs.lstatSync(source);if(st.isSymbolicLink())throw Error('Recovery assets must not contain symbolic links.');
 if(st.isDirectory()){
  fs.mkdirSync(target,{recursive:true,mode:0o700});
  if(!fs.lstatSync(target).isDirectory()||fs.lstatSync(target).isSymbolicLink())throw Error('Invalid recovery asset directory.');
  for(const name of fs.readdirSync(target))if(!fs.existsSync(path.join(source,name)))fs.rmSync(path.join(target,name),{recursive:true,force:true});
  for(const name of fs.readdirSync(source))copyAssets(path.join(source,name),path.join(target,name));
 }else if(st.isFile()){
  if(fs.existsSync(target)&&fs.lstatSync(target).isSymbolicLink())throw Error('Invalid recovery asset file.');
  if(!fs.existsSync(target)||fs.statSync(target).size!==st.size||Math.abs(fs.statSync(target).mtimeMs-st.mtimeMs)>=1){
   const tmp=target+'.'+crypto.randomBytes(8).toString('hex');
   try{fs.copyFileSync(source,tmp,fs.constants.COPYFILE_EXCL);fs.chmodSync(tmp,0o600|(st.mode&0o100));fs.utimesSync(tmp,st.atime,st.mtime);fs.renameSync(tmp,target);}finally{fs.rmSync(tmp,{force:true});}
  }
 }else throw Error('Unsupported recovery asset type.');
}
export function saveVmRecovery(configDirectory:string):void{
 const trial=path.join(configDirectory,'ConfigTrial','state.json');
 if(fs.existsSync(trial)&&['pending','restoring','restore-failed','conflict'].includes(JSON.parse(read(trial)).status))return;
 const compose=checkedCompose(YAML.parse(read(path.join(configDirectory,'docker-compose.yml'))));
 const storage=storagePath(compose,configDirectory),directory=path.join(storage,RECOVERY_FOLDER);
 if(!fs.statSync(storage).isDirectory())throw Error('VM storage folder is unavailable.');
 fs.mkdirSync(directory,{recursive:true,mode:0o700});
 const st=fs.lstatSync(directory);if(!st.isDirectory()||st.isSymbolicLink())throw Error('Invalid VM recovery directory.');
 fs.chmodSync(directory,0o700);
 for(const name of assetNames)if(fs.existsSync(path.join(configDirectory,name)))copyAssets(path.join(configDirectory,name),path.join(directory,name));
 compose.services.windows.volumes=compose.services.windows.volumes.map(mount=>{
  const source=volumeSource(mount),target=volumeTarget(mount);
  if(!source||target==='/run/helios-display'||(!source.startsWith('/')&&!source.startsWith('.')))return mount;
  let absolute=sourcePath(source,configDirectory);
  for(const name of assetNames){
   const relative=path.relative(path.join(configDirectory,name),absolute);
   if(relative===''||(!relative.startsWith('..')&&!path.isAbsolute(relative)))absolute=path.join(directory,name,relative);
  }
  return {type:'bind',source:absolute.replace(/\$/g,'$$$$'),target,read_only:volumeReadOnly(mount),bind:{create_host_path:false}};
 });
 const configFile=path.join(configDirectory,'winboat.config.json');
 const preferences=fs.existsSync(configFile)?JSON.parse(read(configFile)):{};
 atomic(path.join(directory,metadata),JSON.stringify({schema:1,storage,compose,preferences},null,2));
}
export function trySaveVmRecovery(directory:string):void{
 if(!fs.existsSync(path.join(directory,'docker-compose.yml')))return;
 try{saveVmRecovery(directory);}catch(error){console.warn('VM recovery metadata could not be updated:',String(error));}
}
export function inspectVmRecovery(selected:string):VmRecovery{
 const directory=fs.realpathSync(selected);
 let compose:ComposeConfig,preferences:Record<string,unknown>={},storage:string;
 const manifest=fs.existsSync(path.join(directory,RECOVERY_FOLDER,metadata))?path.join(directory,RECOVERY_FOLDER,metadata):path.join(directory,metadata);
 if(fs.existsSync(manifest)){
  const saved=JSON.parse(read(manifest));if(saved.schema!==1||typeof saved.storage!=='string')throw Error('Unsupported VM recovery format.');
  compose=checkedCompose(saved.compose);preferences=saved.preferences;
  storage=path.basename(directory)===RECOVERY_FOLDER?path.dirname(directory):directory;
  compose.services.windows.volumes=compose.services.windows.volumes.map(mount=>{
   const source=volumeSource(mount);if(!source)return mount;
   const absolute=sourcePath(source,directory),relative=path.relative(saved.storage,absolute);
   if(relative.startsWith('..')||path.isAbsolute(relative))return mount;
   return {type:'bind',source:path.join(storage,relative).replace(/\$/g,'$$$$'),target:volumeTarget(mount),read_only:volumeReadOnly(mount),bind:{create_host_path:false}};
  });
 }else{
  if(!fs.existsSync(path.join(directory,'docker-compose.yml')))throw Error('No WinBoat recovery details found. Select the retained configuration folder, or save recovery details in the previous installation first.');
  compose=checkedCompose(YAML.parse(read(path.join(directory,'docker-compose.yml'))));storage=storagePath(compose,directory);
  const config=path.join(directory,'winboat.config.json');if(fs.existsSync(config))preferences=JSON.parse(read(config));
  compose.services.windows.volumes=compose.services.windows.volumes.map(mount=>{
   const source=volumeSource(mount);if(!source||(!source.startsWith('/')&&!source.startsWith('.')))return mount;
   return {type:'bind',source:sourcePath(source,directory).replace(/\$/g,'$$$$'),target:volumeTarget(mount),read_only:volumeReadOnly(mount),bind:{create_host_path:false}};
  });
 }
 if(!preferences||Array.isArray(preferences)||typeof preferences!=='object')throw Error('Invalid saved WinBoat preferences.');
 const disks=existingVmDisks(storage);
 if(disks.some(name=>!fs.lstatSync(path.join(storage,name)).isFile()))throw Error('VM disk paths must be regular files, not links or directories.');
 if(!disks.length||!disks.some(name=>fs.statSync(path.join(storage,name)).size>0))throw Error('No existing Windows disk found. Import will not create a new disk.');
 for(const mount of compose.services.windows.volumes){
  const source=volumeSource(mount);if(volumeTarget(mount)==='/run/helios-display')continue;
  if(source?.startsWith('/')&&!fs.existsSync(sourcePath(source,directory)))throw Error('Required VM mount is missing: '+source);
 }
 const base=fs.existsSync(manifest)?path.dirname(manifest):directory;
 const assets=Object.fromEntries(assetNames.filter(name=>fs.existsSync(path.join(base,name))).map(name=>[name,path.join(base,name)]));
 return {compose,preferences,storage,source:directory,disks,assets};
}

/** Stage only configuration, with an explicit rollback; caller checks Docker ownership first. */
export function stageVmRecovery(recovery:VmRecovery,destination:string):{commit:()=>void;rollback:()=>void}{
 fs.mkdirSync(destination,{recursive:true,mode:0o700});
 const backup=fs.mkdtempSync(path.join(destination,'.import-'));
 const names=['docker-compose.yml','winboat.config.json',...assetNames];
 const moved:string[]=[],written:string[]=[];
 const rollback=()=>{
  for(const name of written)fs.rmSync(path.join(destination,name),{recursive:true,force:true});
  for(const name of moved)fs.renameSync(path.join(backup,name),path.join(destination,name));
  fs.rmSync(backup,{recursive:true,force:true});
 };
 try{
  for(const name of names)if(fs.existsSync(path.join(destination,name))){fs.renameSync(path.join(destination,name),path.join(backup,name));moved.push(name);}
  const compose=JSON.parse(JSON.stringify(recovery.compose)) as ComposeConfig;
  for(const [name,source] of Object.entries(recovery.assets)){
   if(!assetNames.includes(name))throw Error('Unknown VM recovery asset.');
   written.push(name);const target=path.join(destination,name);
   copyAssets(source===target?path.join(backup,name):source,target);
   compose.services.windows.volumes=compose.services.windows.volumes.map(mount=>{
    const original=volumeSource(mount);if(!original)return mount;
    const relative=path.relative(source,sourcePath(original,recovery.source));
    if(relative.startsWith('..')||path.isAbsolute(relative))return mount;
    return {type:'bind',source:path.join(target,relative).replace(/\$/g,'$$$$'),target:volumeTarget(mount),read_only:volumeReadOnly(mount),bind:{create_host_path:false}};
   });
  }
  written.push('winboat.config.json');atomic(path.join(destination,'winboat.config.json'),JSON.stringify(recovery.preferences,null,2));
  written.push('docker-compose.yml');atomic(path.join(destination,'docker-compose.yml'),YAML.stringify(compose));
  return {commit:()=>{fs.rmSync(backup,{recursive:true,force:true});},rollback};
 }catch(error){rollback();throw error;}
}
