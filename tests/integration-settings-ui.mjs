// Render the real templates in Chromium with inert host/guest actions. No VM,
// Docker, filesystem operations or clipboard connections are started by this UI fixture.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import {spawn,spawnSync} from 'node:child_process';
import {parse} from '@vue/compiler-sfc';
import {compile} from '@vue/compiler-dom';
import {integrationSections} from '../src/shared/integration-navigation.ts';
const root=path.resolve(import.meta.dirname,'..'),temporary=fs.mkdtempSync(path.join(os.tmpdir(),'winboat-ui-'));
const names=['VMIntegration','VMWorkbench','VMProjectTools','IntegrationDisplay'];
const templates=Object.fromEntries(names.map(name=>{
 const {descriptor}=parse(fs.readFileSync(path.join(root,'src/renderer/components',name+'.vue'),'utf8'));
 return [name,{code:compile(descriptor.template.content,{mode:'function',isCustomElement:tag=>tag.startsWith('x-')}).code,
  actions:[...descriptor.scriptSetup.content.matchAll(/(?:async\s+)?function\s+(\w+)\(/g)].map(m=>m[1])}];
}));
const fixture=`<!doctype html><html><head><meta charset="utf-8"><meta name="xel-theme" content="/xel/themes/fluent-dark.css"><meta name="xel-accent-color" content="#A78AF9"><script type="module" src="/xel.js"></script><link rel="stylesheet" href="/style.css"><style>body{margin:0;background:#24232a;color:#eceaf2;font-family:system-ui}main{max-width:1100px;margin:auto;padding:24px}.grid{display:grid}.text-sm{font-size:.85rem}.w-full{width:100%}.h-24{height:96px}ul{list-style:none;padding:0}button{background:none;font:inherit}</style></head><body><main id="app"></main><script type="module">
import * as Vue from '/vue.js';
const templates=${JSON.stringify(templates)},sections=${JSON.stringify(integrationSections)};
const {ref,computed}=Vue,active=ref('overview'),blocked=ref(false),calls=[],state={};
const components={Icon:{render:()=>Vue.h('svg',{'aria-hidden':true,width:16,height:16,viewBox:'0 0 24 24'},[Vue.h('rect',{x:4,y:4,width:16,height:16,rx:4,fill:'none',stroke:'currentColor','stroke-width':1.5})])}};
for(const name of ['IntegrationDisplay','VMProjectTools','VMWorkbench','VMIntegration']){
 components[name]={props:['blocked','section'],components,setup(props){
  const data={busy:ref(false),displayBusy:ref(false),workbenchBusy:ref(false),toolsBusy:ref(false),message:ref(''),result:ref(''),
   toGuest:ref(true),toHost:ref(true),images:ref(false),label:ref('Before changes'),snapshots:ref([]),transfer:undefined,
   clipboardState:'Disconnected',clipboardMessage:'Connect to share text',status:'Refresh to check Windows availability.',
   exe:ref(''),appArguments:ref([]),profiles:ref([]),selected:ref(''),resolution:ref('1920x1080'),api:ref('native'),transport:ref('auto'),
   HELIOS_RESOLUTIONS:[{key:'1280x800'},{key:'1920x1080'}],automatic:ref(false),metrics:ref(),metricText:'No sample yet. Viewer rate is not application FPS.',
   cpuSet:ref(''),hugepages:ref(false),network:ref('nat'),networkName:ref(''),sharpen:ref(0),background:ref(false),trialMessage:'',scenario:ref('cold-boot'),backupId:ref(''),
   compatibility:[],records:ref([]),before:ref(''),after:ref(''),points:'',exportId:ref(''),keep:ref(5),availableScopes:['read','graphics','power','application','clipboard','maintenance'],scopes:ref(['read']),scopeLabels:{read:'Read status'},pairingCode:'',
   outputs:ref([]),resize:ref(false),audioStatus:'Not playing',active,integrationSections:sections,currentSection:computed(()=>sections.find(s=>s.id===active.value)),
   blocked:computed(()=>blocked.value||props.blocked),section:computed(()=>props.section)};
  if(name==='IntegrationDisplay')data.selected=ref(undefined);
  for(const action of templates[name].actions)data[action]=async()=>calls.push(action);
  for(const action of ['startClipboard','stopClipboard','transferClipboard','transferClipboardImage','testHelios','revokeGuestSession','startAudio','stopAudio'])data[action]=async()=>calls.push(action);
  data.run=async action=>{if(!data.blocked.value)await action();};data.emit=()=>{};
  state[name]=data;return data;
 },render:new Function('Vue',templates[name].code)(Vue)};
}
const slotValues=Object.fromEntries(['sharing','display','performance','diagnostics'].map(area=>[area,ref('retained')]));
const slotViews=Object.fromEntries(['sharing','display','performance','diagnostics'].map(area=>[area,()=>Vue.h('div',{class:'integration-card','data-slot':area},[Vue.h('h3',null,area+' extension'),Vue.h('label',null,['Extension preference',Vue.h('input',{'data-slot-input':area,value:slotValues[area].value,onInput:e=>slotValues[area].value=e.target.value})])])]));
const app=Vue.createApp({render:()=>Vue.h(components.VMIntegration,null,slotViews)});app.config.errorHandler=e=>{window.fixtureError=String(e)};app.mount('#app');
window.fixture={active,blocked,state,calls};window.fixtureReady=true;
</script></body></html>`;
const server=http.createServer((request,response)=>{
 const pathname=new URL(request.url,'http://localhost').pathname;
 let file;
 if(pathname==='/'){response.setHeader('Content-Type','text/html');response.end(fixture);return;}
 if(pathname==='/vue.js')file=path.join(root,'node_modules/vue/dist/vue.esm-browser.js');
 else if(pathname==='/xel.js')file=path.join(root,'src/renderer/public/xel/xel.js');
 else if(pathname==='/style.css')file=path.join(root,'src/renderer/styles/vm-integration.css');
 else if(pathname.startsWith('/xel/')){const base=path.join(root,'src/renderer/public/xel');const candidate=path.resolve(base,pathname.slice(5));if(candidate.startsWith(base+path.sep))file=candidate;}
 if(!file||!fs.existsSync(file)){response.writeHead(404).end();return;}
 response.setHeader('Content-Type',file.endsWith('.css')?'text/css':'text/javascript');fs.createReadStream(file).pipe(response);
});
let browser,socket;
try{
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 const chrome=process.env.CHROME_BIN||['chromium','google-chrome','google-chrome-stable'].find(c=>spawnSync('which',[c]).status===0);
 assert.ok(chrome,'Install Chromium or set CHROME_BIN to run UI verification');
 browser=spawn(chrome,['--headless','--no-sandbox','--disable-gpu','--remote-debugging-port=0','--user-data-dir='+temporary,'about:blank'],{stdio:['ignore','ignore','pipe']});
 const debuggerUrl=await new Promise((resolve,reject)=>{let output='';const timeout=setTimeout(()=>reject(new Error('Chromium startup timed out')),15000);browser.stderr.on('data',data=>{output+=data;const match=output.match(/DevTools listening on (ws:\/\/[^\s]+)/);if(match){clearTimeout(timeout);resolve(match[1]);}output=output.slice(-20000);});browser.on('error',reject);});
 const endpoint=new URL(debuggerUrl),targets=await(await fetch('http://'+endpoint.host+'/json/list')).json();
 socket=new WebSocket(targets.find(t=>t.type==='page').webSocketDebuggerUrl);await new Promise((resolve,reject)=>{socket.onopen=resolve;socket.onerror=reject;});
 let serial=0;const pending=new Map();socket.onmessage=event=>{const result=JSON.parse(event.data);if(pending.has(result.id)){const {resolve,reject,timer}=pending.get(result.id);clearTimeout(timer);pending.delete(result.id);result.error?reject(new Error(result.error.message)):resolve(result.result);}};
 const send=(method,params={})=>new Promise((resolve,reject)=>{const id=++serial;const timer=setTimeout(()=>{pending.delete(id);reject(new Error('Chromium command timed out: '+method));},10000);pending.set(id,{resolve,reject,timer});socket.send(JSON.stringify({id,method,params}));});
 const evaluate=async expression=>{const reply=await send('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true});assert.equal(reply.exceptionDetails,undefined,JSON.stringify(reply.exceptionDetails));return reply.result.value;};
 await send('Emulation.setDeviceMetricsOverride',{width:1200,height:1000,deviceScaleFactor:1,mobile:false});
 await send('Page.navigate',{url:'http://127.0.0.1:'+server.address().port});
 for(let i=0;i<100&&!await evaluate('window.fixtureReady===true');i++)await new Promise(r=>setTimeout(r,100));
 assert.equal(await evaluate('window.fixtureReady'),true);assert.equal(await evaluate('window.fixtureError'),undefined);
 const visible=label=>evaluate(`Array.from(document.querySelectorAll('h3,h4,x-button,summary')).some(e=>e.textContent.trim()===${JSON.stringify(label)}&&e.checkVisibility({contentVisibilityAuto:true}))`);
 const click=label=>evaluate(`(()=>{const e=Array.from(document.querySelectorAll('button,x-button,summary')).find(e=>e.textContent.trim()===${JSON.stringify(label)}&&e.checkVisibility());if(!e)throw Error('Control not visible: '+${JSON.stringify(label)});e.click()})()`);
 assert.equal(await evaluate("document.querySelectorAll('.integration-nav button').length"),7);
 assert.equal(await visible('Windows controls'),true);assert.equal(await visible('Shared clipboard'),false);
 await click('Clipboard & files');assert.equal(await visible('Shared clipboard'),true);assert.equal(await visible('Windows controls'),false);
 await evaluate("window.fixture.state.VMIntegration.toGuest.value=false");await click('Overview');await click('Clipboard & files');assert.equal(await evaluate('window.fixture.state.VMIntegration.toGuest.value'),false);
 await click('Applications');assert.equal(await visible('Add argument'),false);await click('Compatibility & launch arguments');await click('Add argument');
 await evaluate("(()=>{const e=document.querySelector('input[placeholder=\"e.g. -windowed\"]');e.value='a path with spaces';e.dispatchEvent(new Event('input',{bubbles:true}))})()");
 await click('Overview');await click('Applications');assert.deepEqual(await evaluate('JSON.parse(JSON.stringify(window.fixture.state.VMWorkbench.appArguments.value))'),['a path with spaces']);
 await click('Display & audio');assert.equal(await visible('Save display preferences'),true);assert.equal(await visible('Enable audio & restart'),false);
 await evaluate("(()=>{const e=document.querySelector('[data-slot-input=display]');window.savedSlotInput=e;e.value='preserved slot edit';e.dispatchEvent(new Event('input',{bubbles:true}))})()");await click('Overview');await click('Display & audio');
 assert.equal(await evaluate("document.querySelector('[data-slot-input=display]').value"),'preserved slot edit');
 assert.equal(await evaluate("window.savedSlotInput===document.querySelector('[data-slot-input=display]')"),true);
 assert.equal(await evaluate("document.querySelector('[data-slot=sharing]').checkVisibility()"),false);
 await click('Save display preferences');assert.ok((await evaluate('JSON.parse(JSON.stringify(window.fixture.calls))')).includes('saveViewerSettings'));
 const screenshot=async name=>{if(process.env.UI_SCREENSHOT_DIR){fs.mkdirSync(process.env.UI_SCREENSHOT_DIR,{recursive:true});const image=await send('Page.captureScreenshot',{captureBeyondViewport:true});fs.writeFileSync(path.join(process.env.UI_SCREENSHOT_DIR,name+'.png'),Buffer.from(image.data,'base64'));}};
 await screenshot('integration-desktop');
 for(const width of [1200,480]){await send('Emulation.setDeviceMetricsOverride',{width,height:1000,deviceScaleFactor:1,mobile:false});for(const section of integrationSections){await click(section.label);assert.equal(await evaluate('document.documentElement.scrollWidth<=window.innerWidth'),true,'Horizontal overflow: '+section.id+' at '+width);}}
 await screenshot('integration-mobile');
 await click('Diagnostics');assert.equal(await visible('Run graphics probes · confirm in Windows'),false);
 await evaluate('window.fixture.blocked.value=true');await click('Applications');assert.equal(await evaluate("Array.from(document.querySelectorAll('input')).find(e=>e.placeholder.endsWith('Game.exe')).matches(':disabled')"),true);
 assert.equal(await evaluate('window.fixtureError'),undefined);
 console.log('Integration UI: seven sections, advanced disclosure, retained form state, literal arguments, display actions, blocked controls and 1200/480px layouts passed.');
}finally{
 socket?.close();browser?.kill('SIGKILL');await new Promise(resolve=>server.close(resolve));
 await new Promise(resolve=>setTimeout(resolve,100));fs.rmSync(temporary,{recursive:true,force:true});
}
