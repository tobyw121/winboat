import { test } from 'node:test';
import assert from 'node:assert/strict';
import { configureHelios } from '../src/shared/helios';
import { configureHeliosDisplay, heliosDisplayAddress, heliosDisplayBusConfig, heliosDisplayDirectory } from '../src/shared/helios-display';

const service = () => ({ image: 'standard', devices: [], environment: { HELIOS: '1', ARGUMENTS: '-qmp tcp:0.0.0.0:7149,server,wait=off' },
    volumes: ['disk:/storage', '/home/alice:/shared'], ports: ['3389:3389'] });

test('local display preserves disks, ports and existing QMP while mounting only its private bus read-only', () => {
    const original = service();
    const local = configureHeliosDisplay(original, true, '/run/user/1000/winboat-helios');
    assert.equal(local.environment.HELIOS_DISPLAY, 'dbus');
    assert.equal(local.environment.ARGUMENTS, original.environment.ARGUMENTS);
    assert.deepEqual(local.ports, original.ports);
    assert.deepEqual(local.volumes, [...original.volumes, '/run/user/1000/winboat-helios:/run/helios-display:ro']);
    assert.deepEqual(configureHeliosDisplay(local, true, '/run/user/1000/winboat-helios'), local);
    assert.deepEqual(configureHeliosDisplay(local, false), original);
    assert.equal(original.volumes.length, 2);
});

test('legacy adapter rollback removes the local display mount and mode without changing storage', () => {
    const local = configureHeliosDisplay(service(), true, '/tmp/winboat-helios-1000');
    const legacy = configureHelios(local, false);
    assert.ok(!('HELIOS_DISPLAY' in legacy.environment));
    assert.deepEqual(legacy.volumes, service().volumes);
});

test('local display rejects non-Helios VMs and ambiguous Docker mount/socket paths', () => {
    assert.throws(() => configureHeliosDisplay({ ...service(), environment: {} }, true, '/tmp/display'));
    for (const directory of ['/tmp/x:rw', 'relative', '/tmp/../other', '/tmp/a\nother']) {
        assert.throws(() => configureHeliosDisplay(service(), true, directory));
    }
    assert.throws(() => heliosDisplayDirectory(-1));
    assert.throws(() => heliosDisplayDirectory(1000, '/run/' + 'x'.repeat(100)));
    assert.equal(heliosDisplayDirectory(1000), '/tmp/winboat-helios-1000');
    assert.equal(heliosDisplayDirectory(1000, '/run/user/1000'), '/run/user/1000/winboat-helios');
});

test('the display bus uses EXTERNAL auth and restricts its well-known QEMU name to root', () => {
    const config = heliosDisplayBusConfig('/run/user/1000/winboat-helios', 1000);
    assert.ok(config.includes('<auth>EXTERNAL</auth>'));
    assert.ok(config.includes('<deny own="*"/>'));
    assert.ok(config.includes('<policy user="root"><allow own="org.qemu"/>'));
    assert.ok(!config.includes('ANONYMOUS'));
    assert.equal(heliosDisplayAddress('/tmp/test display'), 'unix:path=%2Ftmp%2Ftest%20display%2Fbus');
});
