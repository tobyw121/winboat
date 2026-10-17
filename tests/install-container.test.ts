import { test } from 'node:test';
import assert from 'node:assert/strict';
import { containerInstallFailure, containerInstallLogFailure } from '../src/shared/install-container.ts';

test('AME preparation diagnostics survive a reset HTTP connection without treating normal setup as a failure', () => {
    assert.equal(containerInstallLogFailure('Adding OEM folder to image...\nAME OOBE and offline registry preparation injected.'), undefined);
    assert.match(containerInstallLogFailure('AME ISO injection failed: Windows Pro index 6 has no Windows/System32/oobe/msoobe.exe. Select apply after installation.\nTraceback...')!, /index 6.*apply after installation/);
    assert.match(containerInstallLogFailure("Couldn't open libGL.so.1 or libOpenGL.so.0")!, /OpenGL runtime/);
    assert.match(containerInstallLogFailure('qemu-system-x86_64: -vnc :0,websocket=5700: Display vnc is incompatible with the GL context')!, /incompatible native GL and VNC.*without deleting/);
});

test('a healthy VM and Windows reboots do not fail installation monitoring', () => {
    assert.equal(containerInstallFailure({ State: { Status: 'running', Running: true }, RestartCount: 0 }), undefined);
    assert.equal(containerInstallFailure({ State: { Status: 'running', Running: true }, RestartCount: 3 }, 3), undefined);
});

test('QEMU container crashes, restart loops, OOM and stopped containers end the installation wait', () => {
    assert.match(containerInstallFailure({ State: { Status: 'restarting', Restarting: true }, RestartCount: 1 })!, /crashed/);
    assert.match(containerInstallFailure({ State: { Status: 'running', Running: true }, RestartCount: 1 })!, /crashed/);
    assert.match(containerInstallFailure({ State: { Status: 'exited', Running: false, ExitCode: 15 } })!, /exit 15/);
    assert.match(containerInstallFailure({ State: { Status: 'exited', OOMKilled: true } })!, /out of memory/);
    assert.throws(() => containerInstallFailure({}), /no VM container state/);
});
