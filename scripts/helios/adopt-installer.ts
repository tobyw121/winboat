import { fileURLToPath } from 'node:url';
import { adoptInstaller } from './bundled-installer.ts';
const directory = process.argv[2];
if (!directory) throw new Error('Usage: npm run helios:adopt-installer -- <directory from WinBoat Windows CI>');
adoptInstaller(directory, fileURLToPath(new URL('../../', import.meta.url)));
console.log('Updated the complete bundled installer, its receipt and the WinBoat checksum pin. Review and commit these three files together.');
