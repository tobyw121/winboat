<template>
 <section class="rounded-xl border border-neutral-600 p-4 mt-5 space-y-3" aria-labelledby="import-vm-title">
  <h2 id="import-vm-title" class="text-xl font-semibold">Use an existing Windows VM</h2>
  <p class="text-gray-400">Select its storage folder or the retained WinBoat configuration folder. Windows, installed applications and VM settings are kept.</p>
  <x-button :disabled="busy" @click="choose">Choose VM folder</x-button>
  <div v-if="candidate" class="text-sm space-y-2">
   <p class="break-all">{{ candidate.storage }}</p>
   <p>{{ candidate.disks.join(', ') }} · {{ candidate.compose.services.windows.environment.CPU_CORES }} CPU cores · {{ candidate.compose.services.windows.environment.RAM_SIZE }} RAM</p>
   <p class="break-all">Image: {{ candidate.compose.services.windows.image }}</p>
   <p>Only import your own trusted VM. Its saved configuration grants Docker access to host devices and folders. Import does not start Windows.</p>
   <label class="flex gap-2"><input v-model="trusted" type="checkbox" :disabled="busy">I trust this VM and its saved configuration.</label>
   <x-button toggled :disabled="busy || !trusted" @click="restore">{{ busy ? 'Importing…' : 'Import existing VM' }}</x-button>
  </div>
  <p v-if="message" role="status" class="text-sm whitespace-pre-wrap">{{ message }}</p>
 </section>
</template>
<script setup lang="ts">
import {ref} from 'vue';
import {inspectVmRecovery,type VmRecovery} from '../../shared/vm-recovery';
import {importExistingVm} from '../lib/vm-import';
const remote:typeof import('@electron/remote')=require('@electron/remote');
const candidate=ref<VmRecovery>();const busy=ref(false),trusted=ref(false),message=ref('');
async function choose(){
 candidate.value=undefined;trusted.value=false;message.value='';
 const result=await remote.dialog.showOpenDialog({title:'Select existing WinBoat VM',properties:['openDirectory']});
 if(result.canceled)return;
 try{candidate.value=inspectVmRecovery(result.filePaths[0]);}catch(error){message.value=String(error);}
}
async function restore(){
 if(!candidate.value||!trusted.value||busy.value)return;
 busy.value=true;message.value='';
 try{await importExistingVm(candidate.value);window.location.reload();}
 catch(error){message.value=String(error);}finally{busy.value=false;}
}
</script>
