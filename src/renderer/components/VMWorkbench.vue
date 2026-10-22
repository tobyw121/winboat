<template>
<section class="border-t border-neutral-700 pt-3 space-y-3">
 <VMProjectTools :blocked="busy || blocked" @busy="toolsBusy=$event" />
 <h2 class="font-semibold">Compatibility and performance workbench</h2>
 <div><h3>Measured performance</h3>
  <x-button :disabled="busy || toolsBusy || blocked" @click="run(sample)">Refresh CPU / GPU / display</x-button>
  <x-button :disabled="busy || toolsBusy || blocked" @click="run(checkTransport)">Compare host / viewer DMA-BUF layouts</x-button>
  <x-button :disabled="busy || toolsBusy || blocked" @click="run(layoutTrace)">Enable layout diagnostics (restart)</x-button><x-button :disabled="busy || toolsBusy || blocked" @click="run(()=>restore('diagnostics'))">Stop layout diagnostics</x-button>
  <label><input type="checkbox" v-model="automatic"> Refresh every 5 seconds while this page is open</label>
  <x-button :disabled="busy || toolsBusy || blocked" @click="run(importFrames)">Read application PresentMon CSV</x-button>
  <p class="text-sm">{{ metricText }}</p>
  <dl v-if="metrics" class="grid grid-cols-2 gap-1 text-sm">
   <dt>Container CPU (100% = one core)</dt><dd>{{ metrics.container?.cpuPercentOfOneCore ?? 'unknown' }}%</dd>
   <dt>Container memory share</dt><dd>{{ metrics.container?.memoryPercent ?? 'unknown' }}%</dd>
   <dt>Viewer extent</dt><dd>{{ metrics.viewer?.width ?? '?' }} × {{ metrics.viewer?.height ?? '?' }}</dd>
   <dt>Requested / actual resolution</dt><dd>{{ metrics.viewer?.requestedWidth ?? '?' }} × {{ metrics.viewer?.requestedHeight ?? '?' }} / {{ metrics.viewer?.width ?? '?' }} × {{ metrics.viewer?.height ?? '?' }}</dd>
   <dt>Application presents/s (CSV)</dt><dd>{{ metrics.applicationFrames?.presentCallsPerSecond?.toFixed(1) ?? 'not recorded' }}</dd>
   <dt>Presentation interval p95 / p99</dt><dd>{{ metrics.applicationFrames?.p95Ms?.toFixed(2) ?? '?' }} / {{ metrics.applicationFrames?.p99Ms?.toFixed(2) ?? '?' }} ms</dd>
  </dl>
  <p v-for="gpu in metrics?.hostGPU?.devices ?? []" :key="gpu.pciBusId" class="text-sm">Host GPU {{ gpu.pciBusId }}: {{ gpu.utilizationPercent ?? '?' }}% load; {{ gpu.memoryUsedMiB ?? '?' }} MiB used; {{ gpu.powerWatts ?? '?' }} W</p>
  <details v-if="metrics"><summary>Measurement and transport details</summary><pre class="text-xs whitespace-pre-wrap max-h-48 overflow-auto">{{ JSON.stringify(metrics,null,2) }}</pre></details>
 </div>
 <div><h3>Application profiles</h3>
  <input v-model="exe" aria-label="Windows executable" placeholder="C:\Games\Game.exe" class="bg-neutral-900 p-1 w-full">
  <input v-model="argumentsJSON" aria-label="Arguments as JSON array" placeholder='["-windowed"]' class="bg-neutral-900 p-1 w-full">
  <select v-model="resolution" class="bg-neutral-900" aria-label="Profile resolution"><option v-for="r in HELIOS_RESOLUTIONS" :key="r.key">{{ r.key }}</option></select>
  <select v-model="api" class="bg-neutral-900" aria-label="Application API profile"><option value="native">Native driver defaults</option><option value="compatibility">D3D11 feature-level 10 diagnostic compatibility</option></select>
  <select v-model="transport" class="bg-neutral-900" aria-label="Profile display transport"><option>auto</option><option>copy</option><option>dmabuf</option></select>
  <x-button :disabled="busy || toolsBusy || blocked" @click="run(saveProfile)">Save profile</x-button>
  <select v-model="selected" aria-label="Saved profile" class="bg-neutral-900"><option v-for="p in profiles" :key="p.id" :value="p.id">{{ p.exe }}</option></select>
  <x-button :disabled="busy || toolsBusy || blocked || !selected" @click="run(loadProfile)">Load profile</x-button>
  <x-button :disabled="busy || toolsBusy || blocked" @click="run(applyProfile)">Apply resolution / transport and restart</x-button>
  <x-button :disabled="busy || toolsBusy || blocked" @click="run(restoreProfile)">Restore previous application settings</x-button>
  <x-button :disabled="busy || toolsBusy || blocked" @click="run(launch)">Start with Windows confirmation</x-button>
  <p class="text-sm text-neutral-400">Compatibility is process-local and requires a supporting installed UMD. It does not install DLL translation layers or change DWM settings. Display changes affect the VM and require an explicit restart.</p>
 </div>
 <div><h3>Resource and network policies</h3>
  <p class="text-sm">Changes are trials: confirm within five minutes or the host restores the previous configuration, even if this window closes.</p>
  <x-button :disabled="busy || toolsBusy || blocked" @click="run(()=>trialAction('status'))">Trial status</x-button>
  <x-button :disabled="busy || toolsBusy || blocked" @click="run(()=>trialAction('confirm'))">Keep working configuration</x-button>
  <x-button :disabled="busy || toolsBusy || blocked" @click="run(()=>trialAction('recover'))">Restore previous configuration now</x-button>
  <x-button :disabled="busy || toolsBusy || blocked" @click="run(()=>trialAction('accept-external'))">Keep external edits after a conflict</x-button>
  <input v-model="cpuSet" aria-label="Linux CPU set" placeholder="CPU set, e.g. 2-7 (empty: unrestricted)" class="bg-neutral-900 p-1 w-full">
  <label><input type="checkbox" v-model="hugepages"> Use already reserved 2 MiB hugepages</label>
  <x-button :disabled="busy || toolsBusy || blocked" @click="run(()=>apply('resources'))">Apply resources and restart</x-button>
  <x-button :disabled="busy || toolsBusy || blocked" @click="run(()=>restore('resources'))">Restore resources</x-button>
  <x-button :disabled="busy || toolsBusy || blocked" @click="run(compactCache)">Trial smaller readback cache (restart)</x-button>
  <x-button :disabled="busy || toolsBusy || blocked" @click="run(()=>restore('readback-cache'))">Restore readback cache</x-button>
  <label><input type="checkbox" v-model="background"> Limit background viewer work to 5 updates/s</label>
  <x-button :disabled="busy || toolsBusy || blocked" @click="run(saveBackground)">Save background limit</x-button>
  <label>Local Desktop sharpening <select v-model.number="sharpen" aria-label="Viewer sharpening" class="bg-neutral-900"><option :value="0">Off</option><option :value="25">25%</option><option :value="50">50%</option><option :value="100">100%</option></select></label>
  <x-button :disabled="busy || toolsBusy || blocked" @click="run(saveSharpen)">Save sharpening</x-button>
  <p class="text-sm text-neutral-400">Adjusts Local Desktop image sharpness. Extra filtering can increase GPU use. Reopen Local Desktop after saving.</p>
  <select v-model="network" aria-label="Network mode" class="bg-neutral-900"><option value="nat">NAT</option><option value="bridge">LAN via existing Docker macvlan</option><option value="isolated">Isolated (no guest networking)</option></select>
  <input v-if="network==='bridge'" v-model="networkName" aria-label="Existing Docker macvlan network" placeholder="Existing Docker macvlan network" class="bg-neutral-900 p-1">
  <x-button :disabled="busy || toolsBusy || blocked" @click="run(()=>apply('network'))">Apply network and restart</x-button>
  <x-button :disabled="busy || toolsBusy || blocked" @click="run(()=>restore('network'))">Restore network</x-button>
  <p class="text-sm text-neutral-400">Profiles are experiments; use the existing A/B comparison to measure them. LAN and isolated modes can make the guest API, RDP and shares unavailable. Local Desktop remains the recovery display. A macvlan places Windows directly on your LAN.</p>
 </div>
 <div><h3>Graphics update acceptance</h3>
  <x-button :disabled="busy || toolsBusy || blocked" @click="run(versions)">Check stack compatibility</x-button>
  <x-button :disabled="busy || toolsBusy || blocked" @click="run(testHelios)">Timed Helios test with VGA recovery</x-button>
  <x-button :disabled="busy || toolsBusy || blocked" @click="run(rollback)">Prepare recorded stable rollback</x-button><p class="text-sm">{{ trialMessage }}</p>
  <x-button :disabled="busy || toolsBusy || blocked" @click="run(runAcceptance)">Run graphics probes (Windows confirmation)</x-button>
  <select v-model="scenario" aria-label="Regression scenario" class="bg-neutral-900"><option>cold-boot</option><option>resize</option><option>logon</option><option>standby</option></select>
  <x-button :disabled="busy || toolsBusy || blocked" @click="run(baseline)">Record before transition</x-button>
  <x-button :disabled="busy || toolsBusy || blocked" @click="run(checkTransition)">Check after transition</x-button>
  <x-button :disabled="busy || toolsBusy || blocked" @click="run(gate)">Check release evidence</x-button>
  <p class="text-sm text-neutral-400">Run the Windows Helios Control acceptance probes, perform the selected transition, then run fresh probes and capture again. Existing graphics controls provide timed testing and stable rollback. A build alone cannot pass this gate.</p>
 </div>
 <div><h3>Live disk export with Windows VSS</h3>
  <x-button :disabled="busy || toolsBusy || blocked" @click="run(chooseBackupFolder)">Choose backup destination</x-button>
  <x-button :disabled="busy || toolsBusy || blocked" @click="run(prepareLive)">Configure agent channel and backup folder (restart)</x-button>
  <x-button :disabled="busy || toolsBusy || blocked" @click="run(()=>restore('live-backup'))">Remove export channel (keeps saved files)</x-button>
  <x-button :disabled="busy || toolsBusy || blocked" @click="run(()=>live('check'))">Check Windows agent</x-button>
  <x-button :disabled="busy || toolsBusy || blocked" @click="run(startLive)">Start VSS disk export</x-button>
  <input v-model="backupId" aria-label="Live export identity" placeholder="Export identity" class="bg-neutral-900 p-1">
  <x-button :disabled="busy || toolsBusy || blocked" @click="run(openLiveFolder)">Open exports folder</x-button>
  <x-button :disabled="busy || toolsBusy || blocked || !backupId" @click="run(()=>live('status'))">Refresh export status</x-button>
  <x-button :disabled="busy || toolsBusy || blocked" @click="run(thaw)">Recover VSS thaw</x-button>
  <p class="text-sm text-neutral-400">Requires Windows QEMU Guest Agent with VSS support, a new host image and enough backup space. The worker resumes and thaws independently of this window. Exports include writable disks and firmware; RAM, GPU/TPM state and shared folders are excluded; retain the original VM and encryption recovery keys. Restore exports offline using their block mapping.</p>
 </div>
 <div><h3>Relative game mouse</h3><x-button :disabled="busy || toolsBusy || blocked" @click="run(relativeMouse)">Switch guest to relative USB mouse (restart)</x-button><x-button :disabled="busy || toolsBusy || blocked" @click="run(()=>restore('mouse'))">Restore mouse device</x-button>
  <p class="text-sm text-neutral-400">Capture is enabled inside the native viewer on X11. Ctrl+Alt+G and loss of focus release the pointer. Wayland capture remains unavailable.</p>
 </div>
 <p role="status" class="text-sm whitespace-pre-wrap">{{ message }}</p>
