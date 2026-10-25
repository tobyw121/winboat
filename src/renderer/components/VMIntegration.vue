<template>
<section class="vm-integration" aria-labelledby="vm-integration-title">
 <header class="integration-header">
  <div><h2 id="vm-integration-title">VM integration</h2><p>Make Windows feel at home on Linux.</p></div>
  <span v-if="busy || displayBusy || workbenchBusy" class="integration-activity" role="status">Operation in progress…</span>
 </header>
 <nav class="integration-nav" aria-label="VM integration sections">
  <button v-for="item in integrationSections" :key="item.id" type="button" :aria-pressed="active===item.id" @click="active=item.id">
   <Icon :icon="item.icon" width="16" aria-hidden="true" />{{ item.label }}
  </button>
 </nav>
 <div class="integration-intro"><h3>{{ currentSection.label }}</h3><p>{{ currentSection.description }}</p></div>
 <fieldset :disabled="busy || displayBusy || workbenchBusy || blocked" class="integration-stack" :aria-busy="busy || displayBusy || workbenchBusy">
  <div v-show="active==='overview'" class="integration-card"><h3>Windows controls</h3>
   <p>Start your VM or send a normal shutdown request to Windows.</p>
   <div class="integration-actions"><x-button class="integration-primary" @click="run(start)">Start Windows</x-button><x-button @click="run(refresh)">Refresh status</x-button></div>
   <p class="integration-notice">{{ status }}</p>
   <details><summary>Power options</summary><x-button @click="run(()=>power('shutdown'))">Shut down Windows</x-button><x-button @click="run(()=>power('reboot'))">Restart Windows</x-button></details>
  </div>
  <div v-show="active==='sharing'" class="integration-card"><h3>Shared clipboard</h3>
   <p>Choose what can move between your Linux and Windows clipboards. Windows will ask you to approve the connection.</p>
   <div class="integration-fields">
    <label class="integration-toggle"><input type="checkbox" v-model="toGuest"> Linux → Windows</label>
    <label class="integration-toggle"><input type="checkbox" v-model="toHost"> Windows → Linux</label>
   </div>
   <div class="integration-actions"><x-button class="integration-primary" @click="run(()=>startClipboard(toGuest,toHost,images))" :disabled="!toGuest && !toHost">Connect clipboard</x-button><x-button @click="run(stopClipboard)">Disconnect</x-button></div>
   <p role="status">{{ clipboardState }} — {{ clipboardMessage }}</p>
   <details><summary>Manual transfers & image sharing</summary>
    <label class="integration-toggle"><input type="checkbox" v-model="images"> Allow manual image transfers</label>
    <x-button @click="run(()=>transferClipboard('send'))" :disabled="!toGuest">Send text</x-button><x-button @click="run(()=>transferClipboard('receive'))" :disabled="!toHost">Receive text</x-button>
    <x-button @click="run(()=>transferClipboardImage('send'))" :disabled="!toGuest || !images">Send image</x-button><x-button @click="run(()=>transferClipboardImage('receive'))" :disabled="!toHost || !images">Receive image</x-button>
    <p>Automatic text: up to 256 KiB. Manual text: up to 4 MiB. PNG images: up to 8 MiB / 8 megapixels. Reconnect after locking or signing out of Windows. Changes to image sharing apply when you reconnect.</p>
   </details>
  </div>
  <div v-show="active==='sharing'" class="integration-card"><h3>File exchange</h3>
   <p>Send files to Windows or collect files saved in the shared exchange folder.</p>
   <div class="integration-actions"><x-button @click="run(sendFiles)">Send files</x-button><x-button @click="run(receiveFile)">Receive a file</x-button></div>
   <x-button @click="run(openHostExchange)">Open Linux folder</x-button><x-button @click="run(openWindowsExchange)">Open Windows folder</x-button>
   <details><summary>First-time setup</summary><p>Creates the authenticated WinBoatExchange share and restarts Windows. Windows files go in ToLinux; files you send appear in ToWindows. Existing files are kept.</p><x-button @click="run(prepareExchange)">Set up exchange & restart</x-button></details>
  </div>
  <div v-show="active==='backups'" class="integration-card"><h3>Snapshots</h3>
   <p>Save a complete checkpoint before changing your VM. Shut Windows down cleanly before creating or restoring one.</p>
   <label class="integration-field">Snapshot name<input v-model="label" maxlength="80" placeholder="Before a driver update" /></label>
   <div class="integration-actions"><x-button class="integration-primary" @click="run(()=>snapshot('create'))">Create snapshot</x-button><x-button @click="run(()=>snapshot('list'))">Refresh list</x-button></div>
   <p v-if="!snapshots.length" class="integration-empty">Refresh the list to see your saved snapshots.</p>
   <ul><li v-for="row in snapshots" :key="row.id" class="integration-snapshot"><div>{{ row.label }}<small>{{ row.createdAtUtc }} · {{ Math.ceil(row.archiveBytes/1048576) }} MiB</small></div><div><x-button @click="run(()=>snapshot('restore',row.id))">Restore</x-button><x-button @click="run(()=>snapshot('delete',row.id))">Delete</x-button></div></li></ul>
   <details><summary>What is saved & recovery options</summary><p>Includes VM storage and firmware. Shared folders and external disks are excluded. Restoring keeps the previous storage and leaves the VM stopped. Archives may contain passwords; keep them private.</p><x-button @click="run(()=>snapshot('recover'))">Recover interrupted restore</x-button></details>
  </div>
  <!-- Explicit panels keep v-show reactive in optimized builds. A constant v-for
       around slot outlets can omit the visibility patch when switching sections. -->
  <div v-show="active==='folders' && !!$slots.folders" class="integration-stack"><slot name="folders" /></div>
  <div v-show="active==='display' && !!$slots.display" class="integration-stack"><slot name="display" /></div>
  <div v-show="active==='performance' && !!$slots.performance" class="integration-stack"><slot name="performance" /></div>
  <div v-show="active==='diagnostics' && !!$slots.diagnostics" class="integration-stack"><slot name="diagnostics" /></div>
  <VMWorkbench :section="active" :blocked="busy || displayBusy || blocked" @busy="workbenchBusy=$event" @changed="emit('changed')" />
  <IntegrationDisplay v-show="active==='display'" :blocked="busy || workbenchBusy || blocked" @busy="displayBusy=$event" @changed="emit('changed')" />
 </fieldset>
 <div v-if="message" class="integration-feedback" role="status"><details v-if="message.trim().startsWith('{') || message.trim().startsWith('[')"><summary>View operation result</summary><pre>{{ message }}</pre></details><span v-else>{{ message }}</span></div>
 <x-button v-if="transfer" @click="transfer.abort()">Cancel file transfer</x-button>
