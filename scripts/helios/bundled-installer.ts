import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { verifyBundle } from './bundle.ts';

export function verifyPinnedInstaller(directory: string, root: string): void {
    const receipt = verifyBundle(directory);
    const lock = JSON.parse(fs.readFileSync(path.join(root, 'helios/stack.lock.json'), 'utf8'));
    if (receipt.sha256 !== lock.bundledInstaller.sha256) {
        throw new Error('Installer differs from the WinBoat bundle pin. Import a reviewed Windows CI build with npm run helios:adopt-installer -- <directory>.');
    }
}

/** Explicitly promote an installer produced by this repository's Windows CI. */
export function adoptInstaller(directory: string, root: string): void {
    const receipt = JSON.parse(fs.readFileSync(path.join(directory, 'helios-build.json'), 'utf8'));
    verifyBundle(directory);
    const lockFile = path.join(root, 'helios/stack.lock.json');
    const lock = JSON.parse(fs.readFileSync(lockFile, 'utf8'));
    const sourceLock = fs.readFileSync(path.join(root, 'helios/source.lock.json'));
    if (receipt.repository !== lock.installerBuild.repository || !/^[a-f0-9]{40}$/.test(receipt.winboatCommit || '')
        || receipt.sourceSnapshot !== lock.hostRevision
        || receipt.sourceLockSha256 !== crypto.createHash('sha256').update(sourceLock).digest('hex')
        || receipt.workflow !== lock.installerBuild.workflow) {
        throw new Error('Installer is not a matching WinBoat Windows CI build. Check its repository, source snapshot and provenance receipt.');
    }
    const destination = path.join(root, lock.bundledInstaller.path);
    fs.mkdirSync(destination, { recursive: true });
    for (const name of ['HeliosSetup.exe', 'helios-build.json']) {
        if (path.resolve(directory, name) !== path.resolve(destination, name)) fs.copyFileSync(path.join(directory, name), path.join(destination, name));
    }
    lock.bundledInstaller.sha256 = receipt.sha256;
    lock.bundledInstaller.provenance = { repository: receipt.repository, winboatCommit: receipt.winboatCommit,
        sourceSnapshot: receipt.sourceSnapshot, sourceLockSha256: receipt.sourceLockSha256, workflow: receipt.workflow };
    fs.writeFileSync(lockFile, JSON.stringify(lock, null, 2) + '\n');
    verifyPinnedInstaller(destination, root);
}
