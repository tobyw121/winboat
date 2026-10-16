import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { reactive } from 'vue';
import { ATLAS_ASSETS, AME_WIZARD_ASSET, ATLAS_IMAGE, ATLAS_OPTIONS, configureAtlasIso, validateAtlasProgress, validateAtlasSelection } from '../src/shared/atlas.ts';
import { stageAtlasBundle } from '../src/shared/atlas-bundle.ts';

test('Atlas rejects incompatible media and never mistakes preparation or failure for completion', () => {
    validateAtlasSelection(true, '11');
    validateAtlasSelection(false, 'custom', '/iso');
    validateAtlasSelection(true, 'custom', '/custom.iso');
    for (const v of ['10', '11l', '11e', 'custom']) assert.throws(() => validateAtlasSelection(true, v));
    assert.throws(() => validateAtlasSelection(true, '11', '/custom.iso'));
    assert.equal(validateAtlasProgress({ release: '0.5.0-hotfix', status: 'awaiting-user', message: 'Preparation required' }).status, 'awaiting-user');
    assert.throws(() => validateAtlasProgress({ release: 'old', status: 'finished', message: '' }));
    assert.throws(() => validateAtlasProgress({ release: '0.5.0-hotfix', status: 'failed', message: 'Playbook errors' }), /Playbook errors/);
    assert.ok(ATLAS_OPTIONS.includes('defender-enable'));
    assert.ok(!ATLAS_OPTIONS.some(x => x.includes('disable')));
});

test('ISO entrypoint chains the hardware hook and preserves CPU, GPU and storage settings', () => {
    const service = reactive({ environment: { WINBOAT_HARDWARE_PROFILE: '1', CPU_FLAGS: 'kvm=off,-hypervisor' },
        entrypoint: ['/usr/bin/tini', '-s', '--', '/bin/bash', '/oem/.winboat-hardware/entry.sh'],
        volumes: ['disk:/storage'], devices: ['/dev/kvm'], gpus: 'all' });
    const actual = configureAtlasIso(service);
    assert.equal(actual.entrypoint.at(-1), '/oem/.winboat-atlas/entry.sh');
    assert.equal(actual.environment.CPU_FLAGS, service.environment.CPU_FLAGS);
    assert.deepEqual(actual.volumes, service.volumes);
    assert.equal(actual.gpus, 'all');
    assert.equal(service.entrypoint.at(-1), '/oem/.winboat-hardware/entry.sh');
    assert.throws(() => configureAtlasIso({ entrypoint: ['/custom'], environment: {} }), /custom/);
    const live = configureAtlasIso({ image: 'dockurr/windows', environment: {} }, 'live');
    assert.equal(live.image, ATLAS_IMAGE);
    assert.equal(live.environment.WINBOAT_ATLAS_MODE, 'live');
    assert.equal(configureAtlasIso({ image: 'paired-helios', environment: { HELIOS: '1' } }).image, 'paired-helios');
});

test('Atlas staging verifies downloads before publishing and reuses validated media', async t => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'winboat-atlas-'));
    t.after(() => fs.rmSync(root, { recursive: true, force: true }));
    const digest = (b: Uint8Array) => crypto.createHash('sha256').update(b).digest('hex');
    await assert.rejects(stageAtlasBundle(fs, path, digest, root, 'user', false,
        async () => Buffer.from('corrupt download'), () => {}, 'iso', undefined, 'test password'), /SHA-256/);
    assert.ok(!fs.existsSync(path.join(root, 'atlas.json')));
    assert.deepEqual(fs.readdirSync(root), []);
    // Injected digest substitutes synthetic bytes, never executable release binaries.
    const assets = [...ATLAS_ASSETS, AME_WIZARD_ASSET];
    const fixtures = assets.map((_, i) => Buffer.from(`fixture-${i}`));
    const fixtureDigest = (data: Uint8Array) => assets[fixtures.findIndex(b => b.equals(Buffer.from(data)))]?.sha256 || 'invalid';
    const bundled = path.join(root, 'bundled');
    fs.mkdirSync(bundled);
    fs.writeFileSync(path.join(bundled, 'AtlasPlaybook.apbx'), fixtures[1]);
    let requests = 0;
    const download = async (url: string) => { requests++; return fixtures[assets.findIndex(a => a.url === url)]; };
    await stageAtlasBundle(fs, path, fixtureDigest, root, 'user', true,
        download, () => {}, 'iso', bundled, 'test password');
    const conf = JSON.parse(fs.readFileSync(path.join(root, 'atlas.json'), 'utf8'));
    assert.equal(conf.mode, 'iso');
    assert.equal(conf.waitForHelios, true);
    assert.deepEqual(conf.options, ATLAS_OPTIONS);
    assert.ok(!JSON.stringify(conf).includes('test password'));
    assert.equal(fs.statSync(path.join(root, 'oobe-credentials.json')).mode & 0o777, 0o600);
    assert.equal(requests, 1); // Playbook comes from the installed application.
    await stageAtlasBundle(fs, path, fixtureDigest, root, 'user', false,
        download, () => {}, 'live', bundled);
    assert.equal(requests, 2);
    assert.ok(!fs.existsSync(path.join(root, 'oobe-credentials.json')));
    assert.ok(!fs.existsSync(path.join(root, AME_WIZARD_ASSET.name)));
    await stageAtlasBundle(fs, path, fixtureDigest, root, 'user', false,
        async () => { throw new Error('unexpected download'); }, () => {}, 'live', bundled);
    assert.equal(JSON.parse(fs.readFileSync(path.join(root, 'atlas.json'), 'utf8')).mode, 'live');
    fs.writeFileSync(path.join(bundled, 'AtlasPlaybook.apbx'), 'damaged');
    await assert.rejects(stageAtlasBundle(fs, path, fixtureDigest, root, 'user', false,
        download, () => {}, 'live', bundled), /bundled Atlas playbook is damaged/);
});
