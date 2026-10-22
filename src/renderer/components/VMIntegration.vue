<template>
<section class="mt-4 border-t border-neutral-700 pt-3 space-y-3">
 <h2 class="font-semibold">VM integration</h2>
 <fieldset :disabled="busy || displayBusy || workbenchBusy || blocked" class="space-y-3">
  <div><h3>Windows power and status</h3>
   <x-button @click="run(refresh)">Refresh status</x-button><x-button @click="run(start)">Start VM</x-button>
   <x-button @click="run(()=>power('shutdown'))">Shut down Windows</x-button><x-button @click="run(()=>power('reboot'))">Restart Windows</x-button>
   <p class="text-sm">{{ status }}</p>
  </div>
  <div><h3>Shared text clipboard</h3>
   <label><input type="checkbox" v-model="toGuest"> Linux → Windows</label>
   <label class="ml-3"><input type="checkbox" v-model="toHost"> Windows → Linux</label>
   <x-button @click="run(()=>startClipboard(toGuest,toHost,images))" :disabled="!toGuest && !toHost">Connect and ask Windows</x-button>
   <label class="ml-3"><input type="checkbox" v-model="images"> Allow explicit PNG image transfers</label>
   <x-button @click="run(stopClipboard)">Disconnect</x-button>
   <x-button @click="run(()=>transferClipboard('send'))" :disabled="!toGuest">Send text now</x-button>
   <x-button @click="run(()=>transferClipboard('receive'))" :disabled="!toHost">Receive text now</x-button>
   <x-button @click="run(()=>transferClipboardImage('send'))" :disabled="!toGuest || !images">Send image now</x-button>
   <x-button @click="run(()=>transferClipboardImage('receive'))" :disabled="!toHost || !images">Receive image now</x-button>
   <p class="text-sm">{{ clipboardState }} — {{ clipboardMessage }}</p>
   <p class="text-sm text-neutral-400">Automatic text up to 256 KiB; manual text up to 4 MiB. Explicit PNG images up to 8 MiB / 8 megapixels; uncompressed 24/32-bit Windows bitmaps are supported too. Windows asks for consent. Locking, logging off or losing host contact stops sharing. Reconnect after unlocking.</p>
  </div>
  <div><h3>Offline snapshots</h3>
   <p class="text-sm text-neutral-400">Shut down Windows cleanly first. Includes the VM storage and firmware; excludes shared folders and external disks. Restore keeps the previous storage and leaves the VM stopped. Archives can contain passwords.</p>
   <input v-model="label" maxlength="80" aria-label="Snapshot name" class="bg-neutral-900 p-1" />
   <x-button @click="run(()=>snapshot('create'))">Create snapshot</x-button><x-button @click="run(()=>snapshot('list'))">Refresh snapshots</x-button>
   <x-button @click="run(()=>snapshot('recover'))">Recover interrupted restore</x-button>
   <ul><li v-for="row in snapshots" :key="row.id" class="text-sm my-2">{{ row.label }} — {{ row.createdAtUtc }} ({{ Math.ceil(row.archiveBytes/1048576) }} MiB)
    <x-button @click="run(()=>snapshot('restore',row.id))">Restore</x-button><x-button @click="run(()=>snapshot('delete',row.id))">Delete snapshot</x-button>
   </li></ul>
  </div>
  <div><h3>File exchange</h3>
   <p class="text-sm text-neutral-400">Uses the authenticated WinBoatExchange share. Send to ToWindows; save Windows files into ToLinux before receiving them here. Existing destinations are never overwritten.</p>
   <x-button @click="run(prepareExchange)">Set up exchange folder (restarts VM)</x-button>
   <x-button @click="run(sendFiles)">Send files to Windows</x-button><x-button @click="run(receiveFile)">Receive a file</x-button>
   <x-button @click="run(openHostExchange)">Open Linux folder</x-button><x-button @click="run(openWindowsExchange)">Open Windows folder</x-button>
  </div>
  <VMWorkbench :blocked="busy || displayBusy || blocked" @busy="workbenchBusy=$event" @changed="emit('changed')" />
  <IntegrationDisplay :blocked="busy || workbenchBusy || blocked" @busy="displayBusy=$event" @changed="emit('changed')" />
 </fieldset>
 <p role="status" class="text-sm whitespace-pre-wrap">{{ message }}</p>
 <x-button v-if="transfer" @click="transfer.abort()">Cancel file transfer</x-button>
</section>
</template>
<script setup lang="ts">
import {guestFetch} from '../lib/guest-session';

import {ref,watch,onBeforeUnmount} from 'vue';
import {Winboat} from '../lib/winboat';
import {WINBOAT_DIR,GUEST_API_PORT} from '../lib/constants';
import {startClipboard,stopClipboard,transferClipboard,transferClipboardImage,clipboardState,clipboardMessage} from '../lib/clipboard-sync';
import {copyExchangeFile,exchangeDirectory} from '../../shared/exchange-files';
import {configuredSharedFolders,prepareSharedFolders} from '../lib/shared-folders';
import {nativeDesktopEnvironment} from '../../shared/native-desktop-environment';
import {hostEnvironment} from '../lib/host-environment';
import VMWorkbench from './VMWorkbench.vue';
import IntegrationDisplay from './IntegrationDisplay.vue';
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
