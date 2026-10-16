import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { HELIOS_GUEST_REVISION } from '../../src/shared/helios.ts';

export function verifyBundle(directory: string): { revision: string; sha256: string } {
    const receipt = JSON.parse(fs.readFileSync(path.join(directory, 'helios-build.json'), 'utf8'));
    if (receipt.revision !== HELIOS_GUEST_REVISION || !/^[a-f0-9]{64}$/.test(receipt.sha256)) throw new Error('Helios bundle has incompatible source identity or checksum.');
    const exe = fs.readFileSync(path.join(directory, 'HeliosSetup.exe'));
    if (exe.length < 128 || exe.toString('ascii', 0, 2) !== 'MZ' || exe.toString('ascii', exe.length - 8) !== 'HLIOSET2') {
        throw new Error('Expected the complete, self-contained HeliosSetup.exe, not an installer skeleton.');
    }
    if (crypto.createHash('sha256').update(exe).digest('hex') !== receipt.sha256) throw new Error('HeliosSetup.exe checksum mismatch.');
    const footer = exe.subarray(-64);
    const offset = Number(footer.readBigUInt64LE(0));
    const size = Number(footer.readBigUInt64LE(8));
    const header = Number(footer.readBigUInt64LE(16));
    if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(size) || offset < 64 || size <= 0 || header <= 0 || header >= size || offset + size !== exe.length - 64) throw new Error('Invalid Helios installer payload bounds.');
    if (!crypto.createHash('sha256').update(exe.subarray(offset, offset + size)).digest().equals(footer.subarray(24, 56))) throw new Error('Helios installer payload checksum mismatch.');
    return receipt;
}
