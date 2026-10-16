/** Reproduce the installer import from an immutable, checksum-pinned CI artifact. */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { verifyBundle } from './bundle.ts';
const root = fileURLToPath(new URL('../../', import.meta.url));
const lock = JSON.parse(fs.readFileSync(path.join(root, 'helios/stack.lock.json'), 'utf8'));
const artifact = lock.installerArtifact;
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'winboat-helios-'));
function digest(bytes: Buffer): string { return crypto.createHash('sha256').update(bytes).digest('hex'); }
try {
    const archive = path.join(temporary, 'artifact.zip');
    // curl uses the inherited HTTPS proxy and CA trust. No token extraction.
    execFileSync('curl', ['--fail', '--location', '--silent', '--show-error', '--max-time', '180',
        `https://api.github.com/repos/winboat-org/helios/actions/artifacts/${artifact.id}/zip`, '-o', archive], { stdio: 'inherit' });
    if (digest(fs.readFileSync(archive)) !== artifact.sha256) throw new Error('Upstream artifact SHA-256 mismatch.');
    const inner = execFileSync('unzip', ['-p', archive, artifact.package], { maxBuffer: 128 * 1024 * 1024 });
    const innerHash = execFileSync('unzip', ['-p', archive, `${artifact.package}.sha256`], { encoding: 'utf8' }).trim().split(/\s+/)[0];
    if (digest(inner) !== innerHash) throw new Error('Upstream Windows bundle checksum mismatch.');
    const packagePath = path.join(temporary, 'package.zip');
    fs.writeFileSync(packagePath, inner);
    const exe = execFileSync('unzip', ['-p', packagePath, artifact.entry], { maxBuffer: 128 * 1024 * 1024 });
    if (digest(exe) !== artifact.executableSha256) throw new Error('Pinned Windows installer checksum mismatch.');
    fs.writeFileSync(path.join(temporary, 'HeliosSetup.exe'), exe);
    fs.writeFileSync(path.join(temporary, 'helios-build.json'), JSON.stringify({ revision: lock.guestRevision, sha256: artifact.executableSha256, artifactId: artifact.id }, null, 2));
    verifyBundle(temporary);
    const destination = path.join(root, 'resources/helios');
    fs.mkdirSync(destination, { recursive: true });
    for (const name of ['HeliosSetup.exe', 'helios-build.json']) fs.copyFileSync(path.join(temporary, name), path.join(destination, name));
    console.log(`Verified and staged HeliosSetup.exe from upstream artifact ${artifact.id}.`);
} finally { fs.rmSync(temporary, { recursive: true, force: true }); }
