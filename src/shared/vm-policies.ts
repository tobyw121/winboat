import {volumeTarget,type ComposeVolume} from './compose-volumes';
/** Explicit reversible settings. No policy mutates the input or selects a faster default. */
export type NetworkMode='nat'|'bridge'|'isolated';
type Service={environment:Record<string,string>;[key:string]:unknown};
const receipt='x-winboat-workbench';
export function changePolicy<T extends Service>(service:T,kind:string,changes:Record<string,unknown>|null):T{
 const next=JSON.parse(JSON.stringify(service)) as T,mutable=next as Service;
 const receipts=(mutable[receipt]??{}) as Record<string,Record<string,unknown>>;
 const mounts=()=>((mutable.volumes??[]) as ComposeVolume[]);
 const get=(key:string)=>key.startsWith('mount:')?mounts().find(v=>volumeTarget(v)===key.slice(6)):key.startsWith('env:')?next.environment[key.slice(4)]:mutable[key];
 const put=(key:string,value:unknown)=>{if(key.startsWith('mount:')){mutable.volumes=[...mounts().filter(v=>volumeTarget(v)!==key.slice(6)),...(value===null?[]:[value])];return;}const target=key.startsWith('env:')?next.environment:mutable,name=key.startsWith('env:')?key.slice(4):key;if(value===null)delete target[name];else (target as Record<string,unknown>)[name]=value;};
 if(changes===null){
  const saved=receipts[kind];if(!saved)throw new Error('No saved settings for this policy.');
  for(const [key,value] of Object.entries(saved))put(key,value);delete receipts[kind];
 }else{
  const flattened=Object.fromEntries(Object.entries(changes).flatMap(([key,value])=>{
   if(key==='environment')return Object.entries(value as Record<string,unknown>).map(([k,v])=>['env:'+k,v]);
   if(key==='volumes'){const next=value as ComposeVolume[],targets=new Set([...mounts(),...next].map(volumeTarget));return [...targets].flatMap(target=>{const old=mounts().find(v=>volumeTarget(v)===target),updated=next.find(v=>volumeTarget(v)===target);return JSON.stringify(old)===JSON.stringify(updated)?[]:[['mount:'+target,updated??null]];});}
   return [[key,value]];
  }));
  if(!receipts[kind])receipts[kind]={};
  for(const [key,value] of Object.entries(flattened)){if(!Object.hasOwn(receipts[kind],key))receipts[kind][key]=get(key)??null;put(key,value);}
 }
 if(Object.keys(receipts).length)mutable[receipt]=receipts;else delete mutable[receipt];return next;
}
export function networkPolicy<T extends Service>(service:T,mode:NetworkMode,interfaceName=''):T{
 if(!['nat','bridge','isolated'].includes(mode))throw new Error('Unknown network mode');
 if(mode==='bridge'&&!/^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}$/.test(interfaceName))throw new Error('Choose an existing Docker macvlan network.');
 if(service.networks)throw new Error('Custom Compose networks must be preserved; configure this VM manually.');
 const env={NETWORK:mode==='isolated'?'N':'Y',DHCP:mode==='bridge'?'Y':'N'};
 // Never use Docker host networking: keep the management ports on their existing bindings.
 return changePolicy(service,'network',{environment:env,network_mode:mode==='bridge'?interfaceName:null});
}
export function resourcePolicy<T extends Service>(service:T,cpus:string,hugepages:boolean):T{
 if(cpus&&!/^\d+(?:-\d+)?(?:,\d+(?:-\d+)?)*$/.test(cpus))throw new Error('Invalid CPU list');
 const used=new Set<number>();
 for(const row of cpus?cpus.split(','):[]){const values=row.split('-').map(Number),end=values[1]??values[0];if(end<values[0]||end>4095)throw new Error('CPU range outside bounds');for(let i=values[0];i<=end;i++)used.add(i);}
 if(cpus&&used.size<Number.parseInt(service.environment.CPU_CORES||'1'))throw new Error('CPU set must cover every allocated virtual CPU.');
 const env={HELIOS_HUGEPAGES:hugepages?'2M':'off',HELIOS_PREALLOC:hugepages?'1':'0'};
 return changePolicy(service,'resources',{environment:env,cpuset:cpus||null});
}
export const nativeRecipes=[
 {id:'d3d11-fl10-v1',label:'D3D11 feature level 10 · versioned diagnostic'},
 {id:'d3d11-backend-caps-v1',label:'D3D11 backend capability checks · versioned diagnostic'},
] as const;
export type ApplicationProfile={schema:1;exe:string;resolution:string;transport:'auto'|'copy'|'dmabuf';api:'native'|'compatibility';args:string[];recipe?:typeof nativeRecipes[number]['id']};
export function applicationProfile(value:unknown):ApplicationProfile{
 const p=value as ApplicationProfile;
 if(!p||p.schema!==1||!/^([A-Za-z]:\\|\\\\)[^\x00-\x1f]*\.exe$/i.test(p.exe)||p.exe.length>1024||!/^\d{3,4}x\d{3,4}$/.test(p.resolution)||!['auto','copy','dmabuf'].includes(p.transport)||!['native','compatibility'].includes(p.api)||!Array.isArray(p.args)||p.args.length>32||p.args.some(a=>typeof a!=='string'||a.length>2048||/[\x00\r\n]/.test(a)))throw new Error('Invalid application profile');
 const [w,h]=p.resolution.split('x').map(Number);if(w<640||h<480||w>7680||h>4320)throw new Error('Resolution outside supported profile bounds');
 if(p.recipe!==undefined&&(p.api!=='native'||!nativeRecipes.some(r=>r.id===p.recipe)))throw new Error('Invalid versioned application recipe');
 return {schema:1,exe:p.exe,resolution:p.resolution,transport:p.transport,api:p.api,args:[...p.args],...(p.recipe?{recipe:p.recipe}:{})};
}
