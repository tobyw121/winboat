import {test} from 'node:test';import assert from 'node:assert/strict';
import fs from 'node:fs/promises';import os from 'node:os';import path from 'node:path';import vm from 'node:vm';import {build} from 'vite';import {createRequire} from 'node:module';
test('paired grants never leave the exact loopback origin and reject redirects',async()=>{
 const root=await fs.mkdtemp(path.join(os.tmpdir(),'winboat-session-'));
 try{
  await fs.writeFile(path.join(root,'entry.ts'),`import {guestFetch,pairGuestSession,revokeGuestSession,guestSessionEnvironment} from ${JSON.stringify(path.resolve('src/renderer/lib/guest-session.ts'))}; window.api={guestFetch,pairGuestSession,revokeGuestSession,guestSessionEnvironment};`);
  const result=await build({configFile:false,root,logLevel:'silent',build:{write:false,modulePreload:{polyfill:false},rollupOptions:{input:path.join(root,'entry.ts')}}});assert(!Array.isArray(result)&&'output' in result);const chunk=result.output.find(x=>x.type==='chunk');assert(chunk&&'code' in chunk);
  const rows:Array<{url:string;options:any}>=[],window:any={};const real=createRequire(import.meta.url)('node-fetch');
  const fetch=Object.assign(async(url:string,options:any={})=>{rows.push({url,options});return {ok:true,json:async()=>({token:'a'.repeat(64),expiresAtUtc:new Date(Date.now()+60000).toISOString(),scopes:['read']})};},{Headers:real.Headers});
  vm.runInNewContext(chunk.code,{window,URL,Date,require:()=>fetch});
  await window.api.pairGuestSession('http://127.0.0.1:7148','123456',['read']);
  await window.api.guestFetch('http://127.0.0.1:7148/graphics/adapters');assert.equal(rows.at(-1)!.options.headers.get('X-WinBoat-Session'),'a'.repeat(64));assert.equal(rows.at(-1)!.options.redirect,'error');
  await window.api.guestFetch('http://127.0.0.1:7149/graphics/adapters');assert.equal(rows.at(-1)!.options.headers,undefined);
  await window.api.guestFetch('https://example.org');assert.equal(rows.at(-1)!.options.headers,undefined);
  assert.equal(window.api.guestSessionEnvironment().WINBOAT_SESSION_ORIGIN,'http://127.0.0.1:7148');
  await window.api.revokeGuestSession();assert.equal(Object.keys(window.api.guestSessionEnvironment()).length,0);
 }finally{await fs.rm(root,{recursive:true,force:true});}
});
