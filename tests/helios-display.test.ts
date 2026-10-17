import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ref, isProxy } from 'vue';
import { configureHelios } from '../src/shared/helios';
import { configureHeliosDisplay, preferHeliosDisplay, resolveHeliosDisplay, heliosDisplayAddress, heliosDisplayBusConfig, heliosDisplayDirectory } from '../src/shared/helios-display';

const service = () => ({ image: 'standard', devices: [], environment: { HELIOS: '1', ARGUMENTS: '-qmp tcp:0.0.0.0:7149,server,wait=off' },
    volumes: ['disk:/storage', '/home/alice:/shared'], ports: ['3389:3389'] });

test('a saved native display preference survives unavailable runtime and activates on a later start', async () => {
    const original = {...service(), restart:'unless-stopped'};
    const savedPreference = true;
    const first = await resolveHeliosDisplay(original, savedPreference, () => '/tmp/display', async () => {throw new Error('No desktop session');});
    assert.equal(first.service.environment.HELIOS_DISPLAY, undefined);
    assert.equal(first.service.restart, 'no');
    assert.equal(first.unavailableReason, 'No desktop session');
    const next = await resolveHeliosDisplay(first.service, savedPreference, () => '/tmp/display', async () => {});
    assert.equal(next.service.environment.HELIOS_DISPLAY, 'dbus');
    const disabled = await resolveHeliosDisplay(next.service, false, () => {throw new Error('must not probe');}, async () => {});
    assert.equal(disabled.service.environment.HELIOS_DISPLAY, undefined);
    assert.deepEqual(disabled.service.volumes, original.volumes);
    assert.deepEqual(disabled.service.ports, original.ports);
});

test('new Helios VMs prefer native display only after its session and runtime are prepared', async () => {
    const original = { ...service(), restart: 'unless-stopped' };
    let checks = 0;
    const selected = await preferHeliosDisplay(original, undefined, () => '/run/user/1000/winboat-helios', async candidate => {
        checks++; assert.equal(candidate.restart, 'no'); assert.equal(candidate.environment.HELIOS_DISPLAY, 'dbus');
    });
    assert.equal(checks, 1); assert.equal(selected.restart, 'no');
    assert.equal(original.restart, 'unless-stopped'); assert.equal(original.environment.HELIOS_DISPLAY, undefined);
    await assert.rejects(preferHeliosDisplay(original, true, () => '/tmp/display', async () => { throw new Error('GTK unavailable'); }), /GTK unavailable/);
    assert.equal(original.restart, 'unless-stopped'); assert.deepEqual(original.volumes, service().volumes);
});
test('browser opt-out and ordinary Windows installs never depend on the local runtime', async () => {
    const unused = () => { throw new Error('Local display must not be probed'); };
    const original = { ...service(), restart: 'unless-stopped' };
    assert.equal(await preferHeliosDisplay(original, false, unused, unused), original);
    const standard = { ...original, environment: {} };
    assert.equal(await preferHeliosDisplay(standard, true, unused, unused), standard);
});

test('local display settings accept a reactive compose service without mutating it', () => {
    const original = ref(service());
    const before = JSON.stringify(original.value);
    const local = configureHeliosDisplay(original.value, true, '/tmp/winboat-helios-1000');
    assert.equal(local.environment.HELIOS_DISPLAY, 'dbus');
    assert.equal(isProxy(local.ports), false);
    local.ports.push('8006:8006');
    assert.equal(JSON.stringify(original.value), before);
    const disabled = configureHeliosDisplay(ref(local).value, false);
    assert.deepEqual(disabled.volumes, original.value.volumes);
    assert.equal(disabled.environment.HELIOS_DISPLAY, undefined);
    assert.equal(local.environment.HELIOS_DISPLAY, 'dbus');
});

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
