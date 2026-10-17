import {test} from 'node:test';
import assert from 'node:assert/strict';
import {skipWhileRunning} from '../src/renderer/utils/interval';

test('slow API polling never overlaps and resumes after completion', async () => {
    let calls=0;
    let release!: () => void;
    const tick=skipWhileRunning(async () => {calls++; await new Promise<void>(resolve => {release=resolve;});});
    const first=tick();
    await Promise.all([tick(),tick(),tick()]);
    assert.equal(calls,1);
    release(); await first;
    const next=tick(); assert.equal(calls,2); release(); await next;
});

test('a failed request releases the polling guard', async () => {
    let calls=0;
    const tick=skipWhileRunning(async () => {calls++; if(calls===1) throw new Error('offline');});
    await assert.rejects(tick(), /offline/);
    await tick(); assert.equal(calls,2);
});