</section>
</template>
<script setup lang="ts">
import {guestFetch,guestSessionEnvironment} from '../lib/guest-session';

import {ref,watch,onBeforeUnmount} from 'vue';
import VMProjectTools from './VMProjectTools.vue';
import {testHelios,trialMessage} from '../lib/graphics-trial';
import {Winboat} from '../lib/winboat';import {WinboatConfig} from '../lib/config';
import {WINBOAT_DIR,GUEST_API_PORT} from '../lib/constants';
import {viewerTelemetryPath} from '../lib/helios-display';
import {HELIOS_RESOLUTIONS,configureHeliosResolution} from '../../shared/helios-resolution';
import {networkPolicy,resourcePolicy,changePolicy,applicationProfile,type ApplicationProfile,type NetworkMode} from '../../shared/vm-policies';
import {volumeSource,volumeTarget} from '../../shared/compose-volumes';
import {nativeDesktopEnvironment} from '../../shared/native-desktop-environment';import {hostEnvironment} from '../lib/host-environment';
const props=defineProps<{blocked:boolean}>(),emit=defineEmits<{busy:[value:boolean];changed:[]}>();
const remote:typeof import('@electron/remote')=require('@electron/remote'),fs:typeof import('fs')=require('fs'),path:typeof import('path')=require('path'),child:typeof import('child_process')=require('child_process'),crypto:typeof import('crypto')=require('crypto');
const {promisify}:typeof import('util')=require('util'),fetch:typeof import('node-fetch').default=guestFetch;
const toolsBusy=ref(false);
const winboat=new Winboat(),config=new WinboatConfig();const busy=ref(false),message=ref(''),automatic=ref(false),metrics=ref<any>(),metricText=ref('No sample yet. Viewer rate is not application FPS.');let previous:any;
const exe=ref(''),argumentsJSON=ref('[]'),resolution=ref('1920x1080'),api=ref<ApplicationProfile['api']>('native'),transport=ref<ApplicationProfile['transport']>('auto'),profiles=ref<{id:string;exe:string}[]>([]),selected=ref('');
const sharpen=ref(config.config.viewerSharpenPercent??0);
const cpuSet=ref(''),hugepages=ref(false),background=ref(config.config.viewerBackgroundFPS===5),network=ref<NetworkMode>('nat'),networkName=ref(''),scenario=ref('cold-boot'),backupId=ref(config.config.lastLiveBackupId??'');let before='';
const tick=setInterval(()=>{if(automatic.value&&!busy.value&&!toolsBusy.value&&!props.blocked)void run(sample);},5000);onBeforeUnmount(()=>clearInterval(tick));watch([busy,toolsBusy],([a,b])=>emit('busy',a||b));
async function run(fn:()=>Promise<unknown>){if(busy.value||toolsBusy.value||props.blocked)return;busy.value=true;message.value='Working…';try{await fn();if(message.value==='Working…')message.value='Completed.';}catch(e){message.value=String(e);}finally{busy.value=false;}}
async function confirm(title:string,detail:string){return(await remote.dialog.showMessageBox({type:'warning',message:title,detail,buttons:['Cancel','Continue'],defaultId:0,cancelId:0})).response===1;}
function privateRoot(name:string){const root=path.join(WINBOAT_DIR,name);fs.mkdirSync(root,{recursive:true,mode:0o700});const stat=fs.lstatSync(root);if(stat.isSymbolicLink()||!stat.isDirectory()||stat.uid!==process.getuid!()||(stat.mode&0o077))throw new Error('Private owned directory required.');return root;}
async function execute(file:string,args:string[]){const script=remote.app.isPackaged?path.join(process.resourcesPath,'graphics-tools',file):path.resolve(remote.app.getAppPath(),'../..','scripts/helios',file);const {stdout}=await promisify(child.execFile)('python3',[script,...args],{timeout:120000,maxBuffer:1048576,env:{...nativeDesktopEnvironment(hostEnvironment(),remote.app.isPackaged?path.dirname(process.resourcesPath):undefined),...guestSessionEnvironment()}});return JSON.parse(stdout);}
async function checkTransport(){metrics.value=await execute('workbench.py',['transport','--viewer',viewerTelemetryPath()]);}
async function layoutTrace(){if(!await confirm('Enable detailed frame-layout traces and restart?','Diagnostic logging adds overhead. Save work, reproduce the issue, compare layouts, then stop layout diagnostics.'))return;const prior=config.config.viewerContractTrace;config.config.viewerContractTrace=true;try{await replace(changePolicy(winboat.parseCompose().services.windows,'diagnostics',{environment:{HELIOS_FRAME_TRACE:'1'}}));}catch(error){config.config.viewerContractTrace=prior;throw error;}}
async function sample(){const result=await execute('workbench.py',['metrics','--viewer',viewerTelemetryPath()]);const current=result.viewer;metricText.value='Viewer: warming up; game FPS requires a PresentMon CSV.';
 if(current&&previous&&['pid','console','width','height','requestedTransportMode'].every(k=>current[k]===previous[k])){const seconds=(current.monotonicUs-previous.monotonicUs)/1e6,frames=current.renderedFrames-previous.renderedFrames;if(seconds>0&&seconds<=15&&frames>=0)metricText.value=`Viewer redraw rate: ${(frames/seconds).toFixed(1)}/s; not game FPS.`;}
 if(winboat.qmpMgr){const responses=await Promise.allSettled([winboat.qmpMgr.executeCommand('query-kvm'),winboat.qmpMgr.executeCommand('query-status')]);result.qemu=responses.map(row=>row.status==='fulfilled'?row.value:{state:'unavailable'});}
 previous=current;metrics.value=result;}
