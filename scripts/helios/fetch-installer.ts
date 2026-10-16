/** Backwards-compatible command: the complete installer now ships in Git. */
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { verifyPinnedInstaller } from './bundled-installer.ts';
const root = fileURLToPath(new URL('../../', import.meta.url));
try {
    verifyPinnedInstaller(path.join(root, 'resources/helios'), root);
    console.log('The complete, verified Helios installer is bundled in WinBoat. No download is needed.');
} catch (error) {
    console.error(error instanceof Error ? error.message : 'Bundled installer verification failed.');
    process.exitCode = 1;
}
