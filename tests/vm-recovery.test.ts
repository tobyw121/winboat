import {test,type TestContext} from 'node:test';
import {createRequire} from 'node:module';
(globalThis as any).require=createRequire(import.meta.url);
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import YAML from 'yaml';
const {existingVmDisks,inspectVmRecovery,saveVmRecovery,stageVmRecovery,RECOVERY_FOLDER}=await import('../src/shared/vm-recovery');
import {volumeSource,volumeTarget} from '../src/shared/compose-volumes';
function fixture(t:TestContext){
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'winboat-import-'));t.after(()=>fs.rmSync(root,{recursive:true,force:true}));
 const config=path.join(root,'old-config'),storage=path.join(root,'Windows VM'),restored=path.join(root,'new-config');
 fs.mkdirSync(config);fs.mkdirSync(storage);fs.mkdirSync(path.join(config,'oem'));
 fs.writeFileSync(path.join(config,'oem','install.bat'),'original provisioning');fs.writeFileSync(path.join(storage,'data.img'),'existing Windows disk');
 fs.writeFileSync(path.join(storage,'windows.nvram'),'EFI identity');
 const compose={name:'winboat',volumes:{},services:{windows:{container_name:'WinBoat',image:'winboat/helios:pinned',environment:{CPU_CORES:'6',RAM_SIZE:'12G',USERNAME:'existing-user',PASSWORD:'private',ARGUMENTS:'preserved QEMU arguments'},ports:['8006:8006'],volumes:[`${storage}:/storage`,'./oem:/oem'],devices:['/dev/kvm']}}};
 fs.writeFileSync(path.join(config,'docker-compose.yml'),YAML.stringify(compose));
 fs.writeFileSync(path.join(config,'winboat.config.json'),JSON.stringify({scale:125,localDisplayPreferred:true,customApps:[]}));
 return {root,config,storage,restored,compose};
}
test('reinstall restores settings and OEM assets after original config is gone, without touching disks/EFI',t=>{
 const f=fixture(t);saveVmRecovery(f.config);saveVmRecovery(f.config);
 fs.rmSync(f.config,{recursive:true});const vm=inspectVmRecovery(f.storage);
 assert.equal(vm.preferences.scale,125);assert.equal(vm.compose.services.windows.environment.PASSWORD,'private');
 assert.equal(vm.compose.services.windows.environment.ARGUMENTS,'preserved QEMU arguments');
 const transaction=stageVmRecovery(vm,f.restored);transaction.commit();
 assert.equal(fs.readFileSync(path.join(f.restored,'oem','install.bat'),'utf8'),'original provisioning');
 assert.equal(inspectVmRecovery(f.restored).compose.services.windows.environment.CPU_CORES,'6');
 assert.equal(fs.readFileSync(path.join(f.storage,'data.img'),'utf8'),'existing Windows disk');
 assert.equal(fs.readFileSync(path.join(f.storage,'windows.nvram'),'utf8'),'EFI identity');
 assert.equal(fs.statSync(path.join(f.storage,RECOVERY_FOLDER,'vm.json')).mode&0o777,0o600);
 assert.equal(fs.statSync(path.join(f.storage,RECOVERY_FOLDER)).mode&0o777,0o700);
});
test('retained config can be imported in place and failed deployment restores previous configuration',t=>{
 const f=fixture(t),before=fs.readFileSync(path.join(f.config,'docker-compose.yml'),'utf8');
 const tx=stageVmRecovery(inspectVmRecovery(f.config),f.config);tx.rollback();
 assert.equal(fs.readFileSync(path.join(f.config,'docker-compose.yml'),'utf8'),before);
 assert.equal(fs.readFileSync(path.join(f.config,'oem','install.bat'),'utf8'),'original provisioning');
});
test('moved VM folder rebases storage and recovery assets, and missing external shares block import',t=>{
 const f=fixture(t);saveVmRecovery(f.config);const moved=path.join(f.root,'Moved VM');fs.renameSync(f.storage,moved);
 const vm=inspectVmRecovery(moved),storage=vm.compose.services.windows.volumes.find(v=>volumeTarget(v)==='/storage')!;
 assert.equal(volumeSource(storage),moved);
 fs.rmSync(path.join(moved,RECOVERY_FOLDER,'oem'),{recursive:true});assert.throws(()=>inspectVmRecovery(moved),/mount is missing/);
});
test('empty storage, named storage, unknown formats and linked assets are rejected',t=>{
 const f=fixture(t);fs.unlinkSync(path.join(f.storage,'data.img'));assert.throws(()=>inspectVmRecovery(f.config),/No existing Windows disk/);
 fs.writeFileSync(path.join(f.storage,'data.img'),'');assert.deepEqual(existingVmDisks(f.storage),['data.img']);
 assert.throws(()=>inspectVmRecovery(f.config),/No existing Windows disk/);
 f.compose.services.windows.volumes[0]='data:/storage';fs.writeFileSync(path.join(f.config,'docker-compose.yml'),YAML.stringify(f.compose));
 assert.throws(()=>inspectVmRecovery(f.config),/named-volume/);
 f.compose.services.windows.volumes[0]=`${f.storage}:/storage`;fs.writeFileSync(path.join(f.config,'docker-compose.yml'),YAML.stringify(f.compose));
 fs.symlinkSync('/etc/passwd',path.join(f.config,'oem','link'));assert.throws(()=>saveVmRecovery(f.config),/symbolic links/);
});
test('confirmed settings refresh recovery, removed OEM flags stay removed, pending trials do not replace recovery',t=>{
 const f=fixture(t);saveVmRecovery(f.config);fs.unlinkSync(path.join(f.config,'oem','install.bat'));saveVmRecovery(f.config);
 assert.equal(fs.existsSync(path.join(f.storage,RECOVERY_FOLDER,'oem','install.bat')),false);
 const original=fs.readFileSync(path.join(f.storage,RECOVERY_FOLDER,'vm.json'),'utf8');
 fs.mkdirSync(path.join(f.config,'ConfigTrial'));fs.writeFileSync(path.join(f.config,'ConfigTrial','state.json'),JSON.stringify({status:'pending'}));
 fs.writeFileSync(path.join(f.config,'winboat.config.json'),JSON.stringify({scale:200}));saveVmRecovery(f.config);
 assert.equal(fs.readFileSync(path.join(f.storage,RECOVERY_FOLDER,'vm.json'),'utf8'),original);
});