async function importFrames(){const choice=await remote.dialog.showOpenDialog({properties:['openFile'],filters:[{name:'PresentMon CSV',extensions:['csv']}]});if(!choice.canceled)metrics.value=await execute('workbench.py',['metrics','--presentmon',choice.filePaths[0],'--application',exe.value.split('\\').pop()||'']);}
function profile(){return applicationProfile({schema:1,exe:exe.value,resolution:resolution.value,transport:transport.value,api:api.value,args:JSON.parse(argumentsJSON.value)});}
async function saveProfile(){const p=profile(),id=crypto.randomBytes(16).toString('hex');fs.writeFileSync(path.join(privateRoot('ApplicationProfiles'),id+'.json'),JSON.stringify(p),{mode:0o600,flag:'wx'});profiles.value.push({id,exe:p.exe});selected.value=id;}
async function loadProfile(){if(!/^[a-f0-9]{32}$/.test(selected.value))throw new Error('Choose a saved profile.');const file=path.join(privateRoot('ApplicationProfiles'),selected.value+'.json');if(fs.lstatSync(file).isSymbolicLink()||fs.statSync(file).size>131072)throw new Error('Invalid profile file.');const p=applicationProfile(JSON.parse(fs.readFileSync(file,'utf8')));exe.value=p.exe;resolution.value=p.resolution;transport.value=p.transport;api.value=p.api;argumentsJSON.value=JSON.stringify(p.args);}
async function replace(service:ReturnType<Winboat['parseCompose']>['services']['windows'],trial=false){const next=winboat.parseCompose();next.services.windows=service;await winboat.replaceCompose(next,trial);emit('changed');}
async function applyProfile(){
 const p=profile();if(!await confirm('Apply application display settings and restart Windows?','Save Windows work first. These display settings affect the VM. Starting the application is a separate step.'))return;
 const service=winboat.parseCompose().services.windows,chosen=configureHeliosResolution(service,p.resolution),old=config.config.viewerTransport,prior=config.config.viewerProfileBefore;
 if(prior===undefined)config.config.viewerProfileBefore=old??'auto';config.config.viewerTransport=p.transport;
 try{await replace(changePolicy(service,'application',{environment:{HELIOS_DISPLAY_WIDTH:chosen.environment.HELIOS_DISPLAY_WIDTH,HELIOS_DISPLAY_HEIGHT:chosen.environment.HELIOS_DISPLAY_HEIGHT}}));}catch(error){config.config.viewerTransport=old;if(prior===undefined)config.config.viewerProfileBefore=undefined;throw error;}
}
async function restoreProfile(){await restore('application');}
async function launch(){const response=await fetch(`http://127.0.0.1:${winboat.getHostPort(GUEST_API_PORT)}/integration/application`,{method:'POST',headers:{'Content-Type':'application/json','X-WinBoat-Application':'confirm-in-windows'},body:JSON.stringify(profile()),timeout:95000});if(!response.ok)throw new Error(await response.text());message.value='Application start requested after Windows confirmation.';}
async function apply(kind:'network'|'resources'){
 if(!await confirm('Apply policy and restart Windows?',kind==='network'?'Network changes may disconnect guest management and shared folders. Keep Local Desktop available; LAN mode exposes Windows on your local network.':'Performance is workload-dependent. Hugepages must already be reserved; no host reservation is changed.'))return;
 const service=winboat.parseCompose().services.windows;
 if(kind==='network'&&network.value==='bridge'){if(service.environment.HELIOS_DISPLAY!=='dbus')throw new Error('Enable Local Desktop before applying direct LAN mode.');const {stdout}=await promisify(child.execFile)('docker',['network','inspect',networkName.value],{timeout:5000});if(JSON.parse(stdout)[0]?.Driver!=='macvlan')throw new Error('Choose an existing Docker macvlan network.');}
 if(kind==='resources'&&hugepages.value){if(service.environment.HELIOS!=='1')throw new Error('Hugepage profiles require the Helios host runtime.');const size=service.environment.RAM_SIZE.match(/^(\d+(?:\.\d+)?)([GM])$/i);if(!size)throw new Error('Unsupported RAM size for preflight.');const bytes=Number(size[1])*1024**(size[2].toUpperCase()==='G'?3:2),free=Number(fs.readFileSync('/sys/kernel/mm/hugepages/hugepages-2048kB/free_hugepages','utf8'));if(free*2097152<bytes)throw new Error('Not enough already reserved free 2 MiB hugepages. Host reservations were not changed.');}
 if(cpuSet.value.length>256)throw new Error('CPU list is too long.');
 if(kind==='resources'&&cpuSet.value){const online=fs.readFileSync('/sys/devices/system/cpu/online','utf8').trim();const available=new Set<number>();for(const r of online.split(',')){const [a,b]=r.split('-').map(Number);for(let n=a;n<=(b??a);n++)available.add(n);}for(const r of cpuSet.value.split(',')){const [a,b]=r.split('-').map(Number);if(!Number.isFinite(a)||!Number.isFinite(b??a)||(b??a)-a>4096)throw new Error('Invalid CPU range');for(let n=a;n<=(b??a);n++)if(!available.has(n))throw new Error('CPU set includes an offline CPU');}}
 await replace(kind==='network'?networkPolicy(service,network.value,networkName.value):resourcePolicy(service,cpuSet.value,hugepages.value),true);message.value='Configuration trial started. Verify display and connectivity, then keep it within five minutes.';}
