import {HELIOS_RUNTIME_VERSION,HELIOS_GUEST_REVISION} from '../src/shared/helios.ts';
import {HELIOS_DISPLAY_VERSION} from '../src/shared/helios-display.ts';
import {GUEST_GRAPHICS_PROTOCOL,GUEST_RUNTIME_PROTOCOL} from '../src/shared/guest-protocol.ts';
import Path from 'path';
import Chalk from 'chalk';
import FileSystem from 'fs';
import * as Vite from 'vite';
import compileTs from './private/tsc.ts';
// ^ Extension can't be omitted because Node expects it
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = Path.dirname(__filename);

function buildRenderer() {
    return Vite.build({
        configFile: Path.join(__dirname, '..', 'vite.config.ts'),
        base: './',
        mode: 'production'
    });
}

function buildMain() {
    const mainPath = Path.join(__dirname, '..', 'src', 'main');
    return compileTs(mainPath);
}

FileSystem.rmSync(Path.join(__dirname, '..', 'build'), {
    recursive: true,
    force: true,
})

console.log(Chalk.blueBright('Transpiling renderer & main...'));

try {
    await Promise.all([buildRenderer(), buildMain()]);
    FileSystem.writeFileSync(Path.join(__dirname,'../build/graphics-requirements.json'),JSON.stringify({
        runtime:HELIOS_RUNTIME_VERSION,display:HELIOS_DISPLAY_VERSION,revision:HELIOS_GUEST_REVISION,
        guest:GUEST_GRAPHICS_PROTOCOL,guestRuntime:GUEST_RUNTIME_PROTOCOL,viewer:13}));
    console.log(Chalk.greenBright('Renderer & main successfully transpiled!'));
} catch (error) {
    console.error(error);
    process.exitCode = 1;
}
