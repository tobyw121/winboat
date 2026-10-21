import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
export async function copyExchangeFile(source:string,destination:string,progress:(bytes:number,total:number)=>void,signal?:AbortSignal):Promise<{bytes:number;sha256:string}>{
    const input=await fs.promises.open(source,fs.constants.O_RDONLY|fs.constants.O_NOFOLLOW);
    const temporary=path.join(path.dirname(destination),'.winboat-transfer-'+crypto.randomBytes(16).toString('hex'));
    try{
        const before=await input.stat();if(!before.isFile())throw new Error('Choose a regular file.');
        if(fs.existsSync(destination))throw new Error('Destination exists; choose a new filename.');
        const output=await fs.promises.open(temporary,fs.constants.O_WRONLY|fs.constants.O_CREAT|fs.constants.O_EXCL|fs.constants.O_NOFOLLOW,0o600);
        let count=0;const hash=crypto.createHash('sha256');
        try{
            const buffer=Buffer.alloc(256*1024);
            while(true){
                if(signal?.aborted)throw new Error('Transfer cancelled.');
                const {bytesRead}=await input.read(buffer,0,buffer.length,null);if(!bytesRead)break;
                let written=0;while(written<bytesRead){
                    const result=await output.write(buffer,written,bytesRead-written,null);
                    if(!result.bytesWritten)throw new Error('Destination stopped accepting data.');written+=result.bytesWritten;
                }
                hash.update(buffer.subarray(0,bytesRead));count+=bytesRead;progress(count,before.size);
            }
            await output.sync();const after=await input.stat();
            if(before.size!==after.size || before.mtimeMs!==after.mtimeMs || count!==before.size)throw new Error('Source changed during transfer; no file published.');
            if(signal?.aborted)throw new Error('Transfer cancelled.');
            await fs.promises.link(temporary,destination);
            return {bytes:count,sha256:hash.digest('hex')};
        }finally{await output.close();}
    }finally{await input.close();await fs.promises.unlink(temporary).catch(()=>{});}
}
export function exchangeDirectory(base:string):string{
    if(!fs.existsSync(base))fs.mkdirSync(base,{recursive:true,mode:0o700});
    const stat=fs.lstatSync(base);if(!stat.isDirectory() || stat.isSymbolicLink() || stat.uid!==process.getuid!())throw new Error('Exchange directory must be owned by you and must not be a symlink.');
    for(const name of ['ToWindows','ToLinux']){
        const folder=path.join(base,name);if(!fs.existsSync(folder))fs.mkdirSync(folder,{mode:0o700});
        const stat=fs.lstatSync(folder);if(!stat.isDirectory() || stat.isSymbolicLink())throw new Error('Invalid exchange subdirectory.');
    }
    return base;
}
