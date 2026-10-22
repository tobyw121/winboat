import {ref} from 'vue';
import {ClipboardEchoGuard,validClipboardText} from '../../shared/clipboard-sync';
import {Winboat} from './winboat';
import {GUEST_API_PORT} from './constants';
const remote:typeof import('@electron/remote')=require('@electron/remote');
const fetch:typeof import('node-fetch').default=require('node-fetch');
const crypto:typeof import('crypto')=require('crypto');
const winboat=new Winboat();
export const clipboardState=ref('disconnected'),clipboardMessage=ref('');
let endpoint='',token='',toGuest=false,toHost=false,timer:ReturnType<typeof setTimeout>|undefined,guard:ClipboardEchoGuard|undefined,busy=false,generation=0;
function base(){return `http://127.0.0.1:${winboat.getHostPort(GUEST_API_PORT)}/integration/clipboard`;}
async function request(method:string,body?:unknown,connect=false){
    const response=await fetch(endpoint||base(),{method,timeout:5000,headers:{'Content-Type':'application/json',...(connect?{'X-WinBoat-Clipboard':'connect'}:{'X-WinBoat-Clipboard-Token':token})},body:body===undefined?undefined:JSON.stringify(body)});
    if(!response.ok)throw new Error(`Clipboard unavailable (${response.status}); reconnect after signing in or updating the guest service.`);
    return response.json();
}
export async function stopClipboard(){
    generation++;if(timer)clearTimeout(timer);timer=undefined;
    if(token){try{await request('DELETE');}catch{/* Guest may have stopped. */}}
    token='';guard=undefined;clipboardState.value='disconnected';
}
export async function startClipboard(readHost:boolean,readGuest:boolean){
    await stopClipboard();toGuest=readHost;toHost=readGuest;
    endpoint=base();const epoch=generation;guard=new ClipboardEchoGuard(remote.clipboard.readText(),crypto.randomBytes(16).toString('hex'));
    const result=await request('POST',{toGuest,toHost},true);
    if(epoch!==generation)return;token=result.token;clipboardState.value='consent-pending';clipboardMessage.value='Confirm text sharing in the Windows desktop.';
    const tick=async()=>{
        if(epoch!==generation)return;
        try{
            const value=await request('GET');if(epoch!==generation)return;
            clipboardState.value=value.state;
            if(['locked','denied','closed'].includes(value.state)){await stopClipboard();clipboardMessage.value='Sharing stopped. Sign in/unlock Windows and reconnect.';return;}
            if(value.state==='active' && !busy){
                const local=toGuest?guard?.localChange(remote.clipboard.readText()):undefined;
                if(local)await request('POST',local);
                else if(toHost){const text=guard?.remoteChange(value);if(text!==undefined)remote.clipboard.writeText(text);}
                clipboardMessage.value='Plain text sharing active. Files are excluded; host empty text is sent only on request.';
            }
        }catch(error){if(epoch!==generation)return;await stopClipboard();clipboardMessage.value=String(error);return;}
        if(epoch===generation)timer=setTimeout(tick,1000);
    };void tick();
}
export async function transferClipboard(direction:'send'|'receive'){
    if(!token || clipboardState.value!=='active')throw new Error('Connect and confirm clipboard sharing first.');busy=true;
    try{
        if(direction==='receive')await request('POST',{kind:'read'});
        else{const text=remote.clipboard.readText();if(!validClipboardText(text))throw new Error('Plain text exceeds 256 KiB or contains NUL.');await request('POST',{kind:'write',text,origin:crypto.randomBytes(16).toString('hex')});}
    }finally{busy=false;}
}