async function trialAction(action:'status'|'confirm'|'recover'|'accept-external'){if(action==='accept-external'&&!await confirm('Keep externally edited configuration?','The saved original is archived privately. This resolves the conflict without overwriting your external edits.'))return;message.value=JSON.stringify(await winboat.configurationTrial(action),null,2);emit('changed');}
async function restore(kind:string){
 if(!await confirm('Restore saved policy and restart Windows?','Save Windows work first. Other policy settings are preserved.'))return;
 const old=config.config.viewerTransport,oldTrace=config.config.viewerContractTrace;if(kind==='diagnostics')config.config.viewerContractTrace=false;if(kind==='application'&&config.config.viewerProfileBefore!==undefined)config.config.viewerTransport=config.config.viewerProfileBefore;
 try{await replace(changePolicy(winboat.parseCompose().services.windows,kind,null));if(kind==='application')config.config.viewerProfileBefore=undefined;if(kind==='diagnostics')config.config.viewerContractTrace=false;}catch(error){config.config.viewerTransport=old;config.config.viewerContractTrace=oldTrace;throw error;}
}
async function compactCache(){if(await confirm('Trial a smaller display readback cache?','Keeps two import entries instead of the default eight. The shared dynamic VRAM ceiling stays in force. Measure cache misses and frame times; confirm this trial within five minutes.'))await replace(changePolicy(winboat.parseCompose().services.windows,'readback-cache',{environment:{HELIOS_READBACK_CACHE_ENTRIES:'2'}}),true);}
async function saveSharpen(){if(![0,25,50,100].includes(sharpen.value))throw new Error('Invalid sharpening strength');config.config.viewerSharpenPercent=sharpen.value;message.value='Saved. Reopen Local Desktop to apply; choose Off to restore the original image.';}
async function saveBackground(){config.config.viewerBackgroundFPS=background.value?5:0;message.value='Saved. Reopen Local Desktop for this viewer setting.';}
async function versions(){message.value=JSON.stringify(await execute('graphics-center.py',['preflight']),null,2);}
async function rollback(){if(await confirm('Prepare the recorded stable graphics package?','Requires the existing VGA-only rescue and verified backup prerequisites. This prepares rollback; driver replacement remains a Windows maintenance action.'))message.value=JSON.stringify(await execute('graphics-center.py',['prepare-rollback']),null,2);}
async function runAcceptance(){const response=await fetch(`http://127.0.0.1:${winboat.getHostPort(GUEST_API_PORT)}/graphics/validation/run`,{method:'POST',headers:{'X-WinBoat-Validation':'acceptance'},timeout:6000});if(!response.ok)throw new Error(await response.text());message.value='Tests requested. Confirm Windows elevation, wait for completion, then capture the regression checkpoint.';}
async function baseline(){before=path.join(privateRoot('RegressionEvidence'),crypto.randomBytes(16).toString('hex')+'.json');await execute('regression-graphics.py',['--output',before]);message.value='Baseline saved. Perform the transition and rerun the Windows acceptance probes.';}
async function checkTransition(){if(!before)throw new Error('Record a baseline first.');const root=privateRoot('RegressionEvidence'),output=path.join(root,crypto.randomBytes(16).toString('hex')+'.json');const result=await execute('regression-graphics.py',['--before',before,'--scenario',scenario.value,'--output',output]);const file=path.join(root,'matrix.json');const matrix=fs.existsSync(file)?JSON.parse(fs.readFileSync(file,'utf8')):{};matrix[scenario.value]=JSON.parse(fs.readFileSync(output,'utf8'));fs.writeFileSync(file,JSON.stringify(matrix),{mode:0o600});message.value=JSON.stringify(result,null,2);}
async function gate(){message.value=JSON.stringify(await execute('workbench.py',['gate','--evidence',path.join(privateRoot('RegressionEvidence'),'matrix.json')]),null,2);}
function backupRoot(){const root=config.config.liveBackupDirectory??path.join(WINBOAT_DIR,'LiveBackups');fs.mkdirSync(root,{recursive:true,mode:0o700});const stat=fs.lstatSync(root);if(stat.isSymbolicLink()||!stat.isDirectory()||stat.uid!==process.getuid!()||(stat.mode&0o077))throw new Error('Backup destination must be private and owned by you.');return fs.realpathSync(root);}
async function chooseBackupFolder(){
 if(winboat.parseCompose().services.windows.volumes.some(v=>volumeTarget(v)==='/backup'))throw new Error('Remove the current export configuration before choosing another destination. Existing files are kept.');
 const result=await remote.dialog.showOpenDialog({title:'Choose a parent directory for private VM disk exports',properties:['openDirectory','createDirectory']});if(result.canceled)return;
 const candidate=path.join(result.filePaths[0],'WinBoatLiveBackups');fs.mkdirSync(candidate,{recursive:true,mode:0o700});const stat=fs.lstatSync(candidate);if(stat.isSymbolicLink()||!stat.isDirectory()||stat.uid!==process.getuid!()||(stat.mode&0o077))throw new Error('The selected backup subdirectory must be private and owned by you.');config.config.liveBackupDirectory=fs.realpathSync(candidate);message.value='Backup destination saved. Configure the export mount to use it.';
}
async function prepareLive(){
 if(!await confirm('Configure VSS export and restart Windows?','Requires installation of the official Windows QEMU Guest Agent with VSS support inside Windows. A dedicated private backup directory is mounted into the container.'))return;
 const service=winboat.parseCompose().services.windows;const {stdout}=await promisify(child.execFile)('docker',['image','inspect','--format','{{index .Config.Labels "org.winboat.integration.maintenance"}}',service.image],{timeout:5000});if(stdout.trim()!=='qga-v1')throw new Error('Rebuild the Helios host image first.');
 const root=backupRoot();const {stdout:mountData}=await promisify(child.execFile)('docker',['inspect','--format','{{json .Mounts}}','WinBoat'],{timeout:5000,maxBuffer:65536});const storage=JSON.parse(mountData).filter((m:{Destination:string})=>m.Destination==='/storage');if(storage.length!==1||storage[0].Type!=='bind')throw new Error('One local storage bind mount is required.');const realStorage=fs.realpathSync(storage[0].Source);if(root===realStorage||root.startsWith(realStorage+path.sep))throw new Error('Backup folder must be outside the Windows storage mount.');
 if(service.volumes.some(v=>volumeTarget(v)==='/backup'&&volumeSource(v)!==root))throw new Error('Custom /backup mount must be preserved.');
 await replace(changePolicy(service,'live-backup',{environment:{HELIOS_AGENT_CHANNEL:'1'},volumes:[...service.volumes.filter(v=>volumeTarget(v)!=='/backup'),{type:'bind',source:root,target:'/backup'}]}));}
