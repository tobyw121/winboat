<template>
    <div class="flex flex-col gap-4">
        <p class="text-neutral-400 text-sm">Choose the Linux folders available in Windows. Changes take effect after saving and restarting the VM.</p>
        <div v-for="(folder, index) in modelValue" :key="index" class="rounded-lg bg-neutral-800 p-3 flex flex-col gap-3">
            <div class="flex items-center justify-between gap-3">
                <label class="text-sm"><input type="checkbox" :checked="folder.enabled" :disabled="disabled" @change="update(index, {enabled: ($event.target as HTMLInputElement).checked})" /> Enabled</label>
                <label class="text-sm"><input type="checkbox" :checked="folder.readOnly" :disabled="disabled" @change="update(index, {readOnly: ($event.target as HTMLInputElement).checked})" /> Read only</label>
                <x-button :disabled="disabled" @click="remove(index)">Remove</x-button>
            </div>
            <label class="text-sm">Windows share name
                <input class="block w-full rounded bg-neutral-900 p-2 mt-1" :value="folder.name" :disabled="disabled" maxlength="64" @input="update(index, {name: ($event.target as HTMLInputElement).value})" />
            </label>
            <label class="text-sm">Linux folder
                <div class="flex gap-2 mt-1"><input class="w-full min-w-0 rounded bg-neutral-900 p-2" :value="folder.hostPath" :disabled="disabled" @input="update(index, {hostPath: ($event.target as HTMLInputElement).value})" /><x-button :disabled="disabled" @click="browse(index)">Browse</x-button></div>
            </label>
            <div class="flex gap-2 items-center text-sm"><code class="break-all">{{ sharePath(folder.name) }}</code><x-button @click="copy(folder.name)">Copy path</x-button></div>
        </div>
        <p v-if="!modelValue.length" class="text-sm text-neutral-400">No Linux folders are shared.</p>
        <p v-for="error in errors" :key="error" class="text-sm text-red-300">{{ error }}</p>
        <p v-if="message" class="text-sm text-red-300">{{ message }}</p>
        <div class="flex gap-3"><x-button :disabled="disabled || modelValue.length >= 16" @click="add">Add folder</x-button></div>
        <p v-if="modelValue.some(folder => folder.enabled)" class="text-sm text-neutral-400">In Windows Explorer, enter the copied path directly. Sign in as <strong>winboat</strong> using your Windows VM password. Network discovery and FreeRDP are not required.</p>
    </div>
</template>
<script setup lang="ts">
import {computed,ref} from 'vue';
import {sharePath,sharedFolderErrors,type SharedFolder} from '../../shared/shared-folders';
import {selectSharedFolder,defaultShareName} from '../lib/shared-folders';
const props = defineProps<{modelValue:SharedFolder[];disabled?:boolean}>();
const emit = defineEmits<{'update:modelValue':[SharedFolder[]]}>();
const errors = computed(()=>sharedFolderErrors(props.modelValue));
const message = ref('');
function update(index:number, values:Partial<SharedFolder>) {emit('update:modelValue',props.modelValue.map((folder,i)=>i===index?{...folder,...values}:folder));}
function remove(index:number) {emit('update:modelValue',props.modelValue.filter((_,i)=>i!==index));}
async function add() {try {message.value='';const hostPath=await selectSharedFolder();if(hostPath) emit('update:modelValue',[...props.modelValue,{name:defaultShareName(hostPath,props.modelValue),hostPath,enabled:true,readOnly:false}]);} catch(error) {message.value=String(error);}}
async function browse(index:number) {try {message.value='';const hostPath=await selectSharedFolder(props.modelValue[index].hostPath);if(hostPath) update(index,{hostPath});} catch(error) {message.value=String(error);}}
function copy(name:string) {const {clipboard}:typeof import('electron')=require('electron');clipboard.writeText(sharePath(name));}
</script>
