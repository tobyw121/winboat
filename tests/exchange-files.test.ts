import {test} from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs';import os from 'node:os';import path from 'node:path';
import {createRequire} from 'node:module';
(globalThis as any).require=createRequire(import.meta.url);
const {copyExchangeFile,exchangeDirectory}=await import('../src/shared/exchange-files');
test('exchange publishes complete files, records progress and refuses overwrite or symlink sources',async()=>{
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'exchange-'));try{
 const folder=exchangeDirectory(path.join(root,'share'));const input=path.join(root,'source');fs.writeFileSync(input,Buffer.alloc(200000,7));
 const target=path.join(folder,'ToWindows','data');let progress=0;
 const result=await copyExchangeFile(input,target,n=>progress=n);assert.equal(result.bytes,200000);assert.equal(progress,200000);assert.deepEqual(fs.readFileSync(input),fs.readFileSync(target));
 await assert.rejects(copyExchangeFile(input,target,()=>{}),/exists/);
 fs.symlinkSync(input,path.join(root,'link'));await assert.rejects(copyExchangeFile(path.join(root,'link'),path.join(root,'bad'),()=>{}));
 assert.deepEqual(fs.readdirSync(path.dirname(target)),['data']);
 }finally{fs.rmSync(root,{recursive:true,force:true});}
});
test('cancelled transfer never publishes a destination',async()=>{
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'exchange-'));try{
 const input=path.join(root,'source');fs.writeFileSync(input,Buffer.alloc(300000));const cancel=new AbortController();
 await assert.rejects(copyExchangeFile(input,path.join(root,'out'),()=>cancel.abort(),cancel.signal));assert.equal(fs.existsSync(path.join(root,'out')),false);
 }finally{fs.rmSync(root,{recursive:true,force:true});}
});
