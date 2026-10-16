/** Boots a tiny diagnostic guest with TCG, never a Windows disk or physical GPU. */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { HELIOS_IMAGE } from '../../src/shared/helios.ts';
import { createVmIdentity, configureVmIdentity, vmIdentitySmbios } from '../../src/shared/vm-identity.ts';

const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'winboat-identity-qemu-'));
try {
    const profile = createVmIdentity({ board_vendor: 'ASUSTeK COMPUTER INC.', board_name: 'PRIME B450-PLUS' }, 'AMD');
    fs.mkdirSync(path.join(directory, 'hardware'));
    for (const [name, bytes] of Object.entries(vmIdentitySmbios(profile))) fs.writeFileSync(path.join(directory, 'hardware', name), bytes);
    const cases = [false, true].map(reduced => ({ reduced, environment: configureVmIdentity({ environment: {} }, profile, reduced).environment }));
    fs.writeFileSync(path.join(directory, 'settings.json'), JSON.stringify({ profile, cases }));
    const result = spawnSync('python3', ['tests/vm-identity-qemu.py', directory, HELIOS_IMAGE], { stdio: 'inherit', timeout: 240000 });
    if (result.error) throw result.error;
    process.exitCode = result.status ?? 1;
} finally { fs.rmSync(directory, { recursive: true, force: true }); }
