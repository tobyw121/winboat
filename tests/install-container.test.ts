import { test } from 'node:test';
import assert from 'node:assert/strict';
import { containerInstallFailure } from '../src/shared/install-container.ts';

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