</section>
</template>
<script setup lang="ts">
import {guestFetch} from '../lib/guest-session';

import {ref,watch,computed,onBeforeUnmount} from 'vue';
import {Icon} from '@iconify/vue';
import {integrationSections} from '../../shared/integration-navigation';
import type {IntegrationSection} from '../../shared/integration-navigation';
import {Winboat} from '../lib/winboat';
import {WINBOAT_DIR,GUEST_API_PORT} from '../lib/constants';
import {startClipboard,stopClipboard,transferClipboard,transferClipboardImage,clipboardState,clipboardMessage} from '../lib/clipboard-sync';
import {copyExchangeFile,exchangeDirectory} from '../../shared/exchange-files';
import {configuredSharedFolders,prepareSharedFolders} from '../lib/shared-folders';
import {nativeDesktopEnvironment} from '../../shared/native-desktop-environment';
import {hostEnvironment} from '../lib/host-environment';
import VMWorkbench from './VMWorkbench.vue';
import IntegrationDisplay from './IntegrationDisplay.vue';
const active=ref<IntegrationSection>('overview');
const currentSection=computed(()=>integrationSections.find(item=>item.id===active.value)!);
const props=defineProps<{blocked:boolean}>(),emit=defineEmits<{busy:[value:boolean];changed:[]}>();
const remote:typeof import('@electron/remote')=require('@electron/remote');
const fs:typeof import('fs')=require('fs'),path:typeof import('path')=require('path');
const child:typeof import('child_process')=require('child_process'),util:typeof import('util')=require('util');
const fetch:typeof import('node-fetch').default=guestFetch;
const winboat=new Winboat(),busy=ref(false),message=ref(''),status=ref('Refresh to query QEMU and the guest independently.');
const images=ref(false),toGuest=ref(true),toHost=ref(true),label=ref('Before changes'),snapshots=ref<Array<{id:string;label:string;createdAtUtc:string;archiveBytes:number}>>([]);
const displayBusy=ref(false),workbenchBusy=ref(false);
let transfer:AbortController|undefined;
onBeforeUnmount(()=>transfer?.abort());
watch([busy,displayBusy,workbenchBusy],([a,b,c])=>emit('busy',a||b||c));
async function run(action:()=>Promise<unknown>){if(busy.value||displayBusy.value||workbenchBusy.value||props.blocked)return;busy.value=true;message.value='Working…';try{await action();if(message.value==='Working…')message.value='Completed.';}catch(error){message.value=String(error);}finally{busy.value=false;}}
async function confirm(title:string,detail:string){return (await remote.dialog.showMessageBox({type:'question',title,message:title,detail,buttons:['Cancel','Continue'],defaultId:0,cancelId:0})).response===1;}
async function guest(route:string,headers:Record<string,string>={}){
 const response=await fetch(`http://127.0.0.1:${winboat.getHostPort(GUEST_API_PORT)}${route}`,{method:Object.keys(headers).length?'POST':'GET',headers,timeout:6000});
 if(!response.ok)throw new Error(`Windows integration unavailable (${response.status}). Update the guest service and sign in.`);return response;
}
async function refresh(){
 let qemu='unavailable',guestState='unavailable';
 try{const reply=await winboat.qmpMgr?.executeCommand('query-status');if(reply&&'return' in reply)qemu=reply.return.status;}catch{}
 try{const response=await guest('/version');guestState=response.ok?'responding':'unavailable';}catch{}
 status.value=`Container: ${winboat.containerStatus.value}; QEMU: ${qemu}; guest API: ${guestState}. API availability does not prove a usable desktop.`;
}
async function start(){await winboat.startContainer();await refresh();}
async function power(action:'shutdown'|'reboot'){
 if(!await confirm(action==='shutdown'?'Shut down Windows?':'Restart Windows?','Windows applications may ask to save files or block shutdown. No forced application termination is requested.'))return;
 await guest('/integration/power',{'X-WinBoat-Power':action});message.value='Windows accepted the request. Refresh status to observe completion.';
}
function script(){return remote.app.isPackaged?path.join(process.resourcesPath,'graphics-tools','vm-snapshots.py'):path.resolve(remote.app.getAppPath(),'../..','scripts/helios/vm-snapshots.py');}
async function snapshot(action:string,id?:string){
 if(['restore','delete'].includes(action)&&!await confirm(`${action==='restore'?'Restore':'Delete'} snapshot?`,action==='restore'?'Requires a cleanly stopped VM and the same host image. The current storage is retained beside the restored directory.':'Only this snapshot archive and its record will be removed.'))return;
 const {stdout}=await util.promisify(child.execFile)('python3',[script(),action,...(id?['--id',id]:[]),...(action==='create'?['--label',label.value]:[])],{timeout:86400000,maxBuffer:1048576,env:nativeDesktopEnvironment(hostEnvironment(),remote.app.isPackaged?path.dirname(process.resourcesPath):undefined)});
 const result=JSON.parse(stdout);if(action==='list')snapshots.value=result;else{message.value=JSON.stringify(result,null,2);await snapshot('list');}
}
function directory(){return exchangeDirectory(path.join(WINBOAT_DIR,'Exchange'));}
function requireExchange(){const folder=configuredSharedFolders(winboat.parseCompose().services.windows).find(row=>row.name==='WinBoatExchange'&&row.enabled);if(!folder||fs.realpathSync(folder.hostPath)!==fs.realpathSync(directory()))throw new Error('Set up the exchange folder first.');return directory();}
async function prepareExchange(){
 if(!await confirm('Set up file exchange?','Adds a writable authenticated share for this VM and restarts Windows. Save open work first.'))return;
 const next=winboat.parseCompose(),folders=configuredSharedFolders(next.services.windows);
 const existing=folders.find(row=>row.name.toLowerCase()==='winboatexchange');
 if(existing&&path.resolve(existing.hostPath)!==directory())throw new Error('WinBoatExchange is already used by another folder. Rename that share first.');
 next.services.windows=await prepareSharedFolders(next.services.windows,[...folders.filter(row=>row.name.toLowerCase()!=='winboatexchange'),{name:'WinBoatExchange',hostPath:directory(),enabled:true,readOnly:false}]);
 await winboat.replaceCompose(next);emit('changed');message.value='Exchange configured. Windows path: \\\\host.lan\\WinBoatExchange';
}
async function copy(source:string,destination:string){
 transfer=new AbortController();try{const result=await copyExchangeFile(source,destination,(bytes,total)=>message.value=`${path.basename(source)}: ${bytes} / ${total} bytes`,transfer.signal);message.value=`Copied ${result.bytes} bytes; SHA-256 ${result.sha256}`;}finally{transfer=undefined;}
}
async function sendFiles(){const root=requireExchange(),result=await remote.dialog.showOpenDialog({properties:['openFile','multiSelections']});if(result.canceled)return;for(const source of result.filePaths)await copy(source,path.join(root,'ToWindows',path.basename(source)));}
async function receiveFile(){
 const root=requireExchange(),result=await remote.dialog.showOpenDialog({title:'Select a file saved by Windows into ToLinux',defaultPath:path.join(root,'ToLinux'),properties:['openFile']});if(result.canceled)return;
 const source=result.filePaths[0];if(fs.realpathSync(path.dirname(source))!==fs.realpathSync(path.join(root,'ToLinux')))throw new Error('Choose a file directly inside ToLinux.');
 const target=await remote.dialog.showSaveDialog({defaultPath:path.basename(source)});if(!target.canceled&&target.filePath)await copy(source,target.filePath);
}
async function openHostExchange(){const error=await remote.shell.openPath(directory());if(error)throw new Error(error);}
async function openWindowsExchange(){requireExchange();await guest('/integration/exchange/open',{'X-WinBoat-Exchange':'open'});}
</script>

<style src="../styles/vm-integration.css"></style>