const {importVmRecovery}=await import('../src/shared/vm-import');
test('Docker import creates only a stopped container and preserves the original disk',async t=>{
 const f=fixture(t),calls:string[][]=[];
 await importVmRecovery(inspectVmRecovery(f.config),f.restored,async args=>{calls.push(args);return '';});
 assert.deepEqual(calls.map(args=>args.slice(0,2)),[['container','ls'],['image','inspect'],['compose','-f'],['compose','-f']]);
 assert.deepEqual(calls.at(-1)!.slice(3),['create','--no-recreate','--no-build','--pull','never']);
 assert.equal(calls.flat().some(arg=>['start','up','down','rm','volume'].includes(arg)),false);
 assert.equal(fs.readFileSync(path.join(f.storage,'data.img'),'utf8'),'existing Windows disk');
});
test('Docker failures roll back local settings; unrelated containers and missing images are untouched',async t=>{
 const f=fixture(t);fs.mkdirSync(f.restored);fs.writeFileSync(path.join(f.restored,'winboat.config.json'),'original settings');
 await assert.rejects(importVmRecovery(inspectVmRecovery(f.config),f.restored,async args=>{
  if(args[0]==='compose')throw Error('Docker validation failed');return '';
 }),/Docker validation failed/);
 assert.equal(fs.readFileSync(path.join(f.restored,'winboat.config.json'),'utf8'),'original settings');
 assert.equal(fs.existsSync(path.join(f.restored,'docker-compose.yml')),false);
 await assert.rejects(importVmRecovery(inspectVmRecovery(f.config),f.restored,async args=>{
  if(args[1]==='ls')return 'WinBoat';
  return JSON.stringify([{Mounts:[{Destination:'/storage',Source:f.config,Type:'bind'}]}]);
 }),/different WinBoat container/);
 await assert.rejects(importVmRecovery(inspectVmRecovery(f.config),f.restored,async args=>{
  if(args[0]==='image')throw Error('missing image');return '';
 }),/saved Docker image is unavailable/);
 assert.equal(fs.readFileSync(path.join(f.restored,'winboat.config.json'),'utf8'),'original settings');
});
test('existing matching container is adopted without start or recreation, stale previews are rejected',async t=>{
 const f=fixture(t),calls:string[][]=[];
 await importVmRecovery(inspectVmRecovery(f.config),f.restored,async args=>{
  calls.push(args);if(args[1]==='ls')return 'WinBoat\n';
  return JSON.stringify([{Mounts:[{Destination:'/storage',Source:f.storage,Type:'bind'}]}]);
 });
 assert.equal(calls.length,3);assert.equal(calls.at(-1)!.at(-1),'--quiet');
 const old=inspectVmRecovery(f.config);fs.writeFileSync(path.join(f.config,'winboat.config.json'),'{}');
 await assert.rejects(importVmRecovery(old,f.restored,async()=>{throw Error('Docker must not be called');}),/configuration changed/);
});
test('authenticated sharing helpers and per-application profiles survive removing the old configuration',t=>{
 const f=fixture(t),runtime=path.join(f.config,'shared-folder-runtime','hash');fs.mkdirSync(runtime,{recursive:true});
 fs.writeFileSync(path.join(runtime,'samba.sh'),'original sharing helper');fs.mkdirSync(path.join(f.config,'ApplicationProfiles'));
 fs.writeFileSync(path.join(f.config,'ApplicationProfiles','game.json'),'{"exe":"game.exe"}');
 f.compose.services.windows.volumes.push(`${runtime}:/opt/winboat-shares:ro`,`${runtime}/samba.sh:/run/samba.sh:ro`);
 fs.writeFileSync(path.join(f.config,'docker-compose.yml'),YAML.stringify(f.compose));saveVmRecovery(f.config);
 const asset=path.join(f.storage,RECOVERY_FOLDER,'oem','install.bat'),inode=fs.statSync(asset).ino;saveVmRecovery(f.config);
 assert.equal(fs.statSync(asset).ino,inode,'unchanged OEM files are not recopied');
 fs.rmSync(f.config,{recursive:true});stageVmRecovery(inspectVmRecovery(f.storage),f.restored).commit();
 const restored=inspectVmRecovery(f.restored),helper=restored.compose.services.windows.volumes.find(v=>volumeTarget(v)==='/opt/winboat-shares')!;
 assert.equal(volumeSource(helper),path.join(f.restored,'shared-folder-runtime','hash'));
 assert.equal(fs.readFileSync(path.join(f.restored,'ApplicationProfiles','game.json'),'utf8'),'{"exe":"game.exe"}');
});
