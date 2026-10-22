import {guestFetch} from './guest-session';
import {ref} from 'vue';
import {ClipboardEchoGuard,validClipboardText} from '../../shared/clipboard-sync';
import {Winboat} from './winboat';
import {GUEST_API_PORT} from './constants';
const remote:typeof import('@electron/remote')=require('@electron/remote');
const fetch:typeof import('node-fetch').default=guestFetch;
const crypto:typeof import('crypto')=require('crypto');
const winboat=new Winboat();
export const clipboardState=ref('disconnected'),clipboardMessage=ref('');
let imageSharing=false;
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
export async function startClipboard(readHost:boolean,readGuest:boolean,images=false){
    await stopClipboard();toGuest=readHost;toHost=readGuest;imageSharing=images;
    endpoint=base();const epoch=generation;guard=new ClipboardEchoGuard(remote.clipboard.readText(),crypto.randomBytes(16).toString('hex'));
    const result=await request('POST',{toGuest,toHost,images},true);
    if(epoch!==generation)return;token=result.token;clipboardState.value='consent-pending';clipboardMessage.value='Confirm text sharing in the Windows desktop.';
    const tick=async()=>{
        if(epoch!==generation)return;
        try{
            const value=await request('GET');if(epoch!==generation)return;
            clipboardState.value=value.state;
            if(['locked','denied','closed'].includes(value.state)){await stopClipboard();clipboardMessage.value='Sharing stopped. Sign in/unlock Windows and reconnect.';return;}
            if(value.state==='active' && !busy){
                const local=toGuest?guard?.localChange(remote.clipboard.readText()):undefined;
                if(value.kind==='image' && value.png && imageSharing && toHost){const image=remote.nativeImage.createFromBuffer(Buffer.from(value.png,'base64'));if(!image.isEmpty())remote.clipboard.writeImage(image);}
                else if(local)await request('POST',local);
                else if(toHost){
                    if(value.kind==='image' && value.png && imageSharing){const image=remote.nativeImage.createFromBuffer(Buffer.from(value.png,'base64'));if(!image.isEmpty())remote.clipboard.writeImage(image);}
                    else if(value.kind!=='image' && value.kind!=='unsupported'){const text=guard?.remoteChange(value);if(text!==undefined)remote.clipboard.writeText(text);}
                }
                if(value.kind==='unsupported'){clipboardMessage.value='Requested clipboard format is unavailable, busy or exceeds the transfer limit.';}

                if(value.kind!=='unsupported')clipboardMessage.value='Text sharing active; images transfer only on explicit request. Files are excluded.';
            }
        }catch(error){if(epoch!==generation)return;await stopClipboard();clipboardMessage.value=String(error);return;}
        if(epoch===generation)timer=setTimeout(tick,1000);
    };void tick();
}
export async function transferClipboard(direction:'send'|'receive'){
    if(!token || clipboardState.value!=='active')throw new Error('Connect and confirm clipboard sharing first.');busy=true;
    try{
        if(direction==='receive')await request('POST',{kind:'read-large'});
        else{const text=remote.clipboard.readText();if(!validClipboardText(text,true))throw new Error('Plain text exceeds 4 MiB or contains NUL.');await request('POST',{kind:'write',text,origin:crypto.randomBytes(16).toString('hex')});}
    }finally{busy=false;}
}

export async function transferClipboardImage(direction:'send'|'receive'){
 if(!token || clipboardState.value!=='active' || !imageSharing)throw new Error('Connect with image sharing enabled and confirm in Windows first.');
 busy=true;
 try{
  if(direction==='receive')await request('POST',{kind:'image-read'});
  else {const image=remote.clipboard.readImage();if(image.isEmpty())throw new Error('No host image in clipboard.');const size=image.getSize();if(size.width>4096||size.height>4096||size.width*size.height>8*1024*1024)throw new Error('Image dimensions exceed transfer bounds.');const png=image.toPNG();if(png.length>8*1024*1024)throw new Error('PNG exceeds 8 MiB.');await request('POST',{kind:'image-write',png:png.toString('base64')});}
 }finally{busy=false;}
}
