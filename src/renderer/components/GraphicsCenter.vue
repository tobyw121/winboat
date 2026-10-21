<template>
    <div class="mt-4 border-t border-neutral-700 pt-3">
        <h2 class="font-semibold">Graphics status and recovery</h2>
        <p class="text-sm text-neutral-400">Refresh on demand. Missing data is unknown; driver detection does not prove working rendering.</p>
        <x-button :disabled="busy || blocked" @click="run('status')">Refresh loaded versions and transport</x-button>
        <dl v-if="status" class="text-sm grid grid-cols-2 gap-2 mt-3">
            <dt>Bound driver versions</dt><dd>{{ status.boundVersions?.join(', ') || 'unknown' }}</dd>
            <dt>Stable / candidate</dt><dd>{{ status.stable }} / {{ status.candidate }}</dd>
            <dt>Host runtime / backend</dt><dd>{{ status.runtime }} / {{ status.backend }}</dd>
            <dt>Last acknowledged transport</dt><dd>{{ status.transport?.transport || 'unknown' }} ({{ status.transport?.state }})</dd>
            <dt>Update transaction</dt><dd>{{ status.transaction?.status || 'not-recorded' }}</dd>
        </dl>
        <details v-if="status"><summary>Adapter, loaded module and error details</summary><pre class="text-xs whitespace-pre-wrap max-h-64 overflow-auto">{{ JSON.stringify(status,null,2) }}</pre></details>
        <div class="flex flex-wrap gap-2 mt-3">
            <x-button v-for="item in actions" :key="item[0]" :disabled="busy || blocked" @click="run(item[0])">{{ item[1] }}</x-button>
        </div>
        <p class="text-sm text-neutral-400 mt-2">Rollback requires a recorded stable package and a VGA-only rescue boot. Restoring host graphics does not automatically accept a candidate or re-enable a guest-disabled driver. Driver installation and visual acceptance remain in Windows Helios Control.</p>
        <h3 class="font-semibold mt-3">Offline recovery backup</h3>
        <p class="text-sm text-neutral-400">Shut down Windows cleanly first. Saves the complete bind-mounted storage and private container configuration. External disks and shared folders are excluded. The archive can contain passwords; keep it private.</p>
        <x-button :disabled="busy || blocked" @click="backup(false)">Create verified storage backup</x-button>
        <x-button :disabled="busy || blocked" @click="backup(true)">Verify existing backup</x-button>
        <h3 class="font-semibold mt-3">Performance comparison</h3>
        <p class="text-sm text-neutral-400">Same workload and resolution for A1/B1/A2/B2. Records container CPU and available host GPU sensors for about 20 seconds; no guest FPS is inferred.</p>
        <input v-model="workload" aria-label="Workload comparison key" placeholder="same-scene-1920x1080" class="bg-neutral-900 p-2" />
        <select v-model="label" aria-label="Comparison arm" class="bg-neutral-900 p-2"><option v-for="arm in ['A1','B1','A2','B2']" :key="arm">{{ arm }}</option></select>
        <x-button :disabled="busy || blocked" @click="measure">Record measurement</x-button>
        <x-button :disabled="busy || blocked" @click="compareMeasurements">Compare four measurements</x-button>
        <p class="text-sm mt-2">{{ message }}</p>
    </div>
</template>
<script setup lang="ts">
import {ref,watch} from 'vue';
import {nativeDesktopEnvironment} from '../../shared/native-desktop-environment';
import {hostEnvironment} from '../lib/host-environment';
defineProps<{blocked:boolean}>();
const emit=defineEmits<{busy:[value:boolean]}>();
const remote:typeof import('@electron/remote')=require('@electron/remote');
const child:typeof import('child_process')=require('child_process');
const path:typeof import('path')=require('path');
const {promisify}:typeof import('util')=require('util');
const workload=ref(''),label=ref('A1');
const busy=ref(false),message=ref('');const status=ref<Record<string,any>>();
watch(busy,value=>emit('busy',value));
const actions=[['helios-disable','Disable Helios; keep VGA'],['rescue-boot','VGA-only rescue boot'],['restore-host','Restore host graphics'],['check-update','Check update transaction'],['prepare-rollback','Prepare stable rollback'],['capture-enable','Capture DWM dumps (30 minutes)'],['capture-disable','Stop DWM dump capture']];
function scriptPath(name:string){return remote.app.isPackaged?path.join(process.resourcesPath,'graphics-tools',name):path.resolve(remote.app.getAppPath(),'../..','scripts/helios',name);}
async function execute(name:string,args:string[]){return promisify(child.execFile)('python3',[scriptPath(name),...args],{timeout:240000,maxBuffer:262144,
    env:nativeDesktopEnvironment(hostEnvironment(),remote.app.isPackaged?path.dirname(process.resourcesPath):undefined)});}
