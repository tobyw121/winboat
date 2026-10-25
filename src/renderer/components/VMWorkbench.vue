<template>
<section v-show="section!=='overview' && section!=='sharing'" class="integration-stack">
 <div v-show="section==='performance'" class="integration-card"><h3>Live resource use</h3>
  <p>Check CPU, memory and display activity before changing performance settings.</p>
  <div class="integration-actions"><x-button class="integration-primary" :disabled="busy || toolsBusy || blocked" @click="run(sample)">Refresh measurements</x-button></div>
  <label class="integration-toggle"><input type="checkbox" v-model="automatic"> Update every 5 seconds while this section is open</label>
  <p role="status">{{ metricText }}</p>
  <dl v-if="metrics" class="grid grid-cols-2 gap-1 text-sm">
   <dt>VM container CPU · 100% = one core</dt><dd>{{ metrics.container?.cpuPercentOfOneCore ?? 'unknown' }}%</dd>
   <dt>Container memory</dt><dd>{{ metrics.container?.memoryPercent ?? 'unknown' }}%</dd>
   <dt>Display resolution</dt><dd>{{ metrics.viewer?.width ?? '?' }} × {{ metrics.viewer?.height ?? '?' }}</dd>
   <dt>Application presents / second</dt><dd>{{ metrics.applicationFrames?.presentCallsPerSecond?.toFixed(1) ?? 'Not recorded' }}</dd>
   <dt>Frame intervals · p95 / p99</dt><dd>{{ metrics.applicationFrames?.p95Ms?.toFixed(2) ?? '?' }} / {{ metrics.applicationFrames?.p99Ms?.toFixed(2) ?? '?' }} ms</dd>
  </dl>
  <p v-for="gpu in metrics?.hostGPU?.devices ?? []" :key="gpu.pciBusId">Host GPU {{ gpu.pciBusId }}: {{ gpu.utilizationPercent ?? '?' }}% load · {{ gpu.memoryUsedMiB ?? '?' }} MiB used · {{ gpu.powerWatts ?? '?' }} W</p>
  <details><summary>Application frame times & measurement details</summary><p>Import a PresentMon CSV for the application selected under Applications. Viewer redraws are not game FPS.</p><x-button :disabled="busy || toolsBusy || blocked" @click="run(importFrames)">Import frame-time CSV</x-button><pre v-if="metrics">{{ JSON.stringify(metrics,null,2) }}</pre></details>
 </div>
 <div v-show="section==='applications'" class="integration-card"><h3>Windows application profiles</h3>
  <p>Keep a separate display and compatibility profile for each application.</p>
  <div class="integration-fields"><label class="integration-field">Saved profile<select v-model="selected"><option value="" disabled>{{ profiles.length ? 'Choose a profile' : 'No profiles saved yet' }}</option><option v-for="p in profiles" :key="p.id" :value="p.id">{{ p.exe }}</option></select></label><div class="integration-actions"><x-button :disabled="busy || toolsBusy || blocked || !selected" @click="run(loadProfile)">Load profile</x-button></div></div>
  <div class="integration-fields">
   <label class="integration-field">Windows application<input v-model="exe" placeholder="C:\Games\Game.exe"><small>Full path to the .exe file inside Windows.</small></label>
   <label class="integration-field">Display resolution<select v-model="resolution"><option v-for="r in HELIOS_RESOLUTIONS" :key="r.key">{{ r.key }}</option></select></label>
  </div>
  <details><summary>Compatibility & launch arguments</summary>
   <div class="integration-fields">
    <label class="integration-field">Graphics compatibility<select v-model="api"><option value="native">Driver defaults (recommended)</option><option value="compatibility">D3D11 feature level 10 · diagnostic</option></select><small>The diagnostic option requires a supporting installed driver.</small></label>
    <label class="integration-field">Display transfer<select v-model="transport"><option value="auto">Automatic (recommended)</option><option value="copy">Copy · compatibility fallback</option><option value="dmabuf">DMA-BUF · direct transfer</option></select></label>
   </div>
   <div v-if="api==='native'" class="integration-fields"><label class="integration-field">Versioned diagnostic recipe<select v-model="recipe"><option value="">None (recommended)</option><option v-for="item in nativeRecipes" :key="item.id" :value="item.id">{{ item.label }}</option></select><small>Requires an updated guest service. First use binds the application and driver versions after Windows confirmation.</small></label></div>
   <details v-if="recipe && api==='native'"><summary>Rebind after an application or driver update</summary><p>Changed executable, driver or driver options block this recipe. Rebinding accepts their current versions after Windows confirmation. It does not start the application. Choose None to stop using the recipe.</p><x-button :disabled="busy || toolsBusy || blocked || !exe" @click="run(rebindRecipe)">Rebind recipe in Windows</x-button></details>
   <div v-for="(argument,index) in appArguments" :key="index" class="integration-actions"><label class="integration-field">Argument {{ index+1 }}<input v-model="appArguments[index]" placeholder="e.g. -windowed"></label><x-button :disabled="busy || toolsBusy || blocked" :aria-label="'Remove argument '+(index+1)" @click="appArguments.splice(index,1)">Remove</x-button></div>
   <x-button :disabled="busy || toolsBusy || blocked || appArguments.length>=32" @click="appArguments.push('')">Add argument</x-button>
   <p>Each row is one argument. Spaces stay within that argument; no JSON or shell quoting is needed.</p>
  </details>
  <div class="integration-actions"><x-button :disabled="busy || toolsBusy || blocked || !exe" @click="run(saveProfile)">Save profile</x-button><x-button class="integration-primary" :disabled="busy || toolsBusy || blocked || !exe" @click="run(()=>launch())">Start application</x-button></div>
  <p>Confirm the application start in Windows. Applying its display settings is a separate step and restarts the VM.</p>
  <details><summary>Apply display settings to the VM</summary><x-button :disabled="busy || toolsBusy || blocked || !exe" @click="run(applyProfile)">Apply display settings & restart</x-button><x-button :disabled="busy || toolsBusy || blocked" @click="run(restoreProfile)">Restore previous display settings</x-button></details>
 </div>
 <div v-show="section==='performance'" class="integration-card"><h3>Configuration trial</h3>
  <p class="integration-notice">CPU, memory and network changes are tried for five minutes. Keep a working configuration before the timer expires, or the previous settings are restored automatically.</p>
  <div class="integration-actions"><x-button :disabled="busy || toolsBusy || blocked" @click="run(()=>trialAction('status'))">Check trial status</x-button><x-button :disabled="busy || toolsBusy || blocked" @click="run(()=>trialAction('confirm'))">Keep changes</x-button><x-button :disabled="busy || toolsBusy || blocked" @click="run(()=>trialAction('recover'))">Undo trial</x-button></div>
  <details><summary>Resolve an external configuration conflict</summary><p>Use this only when the trial reports that configuration was edited outside WinBoat.</p><x-button :disabled="busy || toolsBusy || blocked" @click="run(()=>trialAction('accept-external'))">Keep external edits</x-button></details>
 </div>
 <div v-show="section==='performance'" class="integration-card"><h3>CPU & memory tuning</h3>
  <p>RAM size and core count are configured in Container settings above. Use these options only for measured workload tuning.</p>
  <details><summary>Advanced resource settings</summary>
   <label class="integration-field">Allowed Linux CPU cores<input v-model="cpuSet" placeholder="e.g. 2-7"><small>Leave empty to use all available host cores.</small></label>
   <label class="integration-toggle"><input type="checkbox" v-model="hugepages"> Use already reserved 2 MiB hugepages</label>
   <div class="integration-actions"><x-button :disabled="busy || toolsBusy || blocked" @click="run(()=>apply('resources'))">Try resource settings & restart</x-button><x-button :disabled="busy || toolsBusy || blocked" @click="run(()=>restore('resources'))">Restore resources</x-button></div>
   <p>Hugepages must already be reserved on Linux. WinBoat checks available space before applying this option.</p>
   <x-button :disabled="busy || toolsBusy || blocked" @click="run(compactCache)">Try smaller display cache & restart</x-button><x-button :disabled="busy || toolsBusy || blocked" @click="run(()=>restore('readback-cache'))">Restore display cache</x-button>
  </details>
 </div>
 <div v-show="section==='performance'" class="integration-card"><h3>Network connection</h3>
  <div class="integration-fields"><label class="integration-field">Connection mode<select v-model="network"><option value="nat">Shared network · NAT (recommended)</option><option value="bridge">Direct LAN · existing macvlan network</option><option value="isolated">Isolated · no guest network</option></select></label><label v-if="network==='bridge'" class="integration-field">Docker macvlan network<input v-model="networkName" placeholder="Existing network name"></label></div>
  <p v-if="network==='nat'">Share the host connection through the existing VM network.</p><p v-else class="integration-notice">LAN and isolated modes can disconnect shared folders and Windows management. Keep Local Desktop available. LAN mode places Windows directly on your local network.</p>
  <div class="integration-actions"><x-button :disabled="busy || toolsBusy || blocked" @click="run(()=>apply('network'))">Try network settings & restart</x-button><x-button :disabled="busy || toolsBusy || blocked" @click="run(()=>restore('network'))">Restore network</x-button></div>
 </div>
 <div v-show="section==='display'" class="integration-card"><h3>Local Desktop preferences</h3>
  <div class="integration-fields"><label class="integration-field">Image sharpening<select v-model.number="sharpen"><option :value="0">Off (original image)</option><option :value="25">Subtle · 25%</option><option :value="50">Medium · 50%</option><option :value="100">Strong · 100%</option></select><small>Extra filtering can increase GPU use.</small></label></div>
  <label class="integration-toggle"><input type="checkbox" v-model="background"> Reduce updates while Local Desktop is in the background</label>
  <p>Limits background updates to five per second. Reopen Local Desktop after saving these preferences.</p>
  <x-button class="integration-primary" :disabled="busy || toolsBusy || blocked" @click="run(saveViewerSettings)">Save display preferences</x-button>
 </div>
 <div v-show="section==='diagnostics'" class="integration-card"><h3>Graphics testing & recovery</h3>
  <p>Check the installed graphics stack before testing a driver or preparing a rollback.</p>
  <div class="integration-actions"><x-button :disabled="busy || toolsBusy || blocked" @click="run(versions)">Check graphics compatibility</x-button><x-button :disabled="busy || toolsBusy || blocked" @click="run(testHelios)">Test Helios with timed VGA recovery</x-button></div><p role="status">{{ trialMessage }}</p>
  <details><summary>Prepare a driver rollback</summary><p>Requires the recorded stable package and a VGA-only rescue boot. The actual driver replacement is completed in Windows.</p><x-button :disabled="busy || toolsBusy || blocked" @click="run(rollback)">Prepare stable rollback</x-button></details>
  <details><summary>Developer acceptance & regression tests</summary>
   <p>Run the probes, record a baseline, perform a transition and run fresh probes before checking the result. A successful build alone does not establish driver stability.</p>
   <x-button :disabled="busy || toolsBusy || blocked" @click="run(runAcceptance)">Run graphics probes · confirm in Windows</x-button>
   <label class="integration-field">Transition to test<select v-model="scenario"><option value="cold-boot">Cold boot</option><option value="resize">Display resize</option><option value="logon">Windows sign-in</option><option value="standby">Standby & resume</option></select></label>
   <x-button :disabled="busy || toolsBusy || blocked" @click="run(baseline)">1. Record before</x-button><x-button :disabled="busy || toolsBusy || blocked" @click="run(checkTransition)">2. Check after</x-button><x-button :disabled="busy || toolsBusy || blocked" @click="run(gate)">Check release evidence</x-button>
   <x-button :disabled="busy || toolsBusy || blocked" @click="run(checkTransport)">Compare DMA-BUF layouts</x-button><x-button :disabled="busy || toolsBusy || blocked" @click="run(layoutTrace)">Start layout tracing & restart</x-button><x-button :disabled="busy || toolsBusy || blocked" @click="run(()=>restore('diagnostics'))">Stop layout tracing</x-button>
  </details>
 </div>
 <div v-show="section==='backups'" class="integration-card"><h3>Back up while Windows is running</h3>
  <p>Export Windows disks using VSS. Requires the Windows QEMU Guest Agent with VSS support and a compatible host image.</p>
  <div class="integration-actions"><x-button class="integration-primary" :disabled="busy || toolsBusy || blocked" @click="run(startLive)">Export Windows disks</x-button><x-button :disabled="busy || toolsBusy || blocked" @click="run(openLiveFolder)">Open backup folder</x-button></div>
  <label class="integration-field">Export ID<input v-model="backupId" placeholder="Shown after starting an export"></label><x-button :disabled="busy || toolsBusy || blocked || !backupId" @click="run(()=>live('status'))">Check export progress</x-button>
  <details><summary>Set up live backups</summary><x-button :disabled="busy || toolsBusy || blocked" @click="run(chooseBackupFolder)">Choose backup folder</x-button><x-button :disabled="busy || toolsBusy || blocked" @click="run(prepareLive)">Configure live backup & restart</x-button><x-button :disabled="busy || toolsBusy || blocked" @click="run(()=>live('check'))">Check Windows backup agent</x-button><x-button :disabled="busy || toolsBusy || blocked" @click="run(()=>restore('live-backup'))">Remove setup · keep files</x-button></details>
  <details><summary>Backup contents & interrupted export recovery</summary><p>Includes writable disks and firmware, but not RAM, GPU/TPM state or shared folders. Retain encryption recovery keys. Restore disk exports offline using their disk mapping. Copying and thaw recovery continue independently of this page.</p><x-button :disabled="busy || toolsBusy || blocked" @click="run(thaw)">Recover interrupted VSS freeze</x-button></details>
 </div>
 <div v-show="section==='display'" class="integration-card"><h3>Game mouse capture</h3>
  <p>Use relative mouse input inside Local Desktop on X11. Press Ctrl+Alt+G or leave the window to release the pointer. Wayland capture is not available.</p>
  <details><summary>Change the Windows mouse device</summary><p>Switching mouse devices restarts Windows and changes Browser Display pointer behavior.</p><x-button :disabled="busy || toolsBusy || blocked" @click="run(relativeMouse)">Enable relative mouse & restart</x-button><x-button :disabled="busy || toolsBusy || blocked" @click="run(()=>restore('mouse'))">Restore mouse device</x-button></details>
 </div>
 <VMProjectTools v-show="section==='performance' || section==='backups' || section==='diagnostics'" :section="section" :blocked="busy || blocked" @busy="toolsBusy=$event" />
 <div v-if="message" class="integration-feedback" role="status"><details v-if="message.trim().startsWith('{') || message.trim().startsWith('[')"><summary>View operation result</summary><pre>{{ message }}</pre></details><span v-else>{{ message }}</span></div>
