import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { reactive } from 'vue';
import { configureVmIdentity, createVmIdentity, validateVmIdentity, vmIdentitySmbios, VM_IDENTITY_FILE } from '../src/shared/vm-identity';
import { loadOrCreateVmIdentity } from '../src/shared/vm-identity-store';

const dmi = { board_vendor: 'ASUSTeK COMPUTER INC.', board_name: 'PRIME B450-PLUS',
    board_version: 'Rev X.0x', sys_vendor: 'System manufacturer', product_name: 'System Product Name',
    product_version: '1.0', product_serial: 'DO-NOT-COPY', product_uuid: 'DO-NOT-COPY' };

test('new identities retain usable host names and generate distinct private serials and RFC4122 UUIDs', () => {
    const a = createVmIdentity(dmi, 'AMD Ryzen 7 2700X');
    const b = createVmIdentity(dmi, 'AMD Ryzen 7 2700X');
    assert.equal(a.systemManufacturer, dmi.board_vendor);
    assert.equal(a.systemProduct, dmi.board_name);
    assert.equal(a.source, 'host-dmi');
    for (const field of ['uuid', 'systemSerial', 'boardSerial', 'chassisSerial'] as const) assert.notEqual(a[field], b[field]);
    assert.equal(validateVmIdentity(a), a);
    assert.ok(!JSON.stringify(a).includes('DO-NOT-COPY'));
    const fallback = createVmIdentity({ board_vendor: 'QEMU', board_name: 'Virtual Machine' }, 'Intel');
    assert.equal(fallback.source, 'preset');
    assert.equal(fallback.systemProduct, 'PRIME B660-PLUS D4');
});

test('SMBIOS records encode exact names, serials, UUID byte order and consistent chassis handles', () => {
    const p = createVmIdentity(dmi, 'AMD');
    p.uuid = '00112233-4455-4677-8899-aabbccddeeff';
    const files = vmIdentitySmbios(p);
    const system = files['system.bin'];
    assert.equal(system[0], 1);
    assert.equal(system[1], 27);
    assert.deepEqual(Array.from(system.slice(8, 24)), [0x33, 0x22, 0x11, 0, 0x55, 0x44, 0x77, 0x46, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff]);
    for (const [name, bytes] of Object.entries(files)) {
        assert.deepEqual(Array.from(bytes.slice(-2)), [0, 0], name);
        assert.ok(new TextDecoder().decode(bytes.slice(bytes[1])).includes(p.systemManufacturer), name);
    }
    assert.deepEqual(Array.from(files['baseboard.bin'].slice(11, 13)), [0, 3]);
});

test('CPU compatibility preserves KVM, host CPU selection, GPU devices, storage and QMP', () => {
    const service = reactive({ environment: { ARGUMENTS: '-qmp tcp:0.0.0.0:7149,server,wait=off', CPU_FLAGS: 'aes=on,+hypervisor,kvm=on,hv-time=on' },
        devices: ['/dev/kvm', '/dev/dri:/dev/dri'], volumes: ['disk:/storage'], image: 'helios' });
    const before = JSON.stringify(service);
    const p = createVmIdentity(dmi, 'AMD');
    const updated = configureVmIdentity(service, p, true);
    assert.equal(updated.environment.CPU_FLAGS, 'aes=on,kvm=off,-hypervisor');
    assert.equal(updated.environment.HV, 'N');
    assert.equal(updated.environment.KVM, undefined);
    assert.equal(updated.environment.CPU_MODEL, undefined);
    assert.deepEqual(updated.devices, service.devices);
    assert.deepEqual(updated.volumes, service.volumes);
    assert.equal(updated.environment.ARGUMENTS, service.environment.ARGUMENTS);
    assert.equal(updated.environment.SM_BIOS.split('-smbios').length, 4);
    assert.deepEqual(configureVmIdentity(updated, p, true), updated);
    assert.equal(JSON.stringify(service), before);
    assert.throws(() => configureVmIdentity({ environment: { UUID: 'another-machine' } }, p, true), /conflicts/);
    const standard = configureVmIdentity({ environment: { CPU_FLAGS: 'aes=on' } }, p, false);
    assert.equal(standard.environment.CPU_FLAGS, 'aes=on');
    assert.equal(standard.environment.HV, undefined);
});

test('identity survives repeated setup and corruption or an existing Windows disk never triggers regeneration', t => {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'winboat-identity-'));
    t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
    const p = loadOrCreateVmIdentity(fs, directory, 'AMD');
    const binary = path.join(directory, '.winboat-hardware', 'system.bin');
    assert.deepEqual(fs.readFileSync(binary), Buffer.from(vmIdentitySmbios(p)['system.bin']));
    fs.unlinkSync(binary);
    fs.writeFileSync(path.join(directory, 'data.img'), 'existing disk');
    assert.deepEqual(loadOrCreateVmIdentity(fs, directory, 'Intel'), p);
    assert.deepEqual(fs.readFileSync(binary), Buffer.from(vmIdentitySmbios(p)['system.bin']));
    assert.equal(fs.statSync(path.join(directory, VM_IDENTITY_FILE)).mode & 0o777, 0o600);
    fs.writeFileSync(path.join(directory, VM_IDENTITY_FILE), 'broken');
    assert.throws(() => loadOrCreateVmIdentity(fs, directory, 'AMD'));
    assert.equal(fs.readFileSync(path.join(directory, VM_IDENTITY_FILE), 'utf8'), 'broken');
    fs.unlinkSync(path.join(directory, VM_IDENTITY_FILE));
    assert.throws(() => loadOrCreateVmIdentity(fs, directory, 'AMD'), /already contains/);
    assert.equal(fs.readFileSync(path.join(directory, 'data.img'), 'utf8'), 'existing disk');
});

test('invalid strings, malformed UUIDs and linked identity files are rejected', t => {
    const p = createVmIdentity(dmi, 'AMD');
    assert.throws(() => vmIdentitySmbios({ ...p, systemManufacturer: 'bad\0data' }), /field/);
    assert.throws(() => validateVmIdentity({ ...p, uuid: 'not-a-uuid' }), /identity/);
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'winboat-identity-link-'));
    t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
    const outside = path.join(directory, 'backup.json');
    fs.writeFileSync(outside, JSON.stringify(p));
    fs.symlinkSync(outside, path.join(directory, VM_IDENTITY_FILE));
    assert.throws(() => loadOrCreateVmIdentity(fs, directory, 'AMD'), /file/);
    assert.deepEqual(JSON.parse(fs.readFileSync(outside, 'utf8')), p);
    fs.unlinkSync(path.join(directory, VM_IDENTITY_FILE));
    loadOrCreateVmIdentity(fs, directory, 'AMD');
    const binary = path.join(directory, '.winboat-hardware', 'system.bin');
    const missing = path.join(directory, 'must-not-be-created');
    fs.unlinkSync(binary);
    fs.symlinkSync(missing, binary);
    assert.throws(() => loadOrCreateVmIdentity(fs, directory, 'AMD'));
    assert.equal(fs.existsSync(missing), false);
});
