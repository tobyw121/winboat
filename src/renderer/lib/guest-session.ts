/** Session grants stay in memory and are sent only to the exact paired loopback origin. */
const fetch:typeof import('node-fetch').default=require('node-fetch');
const Headers:typeof import('node-fetch').Headers=require('node-fetch').Headers;
let session:{origin:string;token:string;expires:number}|undefined;
export const guestFetch:typeof fetch=Object.assign((input:Parameters<typeof fetch>[0],options:NonNullable<Parameters<typeof fetch>[1]>={})=>{
 if(session && Date.now()>=session.expires)session=undefined;
 if(!session)return fetch(input,options);
 const url=new URL(typeof input==='string'?input:('url' in input?input.url:input.href));
 if(session && url.origin===session.origin){const headers=new Headers(options.headers);headers.set('X-WinBoat-Session',session.token);return fetch(input,{...options,headers,redirect:'error'});}
 return fetch(input,options);
},fetch);
export async function pairGuestSession(origin:string,code:string,scopes:string[]){
 if(!/^http:\/\/127\.0\.0\.1:\d{1,5}$/.test(origin)||!/^\d{6}$/.test(code))throw new Error('Invalid local pairing endpoint/code');
 const response=await fetch(origin+'/integration/session',{method:'POST',headers:{'Content-Type':'application/json','X-WinBoat-Pair':'windows-consent'},body:JSON.stringify({code,scopes}),timeout:95000,redirect:'error'});
 if(!response.ok)throw new Error('Windows API pairing denied or unavailable ('+response.status+').');
 const value=await response.json();if(!/^[a-f0-9]{64}$/.test(value.token)||!Number.isFinite(Date.parse(value.expiresAtUtc)))throw new Error('Invalid session grant');
 session={origin,token:value.token,expires:Date.parse(value.expiresAtUtc)};return {expiresAtUtc:value.expiresAtUtc,scopes:value.scopes};
}
export async function revokeGuestSession(){if(!session)return;try{await guestFetch(session.origin+'/integration/session',{method:'DELETE',timeout:5000});}finally{session=undefined;}}
/** Fixed local diagnostic workers inherit only the current endpoint-scoped grant. */
export function guestSessionEnvironment():NodeJS.ProcessEnv{
 if(!session || Date.now()>=session.expires)return {};
 return {WINBOAT_SESSION_TOKEN:session.token,WINBOAT_SESSION_ORIGIN:session.origin};
}
