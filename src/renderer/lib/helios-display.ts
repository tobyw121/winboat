import { HELIOS_IMAGE } from '../../shared/helios';
import { HELIOS_DISPLAY_CAPABILITY, HELIOS_DISPLAY_VERSION, HELIOS_DISPLAY_MOUNT,
    heliosDisplayAddress, heliosDisplayBusConfig, heliosDisplayDirectory } from '../../shared/helios-display';
import type { ComposeConfig } from '../../types';
const fs: typeof import('fs') = require('fs');
const path: typeof import('path') = require('path');
const net: typeof import('net') = require('net');
const child: typeof import('child_process') = require('child_process');
const { promisify }: typeof import('util') = require('util');
const remote: typeof import('@electron/remote') = require('@electron/remote');
const execFile = promisify(child.execFile);
let startingBus: Promise<void> | undefined;
let activeViewer: import('child_process').ChildProcess | undefined;

function binary(): string {
    return remote.app.isPackaged ? path.join(process.resourcesPath, 'native', 'winboat-helios-viewer')
        : path.resolve(remote.app.getAppPath(), '..', '..', 'build/native/winboat-helios-viewer');
}
export function localDisplayDirectory(): string {
    return heliosDisplayDirectory(process.getuid!(), process.env.XDG_RUNTIME_DIR);
}
export async function requireLocalDisplay(): Promise<void> {
    try {
        const { stdout } = await execFile(binary(), ['--version'], { timeout: 3000 });
        if (stdout.trim() !== 'winboat-helios-viewer 3') throw new Error('Viewer protocol mismatch.');
    }
    catch { throw new Error('The local Helios viewer needs its bundled executable, GTK 4.8+, libepoxy and a desktop session. Install the GTK4 runtime or use Browser Display.'); }
    const { stdout } = await execFile('docker', ['image', 'inspect', '--format', `{{ index .Config.Labels "${HELIOS_DISPLAY_CAPABILITY}" }}`, HELIOS_IMAGE]);
    if (stdout.trim() !== HELIOS_DISPLAY_VERSION) throw new Error('Rebuild the Helios host image to enable local display support.');
}

async function startBus(): Promise<void> {
    if (process.env.XDG_RUNTIME_DIR) {
        const runtime = fs.lstatSync(process.env.XDG_RUNTIME_DIR);
        if (!runtime.isDirectory() || runtime.isSymbolicLink() || runtime.uid !== process.getuid!() || (runtime.mode & 0o077)) {
            throw new Error('XDG_RUNTIME_DIR must be a private directory owned by your user.');
        }
    }
    const directory = localDisplayDirectory();
    if (!fs.existsSync(directory)) fs.mkdirSync(directory, { mode: 0o700 });
    const stat = fs.lstatSync(directory);
    if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== process.getuid!() || (stat.mode & 0o077)) {
        throw new Error('The local display directory must be private (0700) and owned by your user.');
    }
    const socket = path.join(directory, 'bus');
    if (fs.existsSync(socket)) {
        const info = fs.lstatSync(socket);
        if (!info.isSocket() || info.uid !== process.getuid!()) throw new Error('Unexpected local display socket.');
        try { await execFile(binary(), ['--ping', heliosDisplayAddress(directory)], { timeout: 3000 }); return; }
        catch {
            // Unlink only a refused socket. A live, unresponsive bus may still
            // serve the VM and must not be replaced underneath it.
            await new Promise<void>((resolve, reject) => {
                const connection = net.createConnection(socket);
                connection.setTimeout(1500, () => { connection.destroy(); reject(new Error('The local display bus is unresponsive.')); });
                connection.once('connect', () => { connection.destroy(); reject(new Error('The local display bus rejected authentication.')); });
                connection.once('error', (error: NodeJS.ErrnoException) => {
                    if (error.code === 'ECONNREFUSED' || error.code === 'ENOENT') resolve(); else reject(error);
                });
            });
            fs.rmSync(socket, { force: true });
        }
    }
    const config = path.join(directory, 'bus.conf');
    fs.writeFileSync(config, heliosDisplayBusConfig(directory, process.getuid!()), { mode: 0o600 });
    await execFile('dbus-daemon', [`--config-file=${config}`, '--fork'], { timeout: 5000 });
    await execFile(binary(), ['--ping', heliosDisplayAddress(directory)], { timeout: 3000 });
}
export async function prepareLocalDisplay(compose: ComposeConfig): Promise<void> {
    const service = compose.services.windows;
    if (service.environment.HELIOS_DISPLAY !== 'dbus') return;
    if (service.restart !== 'no') throw new Error('Local desktop requires automatic container startup to be disabled.');
    if (service.environment.HELIOS !== '1' || !service.volumes.includes(`${localDisplayDirectory()}:${HELIOS_DISPLAY_MOUNT}:ro`)) {
        throw new Error('Reapply the local display option in Settings for this desktop session.');
    }
    await requireLocalDisplay();
    if (!startingBus) startingBus = startBus().finally(() => { startingBus = undefined; });
    await startingBus;
}

export async function launchLocalDisplay(onFailure: (message: string) => void): Promise<void> {
    if (activeViewer && activeViewer.exitCode === null) return;
    await new Promise<void>((resolve, reject) => {
        const process = child.spawn(binary(), ['--address', heliosDisplayAddress(localDisplayDirectory())], { stdio: ['ignore', 'pipe', 'pipe'] });
        activeViewer = process;
        let ready = false, output = '', errors = '', settled = false;
        const timer = setTimeout(() => { process.kill(); fail('Local display did not become ready within 10 seconds.'); }, 10000);
        const fail = (message: string) => {
            clearTimeout(timer);
            if (settled) return;
            settled = true;
            if (ready) onFailure(message); else reject(new Error(message));
        };
        process.stdout!.on('data', (data: Buffer) => {
            output = (output + data.toString()).slice(-16384);
            if (!ready && output.split('\n').some(line => line === '{"event":"ready","transport":"dbus"}')) {
                ready = true; clearTimeout(timer); resolve();
            }
        });
        process.stderr!.on('data', (data: Buffer) => { errors = (errors + data.toString()).slice(-8192); });
        process.once('error', error => {
            if (activeViewer === process) activeViewer = undefined;
            fail(error.message);
        });
        process.once('exit', code => {
            if (activeViewer === process) activeViewer = undefined;
            clearTimeout(timer);
            if (code !== 0 || !ready) fail(errors || 'The local display disconnected before it was ready.');
        });
    });
}
