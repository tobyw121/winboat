<template>
 <div class="space-y-2">
  <h3>Local audio and output windows</h3>
  <p class="text-sm text-neutral-400">Local audio needs Python GI, GStreamer and a compatible Helios host image. Microphone access is separately confirmed and ends when WinBoat closes.</p>
  <x-button :disabled="busy || blocked" @click="run(()=>applyAudio(true))">Enable VM audio (restarts VM)</x-button>
  <x-button :disabled="busy || blocked" @click="run(()=>applyAudio(false))">Disable VM audio</x-button>
  <x-button :disabled="busy || blocked" @click="run(()=>startAudio(false))">Play audio</x-button>
  <x-button :disabled="busy || blocked" @click="run(()=>startAudio(true))">Play + allow microphone</x-button><x-button @click="stopAudio">Stop audio / microphone</x-button>
  <p class="text-sm">{{ audioStatus }}</p>
  <x-button :disabled="busy || blocked" @click="run(refresh)">List exposed display outputs</x-button>
  <select v-model="selected" aria-label="QEMU output" class="bg-neutral-900"><option v-for="output in outputs" :key="output.id" :value="output.id">{{ output.label }} — head {{ output.head }} ({{ output.id }})</option></select>
  <label><input type="checkbox" v-model="resize"> Resize guest to window</label>
  <x-button :disabled="busy || blocked || selected===undefined" @click="run(open)">Open output window</x-button>
  <p class="text-sm text-neutral-400">Each window displays one existing QEMU output. Move windows to your host monitors using the window manager. Extra windows do not create new Windows monitors. Automatic resize sends size hints; the Windows driver must accept them.</p>
  <p class="text-sm whitespace-pre-wrap">{{ message }}</p>
 </div>
</template>
<script setup lang="ts">
import {ref} from 'vue';
import {audioStatus,startAudio,stopAudio,configureAudio,listOutputs,openOutput} from '../lib/integration-display';
const props=defineProps<{blocked:boolean}>(),emit=defineEmits<{busy:[value:boolean];changed:[]}>();
const outputs=ref<Awaited<ReturnType<typeof listOutputs>>>([]),selected=ref<number>(),resize=ref(false),message=ref(''),busy=ref(false);
async function run(action:()=>Promise<void>){if(busy.value||props.blocked)return;busy.value=true;emit('busy',true);try{await action();message.value='Completed.';}catch(error){message.value=String(error);}finally{busy.value=false;emit('busy',false);}}
async function applyAudio(enabled:boolean){if(await configureAudio(enabled))emit('changed');}
async function refresh(){outputs.value=await listOutputs();selected.value=outputs.value[0]?.id;}
async function open(){if(selected.value!==undefined)openOutput(selected.value,resize.value);}
</script>
