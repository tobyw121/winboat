<template>
<section class="border-t border-neutral-700 pt-3 space-y-3">
 <h3>Host checks, backups and API permissions</h3>
 <div class="flex flex-wrap gap-2">
  <x-button :disabled="busy || blocked" @click="run(()=>tool('project-health.py',['host']))">Host hardware preflight</x-button>
  <x-button :disabled="busy || blocked" @click="run(()=>tool('project-health.py',['network']))">Check API / RDP / network reachability</x-button>
  <x-button :disabled="busy || blocked" @click="run(shares)">Check authenticated shared folders</x-button>
  <x-button :disabled="busy || blocked" @click="run(incidents)">Explain a graphics diagnostic report</x-button>
 </div>
 <details><summary>Application compatibility observations</summary>
  <p v-for="entry in compatibility" :key="entry.application" class="text-sm">{{ entry.application }} — {{ entry.status }}: {{ entry.note }}</p>
  <p class="text-sm">Observations are tied to their reported driver/hardware. They do not certify your current installation; profiles are applied explicitly.</p>
 </details>
 <div><h4>Private measurement history</h4>
  <input v-model="label" maxlength="80" aria-label="Measurement label" class="bg-neutral-900 p-1">
  <x-button :disabled="busy || blocked" @click="run(record)">Record CPU / GPU sample</x-button>
  <x-button :disabled="busy || blocked" @click="run(history)">Load history</x-button>
  <select v-model="before" aria-label="Before measurement" class="bg-neutral-900"><option v-for="r in records" :key="r.id" :value="r.id">{{ r.timeUtc }} — {{ r.label }}</option></select>
  <select v-model="after" aria-label="After measurement" class="bg-neutral-900"><option v-for="r in records" :key="r.id" :value="r.id">{{ r.timeUtc }} — {{ r.label }}</option></select>
  <x-button :disabled="busy || blocked || !before || !after" @click="run(()=>tool('project-health.py',['compare','--before',before,'--after',after]))">Compare matching environments</x-button>
  <svg v-if="points" viewBox="0 0 400 100" role="img" aria-label="Container CPU history, scaled to largest observed sample" class="w-full h-24"><polyline :points="points" fill="none" stroke="currentColor" stroke-width="2" /></svg>
  <p class="text-sm">Chart: container CPU, 100% equals one core; vertical scale follows the largest sample. Point samples do not establish an FPS improvement.</p>
 </div>
 <div><h4>Verified disk export recovery</h4>
  <input v-model="exportId" aria-label="Export identity to verify" placeholder="32-character export identity" class="bg-neutral-900 p-1">
  <x-button :disabled="busy || blocked" @click="run(()=>backup('inventory'))">Export capacity / inventory</x-button>
  <x-button :disabled="busy || blocked || !exportId" @click="run(()=>backup('verify'))">Verify disk checksums</x-button>
  <x-button :disabled="busy || blocked || !exportId" @click="run(stage)">Stage verified restore in a new folder</x-button>
  <p class="text-sm">Staging verifies QCOW2 structure, converts to each original disk format and compares disk contents. It preserves the original VM. TPM state is absent: the staged folder remains blocked from automatic boot.</p>
  <input v-model.number="keep" type="number" min="1" max="50" aria-label="Retained scheduled offline checkpoints" class="bg-neutral-900 p-1">
  <x-button :disabled="busy || blocked" @click="run(()=>schedule(true))">Enable daily offline backup check</x-button>
  <x-button :disabled="busy || blocked" @click="run(()=>schedule(false))">Disable scheduled check</x-button>
  <p class="text-sm">The user timer skips running or uncleanly stopped VMs. Retention applies only to scheduled offline checkpoints; manual snapshots and live exports are preserved. Requires a systemd user session.</p>
 </div>
 <div><h4>Scoped Windows API session</h4>
  <label v-for="scope in availableScopes" :key="scope" class="mr-3"><input type="checkbox" v-model="scopes" :value="scope"> {{ scope }}</label>
  <x-button :disabled="busy || blocked || !scopes.length" @click="run(pair)">Pair with Windows consent (10 minutes)</x-button>
  <x-button :disabled="busy || blocked" @click="run(revokeGuestSession)">Revoke this session</x-button>
  <p class="text-sm">{{ pairingCode }}</p>
  <p class="text-sm">Enable session enforcement locally in Helios Control first. Pairing tokens stay in memory and are limited to the paired loopback API endpoint. Older scripts require a token when enforcement is enabled. This does not encrypt LAN traffic.</p>
 </div>
 <details v-if="result"><summary>Result</summary><pre role="status" class="text-xs whitespace-pre-wrap max-h-72 overflow-auto">{{ result }}</pre></details>
