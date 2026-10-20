import {test} from 'node:test';
import assert from 'node:assert/strict';
import {graphicsCapture} from '../src/shared/graphics-capture';
test('repeated capture clicks share one collector and failure permits retry',async()=>{
    let finish!:(s:string)=>void;let calls=0;
    const capture=graphicsCapture(()=>{calls++;return new Promise(r=>{finish=r;});});
    const first=capture();assert.equal(first,capture());assert.equal(calls,1);
    finish('Recording: /tmp/graphics.json\n{}');assert.equal(await first,'/tmp/graphics.json');
    const bad=capture();finish('not a report');await assert.rejects(bad,/did not produce/);
    const retry=capture();finish('Recording: /tmp/retry.json\n{}');assert.equal(await retry,'/tmp/retry.json');
    assert.equal(calls,3);
});