async function backup(verify:boolean){
    if(busy.value)return;busy.value=true;
    try{
        let file:string|undefined;
        if(verify){
            const choice=await remote.dialog.showOpenDialog({title:'Verify private offline backup',properties:['openFile'],filters:[{name:'TAR backup',extensions:['tar']}]});
            if(choice.canceled)return;file=choice.filePaths[0];
        }else{
            const choice=await remote.dialog.showSaveDialog({title:'Save private offline storage backup',defaultPath:'winboat-private-backup.tar'});
            if(choice.canceled)return;file=choice.filePath;
        }
        if(!file)return;message.value='Verifying storage. Large disks can take several minutes…';
        const {stdout}=await promisify(child.execFile)('python3',[scriptPath('backup-vm.py'),verify?'--verify':'--create',file],
            {timeout:24*60*60*1000,maxBuffer:65536,env:nativeDesktopEnvironment(hostEnvironment(),remote.app.isPackaged?path.dirname(process.resourcesPath):undefined)});
        message.value=JSON.stringify(JSON.parse(stdout));remote.shell.showItemInFolder(file);
    }catch(error){message.value=error instanceof Error?error.message:String(error);}finally{busy.value=false;}
}
async function measure(){
    if(busy.value)return;busy.value=true;
    try{
        if(!/^[a-zA-Z0-9_.-]{1,96}$/.test(workload.value))throw new Error('Enter the same short scene/resolution key for all four runs.');
        const choice=await remote.dialog.showSaveDialog({title:'Save performance measurement',defaultPath:`helios-${label.value}.json`,filters:[{name:'JSON',extensions:['json']}]});
        if(choice.canceled||!choice.filePath)return;message.value='Recording. Keep the workload unchanged…';
        await execute('measure-performance.py',['--label',label.value,'--comparison-key',workload.value,'--output',choice.filePath]);
        message.value=`Saved ${label.value}. Repeat the same scene for the remaining arms.`;remote.shell.showItemInFolder(choice.filePath);
    }catch(error){message.value=error instanceof Error?error.message:String(error);}finally{busy.value=false;}
}
async function compareMeasurements(){
    if(busy.value)return;busy.value=true;
    try{
        const files:string[]=[];
        for(const arm of ['A1','B1','A2','B2']){
            const choice=await remote.dialog.showOpenDialog({title:`Select ${arm} measurement`,properties:['openFile'],filters:[{name:'JSON',extensions:['json']}]});
            if(choice.canceled)return;files.push(choice.filePaths[0]);
        }
        const {stdout}=await execute('compare-graphics.py',files);message.value=JSON.stringify(JSON.parse(stdout),null,2);
    }catch(error){message.value=error instanceof Error?error.message:String(error);}finally{busy.value=false;}
}
async function run(action:string){
    if(busy.value)return;busy.value=true;
    try{
        if(action!=='status'){
            const answer=await remote.dialog.showMessageBox({type:'warning',message:`${actions.find(item=>item[0]===action)?.[1]}?`,
                detail:action.startsWith('capture-')?'Dumps may contain private memory and stay in Windows. Capture expires after 30 minutes. No dump is uploaded.':'Save work first. Host rescue/recovery can restart this VM. Rollback only cleans verified Helios packages with Helios physically absent; Windows data is preserved.',
                buttons:['Continue','Cancel'],defaultId:1,cancelId:1});
            if(answer.response!==0)return;
        }
        message.value='Working…';
        const script=remote.app.isPackaged?path.join(process.resourcesPath,'graphics-tools','graphics-center.py'):path.resolve(remote.app.getAppPath(),'../..','scripts/helios/graphics-center.py');
        const {stdout}=await promisify(child.execFile)('python3',[script,action],{timeout:240000,maxBuffer:262144,
            env:nativeDesktopEnvironment(hostEnvironment(),remote.app.isPackaged?path.dirname(process.resourcesPath):undefined)});
        const data=JSON.parse(stdout.trim().split('\n').pop()??'');
        if(action==='status'){status.value=data;message.value='Updated. No driver or VM setting changed.';}
        else message.value=`Result: ${data.status || 'completed'}. Refresh status after Windows is available.`;
    }catch(error){message.value=error instanceof Error?error.message:String(error);}
    finally{busy.value=false;}
}
</script>