</section>
</template>
<script setup lang="ts">
import {ref,computed} from 'vue';
import {Winboat} from '../lib/winboat';import {WinboatConfig} from '../lib/config';
import {pairGuestSession,revokeGuestSession,guestSessionEnvironment} from '../lib/guest-session';
import {GUEST_API_PORT,WINBOAT_DIR} from '../lib/constants';
import {checkSharedFolders} from '../lib/shared-folders';
import {nativeDesktopEnvironment} from '../../shared/native-desktop-environment';import {hostEnvironment} from '../lib/host-environment';
import {compatibility} from '../data/compatibility';
const props=defineProps<{blocked:boolean}>(),emit=defineEmits<{busy:[value:boolean]}>();
const remote:typeof import('@electron/remote')=require('@electron/remote'),path:typeof import('path')=require('path'),child:typeof import('child_process')=require('child_process'),util:typeof import('util')=require('util'),crypto:typeof import('crypto')=require('crypto');
const busy=ref(false),result=ref(''),pairingCode=ref(''),label=ref('Manual sample'),records=ref<Array<{id:string;label:string;timeUtc:string;cpuPercentOfOneCore?:number}>>([]),before=ref(''),after=ref(''),exportId=ref(new WinboatConfig().config.lastLiveBackupId??''),keep=ref(5);
const availableScopes=['read','graphics','power','application','clipboard','maintenance'],scopes=ref(['read']),winboat=new Winboat();
const points=computed(()=>{const rows=records.value.filter(r=>Number.isFinite(r.cpuPercentOfOneCore)).slice(-100);if(rows.length<2)return '';const max=Math.max(100,...rows.map(r=>r.cpuPercentOfOneCore!));return rows.map((r,i)=>`${i*400/(rows.length-1)},${100-r.cpuPercentOfOneCore!*100/max}`).join(' ');});
async function run(action:()=>Promise<unknown>){if(busy.value||props.blocked)return;busy.value=true;emit('busy',true);try{await action();}catch(e){result.value=String(e);}finally{busy.value=false;emit('busy',false);}}
async function tool(name:string,args:string[],timeout=120000){const script=remote.app.isPackaged?path.join(process.resourcesPath,'graphics-tools',name):path.resolve(remote.app.getAppPath(),'../..','scripts/helios',name);const {stdout}=await util.promisify(child.execFile)('python3',[script,...args],{timeout,maxBuffer:1048576,env:{...nativeDesktopEnvironment(hostEnvironment(),remote.app.isPackaged?path.dirname(process.resourcesPath):undefined),...guestSessionEnvironment()}});const data=JSON.parse(stdout);result.value=JSON.stringify(data,null,2);return data;}
async function shares(){result.value=JSON.stringify(await checkSharedFolders(),null,2);}
async function incidents(){const f=await remote.dialog.showOpenDialog({title:'Choose a graphics diagnostic JSON',properties:['openFile'],filters:[{name:'Graphics report',extensions:['json']}]});if(!f.canceled)await tool('project-health.py',['incidents','--report',f.filePaths[0]]);}
async function history(){records.value=await tool('project-health.py',['history']);}
async function record(){await tool('project-health.py',['record','--label',label.value]);await history();}
function root(){return new WinboatConfig().config.liveBackupDirectory??path.join(WINBOAT_DIR,'LiveBackups');}
async function backup(action:string,extra:string[]=[],timeout=120000){return tool('backup-manager.py',[action,'--root',root(),...(action==='inventory'?[]:['--id',exportId.value]),...extra],timeout);}
async function stage(){const choice=await remote.dialog.showOpenDialog({title:'Choose a parent folder for a separate restored disk set',properties:['openDirectory']});if(!choice.canceled)await backup('stage',['--destination',choice.filePaths[0]],86400000);}
async function schedule(enabled:boolean){const choice=await remote.dialog.showMessageBox({type:'question',message:enabled?'Enable daily offline checkpoints?':'Disable scheduled backup checks?',detail:enabled?`Keep ${keep.value} scheduled checkpoints after a successful new backup. Leave 10 GiB free. Running Windows is skipped.`:'Existing backup files are kept.',buttons:['Cancel','Continue'],defaultId:0,cancelId:0});if(choice.response===1)await tool('backup-manager.py',[enabled?'schedule-enable':'schedule-disable','--keep',String(keep.value)]);}
async function pair(){const code=String(crypto.randomInt(0,1000000)).padStart(6,'0');pairingCode.value='Compare this code in Windows: '+code;const grant=await pairGuestSession(`http://127.0.0.1:${winboat.getHostPort(GUEST_API_PORT)}`,code,scopes.value);pairingCode.value='Paired until '+grant.expiresAtUtc;result.value=JSON.stringify(grant,null,2);}
</script>
