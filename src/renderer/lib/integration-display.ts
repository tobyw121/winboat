import {ref} from 'vue';
import {WinboatConfig} from './config';
import {Winboat} from './winboat';
import {localDisplayDirectory} from './helios-display';
import {heliosDisplayAddress} from '../../shared/helios-display';
import {nativeDesktopEnvironment} from '../../shared/native-desktop-environment';
import {hostEnvironment} from './host-environment';
const remote:typeof import('@electron/remote')=require('@electron/remote');
const child:typeof import('child_process')=require('child_process'),path:typeof import('path')=require('path');
const winboat=new Winboat();let audio:import('child_process').ChildProcess|undefined;
const windows=new Set<import('child_process').ChildProcess>();
export const audioStatus=ref('stopped');
function env(){return {...nativeDesktopEnvironment(hostEnvironment(),remote.app.isPackaged?path.dirname(process.resourcesPath):undefined),HELIOS_VIEWER_SHARPEN:String(new WinboatConfig().config.viewerSharpenPercent??0),HELIOS_VIEWER_CONTRACT:new WinboatConfig().config.viewerContractTrace?'1':'0',HELIOS_VIEWER_BACKGROUND_FPS:String(new WinboatConfig().config.viewerBackgroundFPS??0),HELIOS_VIEWER_TRANSPORT:new WinboatConfig().config.viewerTransport??'auto'};}
function helper(){return remote.app.isPackaged?path.join(process.resourcesPath,'native/helios-audio.py'):path.resolve(remote.app.getAppPath(),'../..','native/helios-audio/audio.py');}
function viewer(){return remote.app.isPackaged?path.join(process.resourcesPath,'native/winboat-helios-viewer'):path.resolve(remote.app.getAppPath(),'../..','build/native/winboat-helios-viewer');}
export async function startAudio(microphone:boolean){
 stopAudio();
 if(winboat.parseCompose().services.windows.environment.HELIOS_AUDIO_DBUS!=='1')throw new Error('Enable local audio in the VM configuration first.');
 if(microphone&&(await remote.dialog.showMessageBox({type:'question',message:'Allow this Windows VM to use your microphone?',detail:'Recording stops when local audio stops or WinBoat closes. Other host applications and VMs may still use the device.',buttons:['Cancel','Allow microphone'],defaultId:0,cancelId:0})).response!==1)return;
 audioStatus.value='connecting';const process=child.spawn('python3',[helper(),'--address',heliosDisplayAddress(localDisplayDirectory()),...(microphone?['--microphone']:[])],{env:env(),stdio:['pipe','pipe','pipe']});audio=process;
 let output='',error='';process.stdout?.on('data',chunk=>{output=(output+chunk).slice(-4096);if(output.includes('"state": "connected"'))audioStatus.value=microphone?'connected — microphone allowed':'connected — playback available';});
 process.stderr?.on('data',chunk=>{error=(error+chunk).slice(-4096);});
 process.on('error',error=>{if(audio===process){audio=undefined;audioStatus.value=String(error);}});
 process.on('exit',code=>{if(audio===process){audio=undefined;audioStatus.value=code?`Audio unavailable: ${error}`:'stopped';}});
}
export function stopAudio(){if(audio){const process=audio;audio=undefined;process.stdin?.end();process.kill('SIGTERM');}audioStatus.value='stopped';}
export async function configureAudio(enabled:boolean):Promise<boolean>{
 const next=winboat.parseCompose();
 if(enabled){const {promisify}:typeof import('util')=require('util');const {stdout}=await promisify(child.execFile)('docker',['image','inspect','--format','{{index .Config.Labels \"org.winboat.integration.audio\"}}',next.services.windows.image],{timeout:5000});if(stdout.trim()!=='dbus-v1')throw new Error('Rebuild the Helios host image to enable local audio.');}
 if(enabled&&next.services.windows.environment.HELIOS_DISPLAY!=='dbus')throw new Error('Local audio requires Local Desktop.');
 if((await remote.dialog.showMessageBox({type:'question',message:'Apply local audio configuration and restart the VM?',detail:'Save open Windows work first. Requires a newly built Helios host image. Microphone capture remains off until explicitly allowed.',buttons:['Cancel','Restart'],defaultId:0,cancelId:0})).response!==1)return false;
 stopAudio();if(enabled)next.services.windows.environment.HELIOS_AUDIO_DBUS='1';else delete next.services.windows.environment.HELIOS_AUDIO_DBUS;await winboat.replaceCompose(next);return true;
}
export async function listOutputs(){
 const {promisify}:typeof import('util')=require('util');
 const {stdout}=await promisify(child.execFile)(viewer(),['--list-outputs',heliosDisplayAddress(localDisplayDirectory())],{env:env(),timeout:8000,maxBuffer:32768});return JSON.parse(stdout) as {id:number;label:string;head:number}[];
}
export function openOutput(id:number,autoResize:boolean){
 if(!Number.isInteger(id)||id<0||id>0xffffffff)throw new Error('Choose an exposed QEMU output.');
 const process=child.spawn(viewer(),['--address',heliosDisplayAddress(localDisplayDirectory()),'--output',String(id),...(autoResize?['--auto-resize']:[]),'--control-stdin'],{env:env(),stdio:['pipe','ignore','pipe']});
 windows.add(process);let error='';process.stderr?.on('data',chunk=>{error=(error+chunk).slice(-4096);});
 process.on('error',error=>remote.dialog.showErrorBox('Display unavailable',String(error)));process.on('exit',code=>{windows.delete(process);if(code)remote.dialog.showErrorBox('Display unavailable',error);});
}
window.addEventListener('beforeunload',()=>{stopAudio();for(const child of windows){child.stdin?.end();child.kill('SIGTERM');}});
