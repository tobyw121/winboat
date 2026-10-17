import { test } from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import type { ChildProcess } from 'node:child_process';
import { HeliosViewer } from '../src/shared/helios-viewer';

class FakeViewer extends EventEmitter {
    stdout = new PassThrough(); stderr = new PassThrough(); kills = 0;
    kill() { this.kills++; queueMicrotask(() => this.emit('close', 0)); return true; }
    ready() { this.stdout.write('{"event":"ready","transport":"dbus"}\n'); }
}
function fixture(timeout = 1000) {
    const children: FakeViewer[] = [], states: string[] = [], failures: string[] = [];
    const viewer = new HeliosViewer(() => {
        const child = new FakeViewer(); children.push(child); return child as unknown as ChildProcess;
    }, state => states.push(state), timeout);
    return { viewer, children, states, failures, open: () => viewer.open(message => failures.push(message)) };
}
test('concurrent opens share startup and wait for a complete ready message', async () => {
    const f = fixture(); const first = f.open(); assert.equal(f.open(), first);
    assert.equal(f.children.length, 1);
    f.children[0].stdout.write('{"event":"ready",');
    assert.deepEqual(f.states, ['opening']);
    f.children[0].stdout.write('"transport":"dbus"}\n'); await first;
    assert.equal(f.children.length, 1); assert.equal(f.states.at(-1), 'ready');
    f.viewer.close(); assert.deepEqual(f.failures, []);
});
test('runtime failure is reported once and the viewer can be reopened', async () => {
    const f = fixture(); const open = f.open(); f.children[0].ready(); await open;
    f.children[0].stderr.write('GPU import failed'); f.children[0].emit('close', 1);
    f.children[0].emit('error', new Error('already exited'));
    assert.deepEqual(f.failures, ['GPU import failed']);
    const next = f.open(); f.children[1].ready(); await next;
    assert.equal(f.states.at(-1), 'ready'); f.viewer.close();
});
test('normal user close does not open the browser or report a failure', async () => {
    const f = fixture(); const open = f.open(); f.children[0].ready(); await open;
    f.children[0].emit('close', 0);
    assert.equal(f.states.at(-1), 'closed'); assert.deepEqual(f.failures, []);
});
test('closing during startup cancels without affecting a replacement process', async () => {
    const f = fixture(); const open = f.open(); const cancelled = assert.rejects(open, { name: 'AbortError' });
    f.viewer.close(); const next = f.open(); f.children[1].ready(); await next; await cancelled;
    assert.equal(f.states.at(-1), 'ready'); assert.deepEqual(f.failures, []); f.viewer.close();
});
test('a stalled startup times out, terminates and can be retried', async () => {
    const f = fixture(15); await assert.rejects(f.open(), /did not become ready/);
    assert.equal(f.children[0].kills, 1); const retry = f.open(); f.children[1].ready(); await retry; f.viewer.close();
});
test('a process exiting before its handshake rejects startup', async () => {
    const f = fixture(); const rejected = assert.rejects(f.open(), /disconnected/);
    f.children[0].emit('close', 0); await rejected; assert.equal(f.states.at(-1), 'failed');
});
