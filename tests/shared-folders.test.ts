import {test} from 'node:test';
import assert from 'node:assert/strict';
import {parse,stringify} from 'yaml';
import {reactive} from 'vue';
import {readSharedFolders,configureSharedFolders,sharedFolderErrors,sharePath,SHARE_ROOT,type SharedFolderService} from '../src/shared/shared-folders';
import {volumeTarget,volumeSource} from '../src/shared/compose-volumes';
import {configureHeliosDisplay} from '../src/shared/helios-display';
import {configureHelios,LEGACY_WINDOWS_IMAGE} from '../src/shared/helios';
import {ATLAS_IMAGE} from '../src/shared/atlas';
import {spawnSync} from 'node:child_process';
const service = (): SharedFolderService & {devices:string[];ports:string[]} => ({image:LEGACY_WINDOWS_IMAGE,
    environment:{USERNAME:'Windows User',PASSWORD:'null-fixture-password',HELIOS:'1',ARGUMENTS:'keep'},
    volumes:['disk:/storage','/home/null-user:/shared','/dev/bus/usb:/dev/bus/usb', {type:'bind',source:'/tmp/cache',target:'/cache',read_only:true}],devices:['/dev/kvm'],ports:['3389:3389']});
const selected = [{name:'Projects',hostPath:'/home/null-user/Work $cash: files',enabled:true,readOnly:false},
    {name:'Archive',hostPath:'/media/disk/Archive',enabled:true,readOnly:true},
    {name:'Offline',hostPath:'/media/unplugged',enabled:false,readOnly:true}];
test('migrates real and HOME-based legacy mounts without depending on Network discovery', () => {
    const original=service();original.volumes.push('${HOME}:/shared2:ro');
    assert.deepEqual(readSharedFolders(original,'/home/current user','/tmp'),[
        {name:'Data',hostPath:'/home/null-user',enabled:true,readOnly:false},
        {name:'Data2',hostPath:'/home/current user',enabled:true,readOnly:true}]);
    assert.equal(sharePath('My Files'),'\\\\host.lan\\My Files');
});
test('custom folder mounts preserve paths, readonly flags, unrelated devices and the VM disk', () => {
    const original=reactive(service()),before=JSON.stringify(original);
    const next=configureSharedFolders(original,selected,1000,1000);
    assert.equal(JSON.stringify(original),before);
    assert.deepEqual(next.ports,original.ports);assert.deepEqual(next.devices,original.devices);
    assert(next.volumes.some(m=>volumeTarget(m)==='/storage' && volumeSource(m)==='disk'));
    assert(next.volumes.some(m=>volumeTarget(m)==='/cache'));
    assert(!next.volumes.some(m=>volumeTarget(m)==='/shared'));
    const projects=next.volumes.find(m=>volumeTarget(m)===SHARE_ROOT+'Projects');
    assert.equal(typeof projects,'object');assert(projects && typeof projects!=='string');
    assert.equal(projects.source,'/home/null-user/Work $$cash: files');
    assert.equal(projects.bind?.create_host_path,false);assert.equal(projects.read_only,false);
    assert.equal(next.environment.SAMBA,'Y');assert.equal(next.environment.WINBOAT_SHARE_UID,'1000');
    assert.deepEqual(readSharedFolders(next,'unused','unused'),selected);
    assert(!next.volumes.some(m=>volumeTarget(m)===SHARE_ROOT+'Offline'));
    const roundTrip=parse(stringify({services:{windows:next},volumes:{disk:null}}));
    assert.equal(roundTrip.services.windows.environment.PASSWORD,'null-fixture-password');
    assert.equal(roundTrip.services.windows.volumes.find((m:any)=>m.target===SHARE_ROOT+'Projects').source,projects.source);
});
test('disabling shares retains their configuration without exposing the home folder or losing mounts', () => {
    const next=configureSharedFolders(service(),selected.map(f=>({...f,enabled:false})),1000,1000);
    assert.equal(next.environment.SAMBA,'N');assert.equal(next.environment.WINBOAT_SHARED_FOLDERS,'[]');
    assert(!next.volumes.some(m=>volumeTarget(m).startsWith(SHARE_ROOT)));
    assert.equal(readSharedFolders(next,'unused','unused').length,3);
    assert(next.volumes.some(m=>volumeTarget(m)==='/storage'));
});
test('real Docker Compose preserves special characters in bind paths and saved metadata', () => {
    const windows=configureSharedFolders(service(),selected,1000,1000);
    const yaml=stringify({name:'winboat-shares-fixture',services:{windows},volumes:{disk:null}});
    const result=spawnSync('docker',['compose','-f','-','config','--format','json'],{input:yaml,encoding:'utf8'});
    assert.equal(result.status,0,result.stderr);
    const resolved=JSON.parse(result.stdout).services.windows;
    // Compose re-escapes dollars in its rendered output for round-trip safety
    // and omits service extensions from the runtime model.
    assert.equal(resolved.volumes.find((mount:any)=>mount.target===SHARE_ROOT+'Projects').source.replace(/\$\$/g,'$'),selected[0].hostPath);
    assert.deepEqual(readSharedFolders(parse(yaml).services.windows,'unused','unused'),selected);
    assert.equal(resolved.environment.PASSWORD,'null-fixture-password');
});
test('custom bind mounts coexist with local display and adapter changes', () => {
    const selectedService=configureSharedFolders(service(),selected,1000,1000);
    const native=configureHeliosDisplay(selectedService,true,'/tmp/display');
    assert(native.volumes.some(m=>volumeTarget(m)===SHARE_ROOT+'Projects'));
    const standard=configureHelios(native,false);
    assert(standard.volumes.some(m=>volumeTarget(m)===SHARE_ROOT+'Projects'));
    assert(!standard.volumes.some(m=>volumeTarget(m)==='/run/helios-display'));
});
test('authenticated shares select the patched runtime for ordinary Windows installs', () => {
    assert.equal(configureSharedFolders(service(),selected,1000,1000).image,ATLAS_IMAGE);
});
test('rejects ambiguous share names, traversal, missing credentials and invalid identities before saving', () => {
    for (const name of ['', '../storage','A\\B','IPC$','global','Name.','a\nb','%U']) {
        assert(sharedFolderErrors([{...selected[0],name}]).length>0,name);
    }
    assert(sharedFolderErrors([selected[0],{...selected[0],name:'PROJECTS'}]).length>0);
    assert.throws(()=>configureSharedFolders(service(),selected,-1,1000),/identity|user|group/i);
    const noPassword=service();noPassword.environment.PASSWORD='';
    assert.throws(()=>configureSharedFolders(noPassword,selected,1000,1000),/password/i);
});
