import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { adoptInstaller, verifyPinnedInstaller } from '../scripts/helios/bundled-installer.ts';
import { HELIOS_GUEST_REVISION } from '../src/shared/helios.ts';

const digest = (data: Buffer | string) => crypto.createHash('sha256').update(data).digest('hex');

function fixture(t: { after: (fn: () => void) => void }) {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'winboat-installer-test-'));
    t.after(() => fs.rmSync(root, { recursive: true, force: true }));
    fs.mkdirSync(path.join(root, 'helios'));
    const source = fs.readFileSync('helios/source.lock.json');
    fs.writeFileSync(path.join(root, 'helios/source.lock.json'), source);
    const lock = JSON.parse(fs.readFileSync('helios/stack.lock.json', 'utf8'));
    fs.writeFileSync(path.join(root, 'helios/stack.lock.json'), JSON.stringify(lock));
    const candidate = path.join(root, 'candidate'); fs.mkdirSync(candidate);
    // Format-only fixture, deliberately not a runnable Windows executable.
    const pe = Buffer.alloc(128); pe.write('MZ');
    const payload = Buffer.from('header-and-fixture-container-data');
    const footer = Buffer.alloc(64);
    footer.writeBigUInt64LE(BigInt(pe.length)); footer.writeBigUInt64LE(BigInt(payload.length), 8);
    footer.writeBigUInt64LE(6n, 16); crypto.createHash('sha256').update(payload).digest().copy(footer, 24);
    footer.write('HLIOSET2', 56);
    const exe = Buffer.concat([pe, payload, footer]);
    const receipt = { revision: HELIOS_GUEST_REVISION, sha256: digest(exe),
        repository: lock.installerBuild.repository, winboatCommit: 'a'.repeat(40), sourceSnapshot: lock.hostRevision,
        sourceLockSha256: digest(source), workflow: lock.installerBuild.workflow };
    fs.writeFileSync(path.join(candidate, 'HeliosSetup.exe'), exe);
    fs.writeFileSync(path.join(candidate, 'helios-build.json'), JSON.stringify(receipt));
    return { root, candidate, receipt, lock };
}

test('the Git-bundled installer is complete and matches the trusted WinBoat checksum pin', () => {
    verifyPinnedInstaller('resources/helios', process.cwd());
    const receipt = JSON.parse(fs.readFileSync('resources/helios/helios-build.json', 'utf8'));
    assert.equal(receipt.revision, HELIOS_GUEST_REVISION);
    assert.ok(fs.statSync('resources/helios/HeliosSetup.exe').size > 1024 * 1024);
    const build = fs.readFileSync('scripts/helios/build-app.sh', 'utf8');
    assert.ok(!build.includes('helios:fetch-installer'));
    assert.ok(!fs.readFileSync('scripts/helios/fetch-installer.ts', 'utf8').includes('api.github.com'));
});

test('Windows-style Git checkouts preserve the checksum-locked snapshot including mixed original line endings', t => {
    const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'winboat-eol-test-'));
    t.after(() => fs.rmSync(temporary, { recursive: true, force: true }));
    const source = path.join(temporary, 'source'), checkout = path.join(temporary, 'checkout');
    fs.mkdirSync(source);
    const git = (...args: string[]) => execFileSync('git', args, { stdio: 'pipe' });
    git('init', '--initial-branch=main', source);
    git('-C', source, 'config', 'core.autocrlf', 'false');
    fs.copyFileSync('.gitattributes', path.join(source, '.gitattributes'));
    const originals = { 'helios/upstream/installer/src/main.rs': Buffer.from('first\nsecond\n'),
        'helios/upstream/umd12/bindgen/cached/bindings.rs': Buffer.from('first\r\nsecond\r\n'),
        'helios/source.lock.json': Buffer.from('{}\n') };
    for (const [name, bytes] of Object.entries(originals)) {
        fs.mkdirSync(path.dirname(path.join(source, name)), { recursive: true });
        fs.writeFileSync(path.join(source, name), bytes);
    }
    git('-C', source, 'add', '.');
    git('-C', source, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
        '-c', 'commit.gpgsign=false', 'commit', '-qm', 'fixture');
    git('clone', '--no-checkout', '--quiet', source, checkout);
    git('-C', checkout, 'config', 'core.autocrlf', 'true');
    git('-C', checkout, 'checkout', '--quiet', 'HEAD');
    for (const [name, bytes] of Object.entries(originals)) assert.deepEqual(fs.readFileSync(path.join(checkout, name)), bytes, name);
});

test('a self-consistent receipt cannot silently replace the pinned bundled installer', t => {
    const { root, candidate } = fixture(t);
    assert.throws(() => verifyPinnedInstaller(candidate, root), /bundle pin/);
});

test('explicit adoption verifies CI provenance and updates the installer, receipt and pin together', t => {
    const { root, candidate, receipt } = fixture(t);
    adoptInstaller(candidate, root);
    const destination = path.join(root, 'resources/helios');
    verifyPinnedInstaller(destination, root);
    const lock = JSON.parse(fs.readFileSync(path.join(root, 'helios/stack.lock.json'), 'utf8'));
    assert.equal(lock.bundledInstaller.sha256, receipt.sha256);
    assert.equal(lock.bundledInstaller.provenance.winboatCommit, receipt.winboatCommit);
    assert.equal(JSON.parse(fs.readFileSync(path.join(destination, 'helios-build.json'), 'utf8')).winboatCommit, receipt.winboatCommit);
});

test('adoption rejects wrong repositories, source snapshots and source-lock digests without modifying the pin', t => {
    const { root, candidate, receipt } = fixture(t);
    const before = fs.readFileSync(path.join(root, 'helios/stack.lock.json'), 'utf8');
    for (const override of [{ repository: 'other/project' }, { sourceSnapshot: 'b'.repeat(40) },
        { sourceLockSha256: '0'.repeat(64) }, { winboatCommit: 'not-a-commit' }]) {
        fs.writeFileSync(path.join(candidate, 'helios-build.json'), JSON.stringify({ ...receipt, ...override }));
        assert.throws(() => adoptInstaller(candidate, root), /matching WinBoat/);
        assert.equal(fs.readFileSync(path.join(root, 'helios/stack.lock.json'), 'utf8'), before);
    }
    assert.ok(!fs.existsSync(path.join(root, 'resources/helios')));
});
