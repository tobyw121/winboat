import {guestSessionEnvironment} from './guest-session';
import {ref} from 'vue';
import {nativeDesktopEnvironment} from '../../shared/native-desktop-environment';
import {hostEnvironment} from './host-environment';
const remote:typeof import('@electron/remote')=require('@electron/remote');
const child:typeof import('child_process')=require('child_process');
const path:typeof import('path')=require('path');
const {promisify}:typeof import('util')=require('util');
export const trialRunning=ref(false);
export const trialMessage=ref('');
type State={id:string;phase:string;route?:string};
async function run(args:string[]):Promise<State> {
    const script=remote.app.isPackaged?path.join(process.resourcesPath,'graphics-tools','graphics-trial.py')
        :path.resolve(remote.app.getAppPath(),'../..','scripts/helios/graphics-trial.py');
    const {stdout}=await promisify(child.execFile)('python3',[script,...args],{timeout:180000,maxBuffer:65536,
        env:{...nativeDesktopEnvironment(hostEnvironment(),remote.app.isPackaged?path.dirname(process.resourcesPath):undefined),...guestSessionEnvironment()}});
    const state=JSON.parse(stdout.trim().split('\n').pop()??'');
    if(!/^[a-f0-9]{32}$/.test(state.id)||typeof state.phase!=='string')throw new Error('Invalid graphics trial state');
    return state;
}
async function settle(state:State,phase:string):Promise<State> {
    for(let i=0;i<20&&state.phase===phase;i++) {
        await new Promise(resolve=>setTimeout(resolve,500));
        state=await run(['--status',state.id]);
    }
    return state;
}
export async function testHelios():Promise<void> {
    if(trialRunning.value)return;
    trialRunning.value=true;
    try {
        const consent=await remote.dialog.showMessageBox({type:'warning',title:'Test installed Helios for 60 seconds',
            message:'Enable the installed Helios driver for a timed test?',
            detail:'Requires disabled Helios and healthy primary VGA. If you do not confirm within 60 seconds, an independent host watchdog requests VGA recovery. If the guest API fails, it may restart this VM in VGA-only rescue mode. Save work first. This does not install or replace a driver.',
            buttons:['Start test','Cancel'],defaultId:1,cancelId:1});
        if(consent.response!==0)return;
        trialMessage.value='Starting timed Helios test…';
        let state=await settle(await run(['--start']),'armed');
        if(state.phase!=='enabled')throw new Error(`Trial state: ${state.phase}. The watchdog handles an unconfirmed active trial.`);
        trialMessage.value='Check both displays. Without confirmation, VGA recovery starts after 60 seconds.';
        const result=await remote.dialog.showMessageBox({type:'question',title:'Keep Helios enabled?',
            message:'Are VGA and Helios both showing a stable image?',
            detail:'Choose Keep only after visually checking both displays. The watchdog expires independently while this dialog is open.',
            buttons:['Keep Helios','Return to VGA'],defaultId:1,cancelId:1});
        state=await run(['--status',state.id]);
        if(state.phase==='enabled') {
            state=await run([result.response===0?'--confirm':'--cancel',state.id]);
            if(result.response===0)state=await settle(state,'enabled');
        }
        trialMessage.value=state.phase==='confirmed'?'Helios kept after your confirmation and a fresh adapter check.'
            :`Trial state: ${state.phase}. VGA recovery may restart the VM; use Browser Display after host rescue.`;
    } catch(error) {
        trialMessage.value=`Helios trial: ${error instanceof Error?error.message:String(error)}. An armed watchdog remains independent of this window.`;
    } finally {trialRunning.value=false;}
}
