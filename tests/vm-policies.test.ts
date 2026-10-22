import {test} from 'node:test';import assert from 'node:assert/strict';
import {networkPolicy,resourcePolicy,changePolicy,applicationProfile} from '../src/shared/vm-policies';
const service={image:'fixture',environment:{CPU_CORES:'2',NETWORK:'Y',CUSTOM:'keep'},ports:['127.0.0.1:7148:7148']};
test('network and resource policies preserve ports and can restore their saved configuration',()=>{
 const next=networkPolicy(service,'bridge','eth0');assert.equal(next.network_mode,'eth0');assert.equal(next.environment.DHCP,'Y');assert.deepEqual(next.ports,service.ports);assert.deepEqual(changePolicy(next,'network',null),service);
 assert.equal(networkPolicy(service,'isolated').environment.NETWORK,'N');assert.throws(()=>networkPolicy(service,'bridge','eth0;cmd'));
 assert.throws(()=>resourcePolicy(service,'0',false));assert.equal(resourcePolicy(service,'2-3',true).cpuset,'2-3');assert.equal(service.environment.NETWORK,'Y');
});
test('application profiles accept fixed executable and argument arrays, never shell command strings',()=>{
 const p={schema:1,exe:'C:\\Games\\app.exe',resolution:'1920x1080',transport:'auto',api:'native',args:['-windowed']};assert.equal(applicationProfile(p).exe,p.exe);
 for(const value of [{...p,args:'cmd /c'},{...p,exe:'cmd.exe'},{...p,resolution:'9999x9999'},{...p,args:['a\nb']}])assert.throws(()=>applicationProfile(value));
});

test('restoring a resource or backup policy preserves newer network and share changes',()=>{
 const a=resourcePolicy(service,'2-3',false),b=networkPolicy(a,'bridge','lan');const c=changePolicy(b,'resources',null);assert.equal(c.environment.DHCP,'Y');assert.equal(c.environment.HELIOS_HUGEPAGES,undefined);
 const first={...service,volumes:['disk:/storage']};const mounted=changePolicy(first,'live-backup',{volumes:[...first.volumes,'private:/backup']});mounted.volumes.push('later:/shares/later');
 assert.deepEqual(changePolicy(mounted,'live-backup',null).volumes,['disk:/storage','later:/shares/later']);
});
