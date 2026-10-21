const {StringDecoder}:typeof import('string_decoder')=require('string_decoder');
import type {Socket} from 'node:net';
/** Framed QMP with request IDs: events and concurrent callers cannot steal replies. */
export class QMPTransport {
    private decoder=new StringDecoder('utf8');private buffer='';private next=0;private closed=false;
    private pending=new Map<string,{resolve:(v:any)=>void;reject:(e:Error)=>void;timer:ReturnType<typeof setTimeout>}>();
    private readyResolve!:(v:unknown)=>void;private readyReject!:(e:Error)=>void;
    readonly greeting:Promise<unknown>;
    constructor(private socket:Socket){
        this.greeting=new Promise((yes,no)=>{this.readyResolve=yes;this.readyReject=no;});
        const timer=setTimeout(()=>{this.fail(new Error('QMP greeting timed out'));socket.destroy();},5000);
        this.greeting.then(()=>clearTimeout(timer),()=>clearTimeout(timer));
        socket.on('data',(data:Buffer)=>{
            if(this.closed)return;this.buffer+=this.decoder.write(data);
            if(Buffer.byteLength(this.buffer)>1048576){this.fail(new Error('QMP response too large'));socket.destroy();return;}
            const lines=this.buffer.split('\n');this.buffer=lines.pop()||'';
            for(const line of lines){if(!line.trim())continue;
                let value:any;try{value=JSON.parse(line);}catch{this.fail(new Error('Invalid QMP framing'));socket.destroy();return;}
                if(value.QMP){this.readyResolve(value);continue;}
                const pending=this.pending.get(value.id);if(!pending)continue;
                clearTimeout(pending.timer);this.pending.delete(value.id);pending.resolve(value);
            }
        });
        socket.on('error',error=>this.fail(error));socket.on('close',()=>this.fail(new Error('QMP closed')));
    }
    request(command:string,args?:unknown,timeout=5000):Promise<any>{
        if(this.closed)return Promise.reject(new Error('QMP closed'));
        const id=String(++this.next);
        return new Promise((resolve,reject)=>{
            const timer=setTimeout(()=>{this.pending.delete(id);reject(new Error(`QMP ${command} timed out`));},timeout);
            this.pending.set(id,{resolve,reject,timer});
            this.socket.write(JSON.stringify({execute:command,...(args===undefined?{}:{arguments:args}),id})+'\n',error=>{
                if(error){const p=this.pending.get(id);if(p){clearTimeout(p.timer);this.pending.delete(id);p.reject(error);}}
            });
        });
    }
    private fail(error:Error){
        if(this.closed)return;this.closed=true;this.readyReject(error);
        for(const p of this.pending.values()){clearTimeout(p.timer);p.reject(error);}this.pending.clear();
    }
}
