import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { verifyBundle } from './bundle.ts';
const root = fileURLToPath(new URL('../../', import.meta.url));
const source = process.argv[2];
if (!source) throw new Error('Usage: npm run helios:stage -- <directory containing HeliosSetup.exe and helios-build.json>');
verifyBundle(source);
const destination = path.join(root, 'resources/helios');
fs.mkdirSync(destination, { recursive: true });
for (const name of ['HeliosSetup.exe', 'helios-build.json']) {
    const target = path.join(destination, name);
    if (path.resolve(source, name) !== target) fs.copyFileSync(path.join(source, name), target);
}
verifyBundle(destination);
console.log('Verified and staged the pinned Helios Windows installer.');
