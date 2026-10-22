/** Plain text only; suppress echoes without storing a clipboard history. */
export const CLIPBOARD_TEXT_LIMIT=256*1024;
export function validClipboardText(text:string,manual=false):boolean {
    return !text.includes('\0') && Buffer.byteLength(text,'utf8')<=(manual?4*1024*1024:CLIPBOARD_TEXT_LIMIT);
}
export class ClipboardEchoGuard {
    private local='';private remoteRevision=0;
    constructor(initial:string,private origin:string){this.local=initial;}
    localChange(text:string):{kind:string;text:string;origin:string}|undefined {
        if(text===this.local || !text || !validClipboardText(text))return;
        this.local=text;return {kind:'write',text,origin:this.origin};
    }
    remoteChange(value:{revision:number;text?:string;origin?:string}):string|undefined {
        if(!Number.isSafeInteger(value.revision) || value.revision<=this.remoteRevision)return;
        this.remoteRevision=value.revision;
        if(typeof value.text!=='string' || !validClipboardText(value.text,true) || value.origin===this.origin)return;
        this.local=value.text;return value.text;
    }
}