</section>
</template>
<script setup lang="ts">
import {guestFetch,guestSessionEnvironment} from '../lib/guest-session';

import {ref,watch,onBeforeUnmount} from 'vue';
import type {IntegrationSection} from '../../shared/integration-navigation';
import VMProjectTools from './VMProjectTools.vue';
import {testHelios,trialMessage} from '../lib/graphics-trial';
import {Winboat} from '../lib/winboat';import {WinboatConfig} from '../lib/config';
import {trySaveVmRecovery} from '../../shared/vm-recovery';
import {WINBOAT_DIR,GUEST_API_PORT} from '../lib/constants';
import {viewerTelemetryPath} from '../lib/helios-display';
import {HELIOS_RESOLUTIONS,configureHeliosResolution} from '../../shared/helios-resolution';
import {networkPolicy,resourcePolicy,changePolicy,applicationProfile,nativeRecipes,type ApplicationProfile,type NetworkMode} from '../../shared/vm-policies';
import {volumeSource,volumeTarget} from '../../shared/compose-volumes';
import {nativeDesktopEnvironment} from '../../shared/native-desktop-environment';import {hostEnvironment} from '../lib/host-environment';
const props=defineProps<{blocked:boolean;section:IntegrationSection}>(),emit=defineEmits<{busy:[value:boolean];changed:[]}>();
const remote:typeof import('@electron/remote')=require('@electron/remote'),fs:typeof import('fs')=require('fs'),path:typeof import('path')=require('path'),child:typeof import('child_process')=require('child_process'),crypto:typeof import('crypto')=require('crypto');
const {promisify}:typeof import('util')=require('util'),fetch:typeof import('node-fetch').default=guestFetch;
const toolsBusy=ref(false);
const winboat=new Winboat(),config=new WinboatConfig();const busy=ref(false),message=ref(''),automatic=ref(false),metrics=ref<any>(),metricText=ref('No sample yet. Viewer rate is not application FPS.');let previous:any;
const exe=ref(''),appArguments=ref<string[]>([]),resolution=ref('1920x1080'),api=ref<ApplicationProfile['api']>('native'),transport=ref<ApplicationProfile['transport']>('auto'),profiles=ref<{id:string;exe:string}[]>([]),selected=ref('');
const recipe=ref('');
const sharpen=ref(config.config.viewerSharpenPercent??0);
const cpuSet=ref(''),hugepages=ref(false),background=ref(config.config.viewerBackgroundFPS===5),network=ref<NetworkMode>('nat'),networkName=ref(''),scenario=ref('cold-boot'),backupId=ref(config.config.lastLiveBackupId??'');let before='';
const tick=setInterval(()=>{if(props.section==='performance'&&automatic.value&&!busy.value&&!toolsBusy.value&&!props.blocked)void run(sample);},5000);onBeforeUnmount(()=>clearInterval(tick));watch([busy,toolsBusy],([a,b])=>emit('busy',a||b));
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
function profile(){return applicationProfile({schema:1,exe:exe.value,resolution:resolution.value,transport:transport.value,api:api.value,args:[...appArguments.value],...(api.value==='native'&&recipe.value?{recipe:recipe.value}:{})});}
async function saveProfile(){const p=profile(),id=crypto.randomBytes(16).toString('hex');fs.writeFileSync(path.join(privateRoot('ApplicationProfiles'),id+'.json'),JSON.stringify(p),{mode:0o600,flag:'wx'});profiles.value.push({id,exe:p.exe});selected.value=id;trySaveVmRecovery(WINBOAT_DIR);}
async function loadProfile(){if(!/^[a-f0-9]{32}$/.test(selected.value))throw new Error('Choose a saved profile.');const file=path.join(privateRoot('ApplicationProfiles'),selected.value+'.json');if(fs.lstatSync(file).isSymbolicLink()||fs.statSync(file).size>131072)throw new Error('Invalid profile file.');const p=applicationProfile(JSON.parse(fs.readFileSync(file,'utf8')));exe.value=p.exe;resolution.value=p.resolution;transport.value=p.transport;api.value=p.api;appArguments.value=[...p.args];recipe.value=p.recipe??'';}
async function replace(service:ReturnType<Winboat['parseCompose']>['services']['windows'],trial=false){const next=winboat.parseCompose();next.services.windows=service;await winboat.replaceCompose(next,trial);emit('changed');}
async function applyProfile(){
 const p=profile();if(!await confirm('Apply application display settings and restart Windows?','Save Windows work first. These display settings affect the VM. Starting the application is a separate step.'))return;
 const service=winboat.parseCompose().services.windows,chosen=configureHeliosResolution(service,p.resolution),old=config.config.viewerTransport,prior=config.config.viewerProfileBefore;
 if(prior===undefined)config.config.viewerProfileBefore=old??'auto';config.config.viewerTransport=p.transport;
 try{await replace(changePolicy(service,'application',{environment:{HELIOS_DISPLAY_WIDTH:chosen.environment.HELIOS_DISPLAY_WIDTH,HELIOS_DISPLAY_HEIGHT:chosen.environment.HELIOS_DISPLAY_HEIGHT}}));}catch(error){config.config.viewerTransport=old;if(prior===undefined)config.config.viewerProfileBefore=undefined;throw error;}
}
async function restoreProfile(){await restore('application');}
async function rebindRecipe(){if(!recipe.value||api.value!=='native')throw new Error('Select a native recipe first.');await launch(true);}
async function launch(rebindRecipe=false){const response=await fetch(`http://127.0.0.1:${winboat.getHostPort(GUEST_API_PORT)}/integration/application`,{method:'POST',headers:{'Content-Type':'application/json','X-WinBoat-Application':'confirm-in-windows'},body:JSON.stringify({...profile(),...(rebindRecipe?{rebindRecipe:true}:{})}),timeout:95000});if(!response.ok)throw new Error(await response.text());message.value=rebindRecipe?'Recipe rebinding requested. Confirm in Windows; the application is not started.':'Application start requested after Windows confirmation.';}
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
async function saveViewerSettings(){
 if(![0,25,50,100].includes(sharpen.value))throw new Error('Invalid sharpening strength');
 config.config.viewerSharpenPercent=sharpen.value;config.config.viewerBackgroundFPS=background.value?5:0;
 message.value='Display preferences saved. Reopen Local Desktop to apply them.';
}
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
