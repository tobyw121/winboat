import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { parse } from 'yaml';
import { HELIOS_REVISION, HELIOS_GUEST_REVISION, HELIOS_IMAGE, configureHelios, validateHeliosProgress } from '../src/shared/helios';
import { verifyBundle } from '../scripts/helios/bundle';

const service = () => ({
    image: 'ghcr.io/dockur/windows:5.07',
    environment: { ARGUMENTS: '-qmp tcp:0.0.0.0:7149,server,wait=off', VIRGL: '1', PASSWORD: 'local-test-value' },
    devices: ['/dev/kvm', '/dev/dri:/dev/dri', '/dev/snd:/dev/snd'],
    volumes: ['disk:/storage'], ports: ['3389:3389/tcp'],
});

test('Helios configuration preserves VM data and QMP while selecting the paired stack', () => {
    const original = service();
    const updated = configureHelios(original, true, '/dev/dri/renderD129');
    assert.equal(updated.image, HELIOS_IMAGE);
    assert.equal(updated.environment.HELIOS_REVISION, HELIOS_REVISION);
    assert.equal(updated.environment.RENDERNODE, '/dev/dri/renderD129');
    assert.equal(updated.environment.GPU, 'N');
    assert.equal(updated.environment.ARGUMENTS, original.environment.ARGUMENTS);
    assert.deepEqual(updated.volumes, original.volumes);
    assert.deepEqual(updated.ports, original.ports);
    assert.equal(updated.devices.filter(x => x.startsWith('/dev/dri')).length, 1);
    assert.ok(updated.devices.includes('/dev/kvm'));
    assert.ok(updated.devices.includes('/dev/snd:/dev/snd'));
    assert.ok(!('VIRGL' in updated.environment));
    assert.equal(original.image, 'ghcr.io/dockur/windows:5.07');
});

test('only NVIDIA configurations request the NVIDIA Container Toolkit', () => {
    assert.equal(configureHelios(service(), true, '/dev/dri/renderD128', true).gpus, 'all');
    assert.equal(configureHelios(service(), true, '/dev/dri/renderD128').gpus, undefined);
});

test('Helios rejects card-only detection and invalid render-node arguments', () => {
    for (const node of [undefined, '/dev/dri/card0', '/dev/dri/renderD128 -device evil', '/tmp/renderD128']) {
        assert.throws(() => configureHelios(service(), true, node), /render node/);
    }
});

test('disabling Helios preserves the Windows disk and removes only managed graphics settings', () => {
    const enabled = configureHelios(service(), true, '/dev/dri/renderD128', true);
    const disabled = configureHelios(enabled, false);
    assert.equal(disabled.image, 'ghcr.io/dockur/windows:5.07');
    assert.deepEqual(disabled.volumes, enabled.volumes);
    assert.equal(disabled.gpus, undefined);
    assert.equal(disabled.environment.NVIDIA_VISIBLE_DEVICES, undefined);
    assert.equal(disabled.environment.HELIOS, undefined);
    assert.deepEqual(disabled.devices, ['/dev/kvm', '/dev/snd:/dev/snd']);
});

test('driver state never reports completion for failures, unknown states or mismatched revisions', () => {
    assert.throws(() => validateHeliosProgress({ status: 'finished', revision: 'wrong' }), /revisions do not match/);
    assert.throws(() => validateHeliosProgress({ status: 'failed', revision: HELIOS_GUEST_REVISION, message: 'Secure Boot enabled' }), /Secure Boot enabled/);
    assert.throws(() => validateHeliosProgress({ status: 'unknown', revision: HELIOS_GUEST_REVISION }), /invalid/);
    assert.throws(() => validateHeliosProgress({ status: 'finished', revision: HELIOS_GUEST_REVISION, installed: false }), /without an installed driver/);
    for (const status of ['waiting', 'test-signing-restart-required', 'driver-restart-required', 'finished']) {
        assert.equal(validateHeliosProgress({ status, revision: HELIOS_GUEST_REVISION, installed: status === 'finished' }).status, status);
    }
});

function bundleFixture(directory: string) {
    // Format-only fixture. This is deliberately not a runnable Windows installer.
    const pe = Buffer.alloc(128); pe.write('MZ');
    const payload = Buffer.from('header+compressed-payload-for-format-testing');
    const footer = Buffer.alloc(64);
    footer.writeBigUInt64LE(BigInt(pe.length), 0);
    footer.writeBigUInt64LE(BigInt(payload.length), 8);
    footer.writeBigUInt64LE(6n, 16);
    crypto.createHash('sha256').update(payload).digest().copy(footer, 24);
    footer.write('HLIOSET2', 56);
    const exe = Buffer.concat([pe, payload, footer]);
    const receipt = { revision: HELIOS_GUEST_REVISION, sha256: crypto.createHash('sha256').update(exe).digest('hex') };
    fs.writeFileSync(path.join(directory, 'HeliosSetup.exe'), exe);
    fs.writeFileSync(path.join(directory, 'helios-build.json'), JSON.stringify(receipt));
    return { exe, receipt };
}

