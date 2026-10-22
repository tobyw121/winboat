<template>
 <section class="integration-stack">
  <div class="integration-card"><h3>Windows audio</h3>
   <p>Play VM audio through Linux. Microphone access is optional and ends when WinBoat closes.</p>
   <div class="integration-actions"><x-button class="integration-primary" :disabled="busy || blocked" @click="run(()=>startAudio(false))">Play Windows audio</x-button><x-button :disabled="busy || blocked" @click="run(()=>startAudio(true))">Play & allow microphone</x-button><x-button @click="stopAudio">Stop audio & microphone</x-button></div>
   <p role="status">{{ audioStatus }}</p>
   <details><summary>Audio setup</summary><p>Requires Python GI, GStreamer and a compatible Helios host image. Enabling VM audio restarts Windows.</p><x-button :disabled="busy || blocked" @click="run(()=>applyAudio(true))">Enable audio & restart</x-button><x-button :disabled="busy || blocked" @click="run(()=>applyAudio(false))">Disable VM audio</x-button></details>
  </div>
  <div class="integration-card"><h3>Additional display windows</h3>
   <p>Open an existing Windows display in its own Local Desktop window.</p>
   <x-button :disabled="busy || blocked" @click="run(refresh)">Find display outputs</x-button>
   <div class="integration-fields"><label class="integration-field">Display output<select v-model="selected"><option v-if="!outputs.length" :value="undefined" disabled>Find outputs to get started</option><option v-for="output in outputs" :key="output.id" :value="output.id">{{ output.label }} · display {{ output.head }} ({{ output.id }})</option></select></label></div>
   <label class="integration-toggle"><input type="checkbox" v-model="resize"> Match Windows resolution to the window size</label>
   <x-button :disabled="busy || blocked || selected===undefined" @click="run(open)">Open display window</x-button>
   <details><summary>Multiple monitor behavior</summary><p>Each window shows one existing VM output. Move it between Linux monitors as usual. Opening a window does not add a Windows monitor. Automatic resizing requires support from the installed Windows driver.</p></details>
  </div>
  <p v-if="message" class="integration-feedback" role="status">{{ message }}</p>
 </section>
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