async function live(action:string){const args=['exec','WinBoat','python3','/opt/helios/live-backup.py',action,...(action==='status'?['--id',backupId.value]:[])];const {stdout}=await promisify(child.execFile)('docker',args,{timeout:20000,maxBuffer:1048576});message.value=JSON.stringify(JSON.parse(stdout),null,2);}
async function startLive(){if(['pending','restoring','restore-failed','conflict'].includes((await winboat.configurationTrial()).status))throw new Error('Confirm or recover the configuration trial before starting a live export.');if(!await confirm('Export live Windows disks?','Windows is briefly frozen through VSS and paused while backup jobs begin. Disk copying continues after thaw. Leave sufficient free space; this export does not include RAM or GPU state.'))return;await live('check');backupId.value=crypto.randomBytes(16).toString('hex');config.config.lastLiveBackupId=backupId.value;const {stdout:description}=await promisify(child.execFile)('docker',['inspect','WinBoat'],{timeout:5000,maxBuffer:1048576});const info=JSON.parse(description)[0];fs.writeFileSync(path.join(backupRoot(),backupId.value+'.container.json'),JSON.stringify({schema:1,Image:info.Image,Config:info.Config,HostConfig:info.HostConfig,Mounts:info.Mounts}),{flag:'wx',mode:0o600});await promisify(child.execFile)('docker',['exec','-d','WinBoat','python3','/opt/helios/live-backup.py','export','--id',backupId.value],{timeout:10000});message.value='Export worker started: '+backupId.value+'. Refresh status to confirm completion.';}
async function openLiveFolder(){const error=await remote.shell.openPath(backupRoot());if(error)throw new Error(error);}
async function thaw(){if(await confirm('Request Windows VSS thaw?','Use only to recover an interrupted freeze. This does not resume a manually paused VM.'))await live('thaw');}
async function relativeMouse(){const service=winboat.parseCompose().services.windows;const {stdout}=await promisify(child.execFile)('docker',['image','inspect','--format','{{index .Config.Labels "org.winboat.integration.maintenance"}}',service.image],{timeout:5000});if(stdout.trim()!=='qga-v1')throw new Error('Rebuild the Helios host image before changing relative mouse mode.');if(await confirm('Use a relative mouse and restart Windows?','This replaces the standard USB tablet. Browser absolute pointer behavior changes. Save work first.'))await replace(changePolicy(winboat.parseCompose().services.windows,'mouse',{environment:{HELIOS_RELATIVE_MOUSE:'1'}}));}
try{const root=privateRoot('ApplicationProfiles');for(const name of fs.readdirSync(root)){if(!/^[a-f0-9]{32}\.json$/.test(name))continue;const file=path.join(root,name);if(fs.lstatSync(file).isSymbolicLink()||fs.statSync(file).size>131072)continue;const p=applicationProfile(JSON.parse(fs.readFileSync(file,'utf8')));profiles.value.push({id:name.slice(0,-5),exe:p.exe});}}catch(e){message.value=String(e);}
</script>