test('staging validates full payload, source pin and installer checksum', t => {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'helios-test-'));
    t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
    const { exe, receipt } = bundleFixture(directory);
    assert.equal(verifyBundle(directory).revision, HELIOS_GUEST_REVISION);
    exe[130] ^= 1;
    fs.writeFileSync(path.join(directory, 'HeliosSetup.exe'), exe);
    assert.throws(() => verifyBundle(directory), /checksum mismatch/);
    receipt.sha256 = crypto.createHash('sha256').update(exe).digest('hex');
    fs.writeFileSync(path.join(directory, 'helios-build.json'), JSON.stringify(receipt));
    assert.throws(() => verifyBundle(directory), /payload checksum/);
    const valid = bundleFixture(directory);
    fs.writeFileSync(path.join(directory, 'helios-build.json'), JSON.stringify({ ...valid.receipt, revision: 'wrong' }));
    assert.throws(() => verifyBundle(directory), /incompatible/);
    fs.writeFileSync(path.join(directory, 'HeliosSetup.exe'), Buffer.from('MZ-skeleton'));
    fs.writeFileSync(path.join(directory, 'helios-build.json'), JSON.stringify(valid.receipt));
    assert.throws(() => verifyBundle(directory), /complete/);
});

test('host and Windows CI follow the pinned compatible stack', () => {
    const workflow = parse(fs.readFileSync('.github/workflows/build-helios-windows.yml', 'utf8'));
    let checkouts = 0;
    for (const job of Object.values(workflow.jobs) as any[]) {
        for (const step of job.steps) {
            if (step.uses?.startsWith('actions/checkout@')) {
                checkouts++;
                assert.equal(step.with.repository, undefined);
                assert.equal(step.with.ref, undefined);
                assert.equal(step.with['persist-credentials'], false);
            }
        }
    }
    assert.ok(checkouts >= 5);
    assert.equal(workflow.defaults.run['working-directory'], 'temp/helios-windows');
    for (const job of Object.values(workflow.jobs) as any[]) {
        const prepare = job.steps.find((step: any) => step.name === 'Prepare embedded Helios sources');
        assert.ok(prepare?.run.includes('Initialize-Sources.ps1'));
        assert.equal(prepare['working-directory'], '.');
    }
    for (const filename of ['helios/host/Dockerfile', 'helios/host/build-stack.sh']) {
        assert.ok(fs.readFileSync(filename, 'utf8').includes(HELIOS_REVISION), filename);
    }
    assert.ok(fs.readFileSync('guest_server/scripts/Start-HeliosProvisioning.ps1', 'utf8').includes(HELIOS_GUEST_REVISION));
    const lock = JSON.parse(fs.readFileSync('helios/stack.lock.json', 'utf8'));
    assert.equal(lock.hostRevision, HELIOS_REVISION);
    assert.equal(lock.guestRevision, HELIOS_GUEST_REVISION);
    const source = JSON.parse(fs.readFileSync('helios/source.lock.json', 'utf8'));
    assert.equal(source.revision, lock.hostRevision);
    for (const dep of source.submodules) {
        if (dep.path in lock.sharedSources) assert.equal(dep.revision, lock.sharedSources[dep.path]);
    }
    assert.ok(Object.keys(source.files).length > 0);
    for (const [filename, checksum] of Object.entries(source.files)) {
        assert.equal(crypto.createHash('sha256').update(fs.readFileSync(path.join('helios/upstream', filename))).digest('hex'), checksum, filename);
    }
    const builder = JSON.parse(fs.readFileSync('electron-builder.json', 'utf8'));
    assert.ok(builder.extraResources.some((x: any) => x.to === 'helios' && x.filter.includes('HeliosSetup.exe')));
});

test('generated Helios compose validates as a real Docker Compose configuration', async () => {
    const { spawnSync } = await import('node:child_process');
    const { stringify } = await import('yaml');
    const windows = configureHelios(service(), true, '/dev/dri/renderD128', true);
    const yaml = stringify({ name: 'winboat', services: { windows }, volumes: { disk: {} } });
    const result = spawnSync('docker', ['compose', '-f', '-', 'config', '--quiet'], { input: yaml, encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
});
