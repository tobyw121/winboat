<template>
<section class="integration-stack">
 <div v-show="section==='diagnostics'" class="integration-card"><h3>Host & connection checks</h3>
  <p>Check Linux hardware, Windows connectivity or shared folders without changing your configuration.</p>
  <div class="integration-actions"><x-button :disabled="busy || blocked" @click="run(()=>tool('project-health.py',['host']))">Check host hardware</x-button><x-button :disabled="busy || blocked" @click="run(()=>tool('project-health.py',['network']))">Check Windows connection</x-button><x-button :disabled="busy || blocked" @click="run(shares)">Check shared folders</x-button><x-button :disabled="busy || blocked" @click="run(incidents)">Explain a graphics report</x-button></div>
 </div>
 <details v-show="section==='diagnostics'" class="integration-card"><summary>Known application compatibility</summary>
  <p v-for="entry in compatibility" :key="entry.application">{{ entry.application }} — {{ entry.status }}: {{ entry.note }}</p>
  <p>These observations apply to the reported driver and hardware. They do not certify your installation or apply profiles automatically.</p>
 </details>
 <div v-show="section==='performance'" class="integration-card"><h4>Measurement history</h4>
  <p>Save a labeled sample before and after a change, then compare matching environments.</p>
  <label class="integration-field">Sample name<input v-model="label" maxlength="80" placeholder="e.g. Before changing the display cache"></label>
  <div class="integration-actions"><x-button :disabled="busy || blocked" @click="run(record)">Save current sample</x-button><x-button :disabled="busy || blocked" @click="run(history)">Refresh history</x-button></div>
  <svg v-if="points" viewBox="0 0 400 100" role="img" aria-label="Container CPU history, scaled to largest observed sample" class="w-full h-24"><polyline :points="points" fill="none" stroke="var(--integration-accent)" stroke-width="2" /></svg>
  <p v-if="!records.length" class="integration-empty">No history loaded. Save a sample or refresh your history.</p>
  <details><summary>Compare saved samples</summary>
   <div class="integration-fields"><label class="integration-field">Before<select v-model="before"><option value="" disabled>Select a sample</option><option v-for="r in records" :key="r.id" :value="r.id">{{ r.timeUtc }} — {{ r.label }}</option></select></label><label class="integration-field">After<select v-model="after"><option value="" disabled>Select a sample</option><option v-for="r in records" :key="r.id" :value="r.id">{{ r.timeUtc }} — {{ r.label }}</option></select></label></div>
   <x-button :disabled="busy || blocked || !before || !after" @click="run(()=>tool('project-health.py',['compare','--before',before,'--after',after]))">Compare samples</x-button>
   <p>Chart shows container CPU; 100% equals one core. The scale follows the largest sample. Point samples do not establish an FPS improvement.</p>
  </details>
 </div>
 <div v-show="section==='backups'" class="integration-card"><h4>Scheduled snapshots</h4>
  <p>Check once a day for a safely stopped VM and create an offline checkpoint. Running Windows is skipped.</p>
  <div class="integration-fields"><label class="integration-field">Scheduled checkpoints to keep<input v-model.number="keep" type="number" min="1" max="50"><small>Manual snapshots and live disk exports are kept separately.</small></label></div>
  <x-button :disabled="busy || blocked" @click="run(()=>schedule(true))">Enable daily checks</x-button><x-button :disabled="busy || blocked" @click="run(()=>schedule(false))">Disable daily checks</x-button>
  <p>Requires a systemd user session. Existing files are kept when scheduling is disabled.</p>
 </div>
 <details v-show="section==='backups'" class="integration-card"><summary>Verify disk exports & stage a restore</summary>
  <p>Verify an existing export before staging its disks in a new folder. The original VM is kept.</p>
  <label class="integration-field">Export ID<input v-model="exportId" placeholder="ID shown when the disk export started"></label>
  <div class="integration-actions"><x-button :disabled="busy || blocked" @click="run(()=>backup('inventory'))">List exports & available space</x-button><x-button :disabled="busy || blocked || !exportId" @click="run(()=>backup('verify'))">Verify disk checksums</x-button><x-button :disabled="busy || blocked || !exportId" @click="run(stage)">Stage restore in a new folder</x-button></div>
  <p>Staging verifies disk structure and contents, then converts to the original disk formats. TPM state is not included; staged disks are blocked from automatic boot.</p>
 </details>
 <details v-show="section==='diagnostics'" class="integration-card"><summary>Windows API permissions</summary>
  <p>Pair a temporary session with only the permissions you need. First enable session enforcement in Windows Helios Control.</p>
  <div class="integration-fields"><label v-for="scope in availableScopes" :key="scope" class="integration-toggle"><input type="checkbox" v-model="scopes" :value="scope"> {{ scopeLabels[scope] }}</label></div>
  <x-button :disabled="busy || blocked || !scopes.length" @click="run(pair)">Pair for 10 minutes</x-button><x-button :disabled="busy || blocked" @click="run(revokeGuestSession)">Revoke session</x-button>
  <p role="status">{{ pairingCode }}</p>
  <p>Confirm the code in Windows. Tokens stay in memory and apply only to the paired local API endpoint. Older scripts need a token when enforcement is enabled. This does not encrypt LAN traffic.</p>
 </details>
 <div v-if="result" class="integration-feedback" role="status"><details v-if="result.trim().startsWith('{') || result.trim().startsWith('[')"><summary>View check result</summary><pre>{{ result }}</pre></details><span v-else>{{ result }}</span></div>
</section>
</template>
<script setup lang="ts">
import {ref,computed} from 'vue';
import type {IntegrationSection} from '../../shared/integration-navigation';
import {Winboat} from '../lib/winboat';import {WinboatConfig} from '../lib/config';
import {pairGuestSession,revokeGuestSession,guestSessionEnvironment} from '../lib/guest-session';
import {GUEST_API_PORT,WINBOAT_DIR} from '../lib/constants';
import {checkSharedFolders} from '../lib/shared-folders';
import {nativeDesktopEnvironment} from '../../shared/native-desktop-environment';import {hostEnvironment} from '../lib/host-environment';
import {compatibility} from '../data/compatibility';
const props=defineProps<{blocked:boolean;section:IntegrationSection}>(),emit=defineEmits<{busy:[value:boolean]}>();
const remote:typeof import('@electron/remote')=require('@electron/remote'),path:typeof import('path')=require('path'),child:typeof import('child_process')=require('child_process'),util:typeof import('util')=require('util'),crypto:typeof import('crypto')=require('crypto');
const busy=ref(false),result=ref(''),pairingCode=ref(''),label=ref('Manual sample'),records=ref<Array<{id:string;label:string;timeUtc:string;cpuPercentOfOneCore?:number}>>([]),before=ref(''),after=ref(''),exportId=ref(new WinboatConfig().config.lastLiveBackupId??''),keep=ref(5);
const scopeLabels:Record<string,string>={read:'Read status',graphics:'Graphics controls',power:'Windows power',application:'Start applications',clipboard:'Clipboard sharing',maintenance:'Maintenance'};
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
