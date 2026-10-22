import { test } from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import type { ChildProcess } from 'node:child_process';
import { HeliosViewer,viewerStatistics,viewerWire,viewerContract } from '../src/shared/helios-viewer';

class FakeViewer extends EventEmitter {
    stdin = new PassThrough(); stdout = new PassThrough(); stderr = new PassThrough(); kills = 0;
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

test('automatic startup retries until QEMU is ready and recovers a crashed viewer', async t => {
    t.mock.timers.enable({apis: ['setTimeout']});
    const f = fixture();
    f.viewer.setAutomatic(true, message => f.failures.push(message));
    f.viewer.setAutomatic(true, message => f.failures.push(message));
    assert.equal(f.children.length, 1);
    f.children[0].emit('close', 1);
    await Promise.resolve();
    t.mock.timers.tick(1000);
    assert.equal(f.children.length, 2);
    f.children[1].ready(); await Promise.resolve();
    assert.equal(f.states.at(-1), 'ready');
    f.children[1].emit('close', 1);
    t.mock.timers.tick(1000);
    assert.equal(f.children.length, 3);
    f.children[2].ready(); await Promise.resolve();
    f.viewer.close();
});
test('VM stop cancels a pending automatic reconnect and stale events cannot reopen it', async t => {
    t.mock.timers.enable({apis: ['setTimeout']});
    const f = fixture(); f.viewer.setAutomatic(true, () => {});
    f.children[0].emit('close', 1); await Promise.resolve();
    f.viewer.setAutomatic(false, () => {});
    t.mock.timers.tick(30000);
    assert.equal(f.children.length, 1);assert.equal(f.states.at(-1), 'closed');
    f.children[0].emit('error', new Error('late failure'));
    t.mock.timers.tick(30000);assert.equal(f.children.length, 1);
    f.viewer.setAutomatic(true, () => {});
    assert.equal(f.children.length, 2);
    f.children[1].ready(); await Promise.resolve(); f.viewer.close();
});
test('an intentional window close remains closed until a new VM lifecycle', async t => {
    t.mock.timers.enable({apis: ['setTimeout']});
    const f = fixture(); f.viewer.setAutomatic(true, () => {});
    f.children[0].ready(); await Promise.resolve(); f.children[0].emit('close', 0);
    f.viewer.setAutomatic(true, () => {});t.mock.timers.tick(30000);
    assert.equal(f.children.length, 1);
    f.viewer.setAutomatic(false, () => {});f.viewer.setAutomatic(true, () => {});
    assert.equal(f.children.length, 2);f.children[1].ready();await Promise.resolve();f.viewer.close();
});

test('guest adapter health is delivered on stdin and stale data restores automatic selection', async () => {
    const f=fixture();
    f.viewer.updateAdapters({helios:{state:'running'},basic:{state:'disabled'},sampleAgeMs:0});
    const opening=f.open();
    assert.equal(f.children[0].stdin.read()?.toString(),'adapters 1 2\n');
    f.children[0].ready();await opening;
    f.viewer.updateAdapters({helios:{state:'failed'},basic:{state:'running'},sampleAgeMs:0});
    assert.equal(f.children[0].stdin.read()?.toString(),'adapters 2 1\n');
    f.viewer.updateAdapters({helios:{state:'failed'},basic:{state:'disabled'},sampleAgeMs:30000});
    assert.equal(f.children[0].stdin.read()?.toString(),'adapters 0 0\n');
    f.viewer.updateAdapters(null);
    assert.equal(f.children[0].stdin.read()?.toString(),'adapters 0 0\n');
    f.viewer.close();
    const next=f.open();assert.equal(f.children[1].stdin.read()?.toString(),'adapters 0 0\n');
    f.children[1].ready();await next;f.viewer.close();
});

test('same-version legacy guest APIs update display recovery and automatic runtimes', async () => {
    const {guestNeedsUpdate,GUEST_GRAPHICS_PROTOCOL,GUEST_RUNTIME_PROTOCOL}=await import('../src/shared/guest-protocol');
    assert.equal(guestNeedsUpdate({version:'0.8.7'},'0.8.7'),true);
    assert.equal(guestNeedsUpdate({version:'0.8.7',graphics_protocol:'old'},'0.8.7'),true);
    assert.equal(guestNeedsUpdate({version:'0.8.7',graphics_protocol:'helios-watchdog-v2'},'0.8.7'),true);
    assert.equal(guestNeedsUpdate({version:'0.8.7',graphics_protocol:'helios-watchdog-v3'},'0.8.7'),true);
    assert.equal(guestNeedsUpdate({version:'0.8.7',graphics_protocol:'helios-watchdog-v5',runtime_protocol:GUEST_RUNTIME_PROTOCOL},'0.8.7'),true);
    assert.equal(guestNeedsUpdate({version:'0.8.7',graphics_protocol:GUEST_GRAPHICS_PROTOCOL},'0.8.7'),true);
    assert.equal(guestNeedsUpdate({version:'0.8.7',graphics_protocol:GUEST_GRAPHICS_PROTOCOL,runtime_protocol:'old'},'0.8.7'),true);
    assert.equal(guestNeedsUpdate({version:'0.8.7',graphics_protocol:GUEST_GRAPHICS_PROTOCOL,runtime_protocol:GUEST_RUNTIME_PROTOCOL},'0.8.7'),false);
    assert.equal(guestNeedsUpdate({version:'0.8.6',graphics_protocol:GUEST_GRAPHICS_PROTOCOL},'0.8.7'),true);
});

test('a loaded driver without a Windows desktop cannot win over a working VGA output', async () => {
    const f=fixture(); const opening=f.open(); f.children[0].ready();await opening;
    f.children[0].stdin.read();
    f.viewer.updateAdapters({helios:{state:'running',desktopState:'inactive'},basic:{state:'running',desktopState:'active'},sampleAgeMs:0});
    assert.equal(f.children[0].stdin.read()?.toString(),'adapters 3 1\n');
    f.viewer.updateAdapters({helios:{state:'running',desktopState:'active'},basic:{state:'running',desktopState:'active'},sampleAgeMs:0});
    assert.equal(f.children[0].stdin.read()?.toString(),'adapters 1 1\n');
    f.viewer.updateAdapters({helios:{state:'running',desktopState:'unknown'},basic:{state:'running',desktopState:'unknown'},sampleAgeMs:0});
    assert.equal(f.children[0].stdin.read()?.toString(),'adapters 0 0\n');
    f.viewer.updateAdapters({helios:{state:'failed',desktopState:'active'},basic:{state:'running',desktopState:'active'},sampleAgeMs:0});
    assert.equal(f.children[0].stdin.read()?.toString(),'adapters 2 1\n');
    f.viewer.close();
});

test('adapter recovery reports its cause while preserving the same viewer window', async () => {
    const child=new FakeViewer(), updates:{state:string;message:string}[]=[], hints:boolean[]=[];
    const viewer=new HeliosViewer(()=>child as unknown as ChildProcess,(state,message)=>updates.push({state,message}),1000,1000,unavailable=>hints.push(unavailable));
    const opening=viewer.open(()=>assert.fail('Adapter recovery must not fail the session'));
    child.ready();await opening;
    child.stdout.write(JSON.stringify({event:'display-recovery',console:1,accelerated:true,reason:'EGL DMA-BUF import failed'})+'\n');
    assert.match(updates.at(-1)!.message,/EGL DMA-BUF import failed/);
    assert.equal(updates.at(-1)!.state,'ready');assert.equal(child.kills,0);
    child.stdout.write('{"event":"display-recovered","console":1,"accelerated":true}\n');
    assert.match(updates.at(-1)!.message,/connected/);
    assert.deepEqual(hints,[true,false]);
    child.stdout.write(JSON.stringify({event:'display-recovery',console:0,accelerated:false,reason:'VGA frame failed'})+'\n');
    assert.deepEqual(hints,[true,false]);
    viewer.close();
});

test('viewer statistics retain numeric counters and discard arbitrary text',()=>{
    const row=viewerStatistics('{"event":"statistics","pid":1,"console":2,"monotonicUs":3,"width":1920,"path":"PRIVATE","softwareFrames":-1}');
    assert.deepEqual(row,{pid:1,console:2,monotonicUs:3,width:1920});
    assert.equal(viewerStatistics('{"event":"statistics","pid":true,"console":2,"monotonicUs":3}'),undefined);
});

test('wire evidence accepts only fixed D-Bus tokens',()=>{
    const line='frame-wire peer='+('a'.repeat(32))+' serial=1 stage=ack method=Update monotonic_us=5';
    assert.equal(viewerWire(line),line);assert.equal(viewerWire(line+' PRIVATE'),undefined);
});

test('DMA-BUF layout evidence survives stderr framing without losing 64-bit precision or accepting free text',async()=>{
 const line='{"event":"dmabuf-contract","console":0,"inode":18446744073709551615,"bytes":4096000,"width":1280,"height":800,"stride":5120,"offset":0,"fourcc":875713089,"modifier":72057594037927935}';
 assert.equal(viewerContract(line),line);assert.equal(viewerContract(line.replace('"width":1280','"width":"PRIVATE"')),undefined);
 const child=new FakeViewer(),evidence:string[]=[];
 const viewer=new HeliosViewer(()=>child as unknown as ChildProcess,()=>{},1000,1000,undefined,undefined,line=>evidence.push(line));
 const opening=viewer.open(()=>{});child.ready();await opening;child.stderr.write(line.slice(0,50));child.stderr.write(line.slice(50)+'\n');
 assert.deepEqual(evidence,[line]);viewer.close();
});
