import {test} from 'node:test';import assert from 'node:assert/strict';
import {performanceProfile} from '../src/shared/helios-performance.ts';
test('performance experiments preserve storage/GPU/VRAM settings and restore the exact managed baseline',()=>{
 const original={environment:{RAM_SIZE:'20G',HELIOS:'1',HELIOS_SHADER_CACHE:'1',HELIOS_VRAM_CAP_BYTES:'1000'},volumes:['existing:/storage'],ports:['8006:8006']};
 const candidate=performanceProfile(original,'io-thread-low-cpu');assert.equal(candidate.environment.HELIOS_IO_THREAD,'1');assert.equal(candidate.environment.HELIOS_VRAM_CAP_BYTES,'1000');
 assert.deepEqual(candidate.volumes,original.volumes);assert.deepEqual(candidate.ports,original.ports);
 const another=performanceProfile(candidate,'readback-damage');assert.deepEqual(performanceProfile(another,'restore'),original);
 assert.equal(original.environment.HELIOS_SHADER_CACHE,'1');
});
test('unknown profiles and incomplete restoration snapshots are refused',()=>{
 assert.throws(()=>performanceProfile({environment:{}},'wrong' as any));
 assert.throws(()=>performanceProfile({environment:{},'x-winboat-performance':{before:{PASSWORD:'private'}}},'restore'));
});
