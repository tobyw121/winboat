<template>
 <section class="rounded-xl border border-neutral-600 p-4 my-5 space-y-2">
  <h2 class="text-xl font-semibold">Reinstall recovery</h2>
  <p class="text-gray-400">Keep the entire VM folder, including its hidden .winboat-recovery folder. After reinstalling WinBoat, choose “Use an existing Windows VM” on the welcome screen.</p>
  <p role="status" class="text-sm break-all">{{ message }}</p>
  <div class="flex gap-3">
   <x-button @click="save">Update recovery details</x-button>
   <x-button :disabled="!storage" @click="reveal">Show VM folder</x-button>
  </div>
 </section>
</template>
<script setup lang="ts">
import {onMounted,ref} from 'vue';
import {inspectVmRecovery,saveVmRecovery,RECOVERY_FOLDER} from '../../shared/vm-recovery';
import {WINBOAT_DIR} from '../lib/constants';
const remote:typeof import('@electron/remote')=require('@electron/remote');
const path:typeof import('path')=require('path');
const message=ref(''),storage=ref('');
function refresh(){
 try{
  storage.value=inspectVmRecovery(WINBOAT_DIR).storage;
  inspectVmRecovery(storage.value);
  message.value='Recovery details available: '+path.join(storage.value,RECOVERY_FOLDER);
 }catch(error){message.value='Recovery details need attention: '+String(error);}
}
function save(){try{saveVmRecovery(WINBOAT_DIR);refresh();}catch(error){message.value=String(error);}}
function reveal(){if(storage.value)remote.shell.showItemInFolder(path.join(storage.value,RECOVERY_FOLDER));}
onMounted(refresh);
</script>
