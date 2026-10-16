/** Container/control validation only. This does not test a real GPU or Windows. */
import { spawnSync } from 'node:child_process';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import { HELIOS_IMAGE, HELIOS_LABEL, HELIOS_REVISION, HELIOS_RUNTIME_LABEL, HELIOS_RUNTIME_VERSION } from '../../src/shared/helios.ts';
import { HELIOS_DISPLAY_CAPABILITY, HELIOS_DISPLAY_VERSION } from '../../src/shared/helios-display.ts';
function docker(args: string[], input?: string, timeout = 30000): string {
    const result = spawnSync('docker', args, { input, encoding: 'utf8', timeout, maxBuffer: 8 * 1024 * 1024 });
    if (result.error) throw result.error;
    assert.equal(result.status, 0, result.stderr);
    return result.stdout;
}
assert.equal(docker(['image', 'inspect', '--format', `{{ index .Config.Labels "${HELIOS_LABEL}" }}`, HELIOS_IMAGE]).trim(), HELIOS_REVISION);
assert.equal(docker(['image', 'inspect', '--format', `{{ index .Config.Labels "${HELIOS_DISPLAY_CAPABILITY}" }}`, HELIOS_IMAGE]).trim(), HELIOS_DISPLAY_VERSION);
assert.equal(docker(['image', 'inspect', '--format', `{{ index .Config.Labels "${HELIOS_RUNTIME_LABEL}" }}`, HELIOS_IMAGE]).trim(), HELIOS_RUNTIME_VERSION);
console.log(docker(['run', '--rm', '--network', 'none', '--entrypoint', '/opt/helios/check-runtime.sh', HELIOS_IMAGE]).trim());
const startup = fs.readFileSync(new URL('../../tests/helios-startup.sh', import.meta.url), 'utf8');
// A null character-device fixture exercises argument generation, never GPU rendering.
const display = docker(['run', '--rm', '-i', '--network', 'none', '--device', '/dev/null:/dev/dri/renderD128',
    '-e', 'RENDERNODE=/dev/dri/renderD128', '-e', 'RAM_SIZE=128M', '-e', 'VNC_PORT=5900', '-e', 'WSS_PORT=5700',
    '--entrypoint', 'bash', HELIOS_IMAGE, '-s'], startup);
assert.ok(display.includes('venus=on,blob=on'));
assert.ok(display.includes('-device VGA,id=helios-bootstrap -device virtio-gpu-gl-pci'));
assert.ok(display.includes('memory-backend-memfd,id=helios-ram,size=128M,share=on'));
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'winboat-display-args-'));
const socket = net.createServer();
await new Promise<void>((resolve, reject) => { socket.once('error', reject); socket.listen(path.join(temporary, 'bus'), resolve); });
try {
    const local = docker(['run', '--rm', '-i', '--network', 'none', '--device', '/dev/null:/dev/dri/renderD128',
        '-v', `${temporary}:/run/helios-display:ro`, '-e', 'HELIOS_DISPLAY=dbus',
        '-e', 'RAM_SIZE=128M', '-e', 'VNC_PORT=5900', '-e', 'WSS_PORT=5700',
        '--entrypoint', 'bash', HELIOS_IMAGE, '-s'], startup);
    assert.ok(local.includes('dbus,addr=unix:path=/run/helios-display/bus,gl=on,rendernode=/dev/dri/renderD128'));
    assert.ok(local.includes('-vnc :0,websocket=5700'));
    assert.ok(local.includes('venus=on,blob=on'));
    assert.ok(local.includes('-device VGA,id=helios-bootstrap -device virtio-gpu-gl-pci'));
} finally {
    await new Promise<void>(resolve => socket.close(() => resolve()));
    fs.rmSync(temporary, { recursive: true });
}
const libraries = docker(['run', '--rm', '-e', 'LD_LIBRARY_PATH=/opt/helios/renderer/lib', '--entrypoint', 'sh', HELIOS_IMAGE, '-c',
    'ldd /opt/helios/qemu/bin/qemu-system-x86_64; ldd /opt/helios/renderer/lib/libvirglrenderer.so.1; ldd /opt/helios/renderer/libexec/virgl_render_server']);
assert.ok(!libraries.includes('not found'), libraries);
// Replace QEMU only inside this disposable container with a fork/exec probe.
// The actual installed wrapper must supply both the loader and server paths.
const probe = fs.mkdtempSync(path.join(os.tmpdir(), 'winboat-render-server-'));
try {
    fs.copyFileSync(new URL('../../tests/helios-render-server.c', import.meta.url), path.join(probe, 'probe.c'));
    docker(['run', '--rm', '--network', 'none', '-v', `${probe}:/test`, '--entrypoint', 'cc',
        'golang:1.25-bookworm', '-Wall', '-Wextra', '-Werror', '/test/probe.c', '-ldl', '-o', '/test/probe']);
    console.log(docker(['run', '--rm', '--network', 'none',
        '-v', `${probe}/probe:/opt/helios/qemu/bin/qemu-system-x86_64:ro`,
        '--entrypoint', 'qemu-system-x86_64', HELIOS_IMAGE]).trim());
    fs.copyFileSync(new URL('../../tests/helios-bootstrap-qemu.py', import.meta.url), path.join(probe, 'bootstrap.py'));
    console.log(docker(['run', '--rm', '--network', 'none', '-v', `${probe}:/test`,
        '--entrypoint', 'python3', HELIOS_IMAGE, '/test/bootstrap.py', '/test/bootstrap.ppm'], undefined, 60000).trim());
    fs.mkdirSync(new URL('../../dist/', import.meta.url), { recursive: true });
    fs.copyFileSync(path.join(probe, 'bootstrap.ppm'), new URL('../../dist/helios-bootstrap-smoke.ppm', import.meta.url));
} finally {
    fs.rmSync(probe, { recursive: true });
}
const commands = ['qmp_capabilities', 'query-status', 'query-memory-size-summary', 'quit']
    .map(execute => JSON.stringify({ execute })).join('\n') + '\n';
const output = docker(['run', '--rm', '-i', '--entrypoint', 'qemu-system-x86_64', HELIOS_IMAGE,
    '-machine', 'q35,accel=tcg,memory-backend=helios-test', '-object', 'memory-backend-memfd,id=helios-test,size=128M,share=on',
    '-m', '128M', '-nodefaults', '-display', 'none', '-S', '-qmp', 'stdio'], commands);
const messages = output.split('\n').filter(line => line.startsWith('{')).map(line => JSON.parse(line));
assert.ok(!messages.some(message => 'error' in message), output);
assert.ok(messages.some(message => message.return?.['base-memory'] === 128 * 1024 * 1024), output);
assert.ok(messages.some(message => message.event === 'SHUTDOWN' && message.data.reason === 'host-qmp-quit'), output);
console.log('Helios image identity, dockur network/config startup, HTTP preinstall completion, display arguments, runtime libraries and shared-memory QMP/TCG control smoke passed. GPU/Windows tests remain separate.');
