import { hostEnvironment } from './host-environment';
import { nativeDesktopEnvironment } from '../../shared/native-desktop-environment';
import { HELIOS_IMAGE } from '../../shared/helios';
import { HELIOS_DISPLAY_CAPABILITY, HELIOS_DISPLAY_VERSION, HELIOS_DISPLAY_MOUNT,
    heliosDisplayAddress, heliosDisplayBusConfig, heliosDisplayDirectory } from '../../shared/helios-display';
import type { ComposeConfig } from '../../types';
import { ref } from 'vue';
import { HeliosViewer, type ViewerState } from '../../shared/helios-viewer';
const fs: typeof import('fs') = require('fs');
const path: typeof import('path') = require('path');
const net: typeof import('net') = require('net');
const child: typeof import('child_process') = require('child_process');
const { promisify }: typeof import('util') = require('util');
const remote: typeof import('@electron/remote') = require('@electron/remote');
const execFile = promisify(child.execFile);
let startingBus: Promise<void> | undefined;
export const localDisplayState = ref<ViewerState>('closed');
export const localDisplayMessage = ref('');
let openingConsole: Promise<void> | undefined;
const viewer = new HeliosViewer(() => child.spawn(binary(), ['--address', heliosDisplayAddress(localDisplayDirectory())],
    { env: desktopEnvironment(), stdio: ['ignore', 'pipe', 'pipe'] }), (state, message) => {
    localDisplayState.value = state; localDisplayMessage.value = message;
});

function desktopEnvironment(): NodeJS.ProcessEnv {
    return nativeDesktopEnvironment(hostEnvironment(), remote.app.isPackaged ? path.dirname(process.resourcesPath) : undefined);
}

function binary(): string {
    return remote.app.isPackaged ? path.join(process.resourcesPath, 'native', 'winboat-helios-viewer')
        : path.resolve(remote.app.getAppPath(), '..', '..', 'build/native/winboat-helios-viewer');
}
export function localDisplayDirectory(): string {
    return heliosDisplayDirectory(process.getuid!(), hostEnvironment().XDG_RUNTIME_DIR);
}
export async function requireLocalDisplay(): Promise<void> {
    if (!hostEnvironment().DISPLAY && !hostEnvironment().WAYLAND_DISPLAY) throw new Error('Local Desktop needs a running X11 or Wayland desktop session.');
    try {
        const { stdout } = await execFile(binary(), ['--version'], { timeout: 3000, env: desktopEnvironment() });
        if (stdout.trim() !== 'winboat-helios-viewer 3') throw new Error('Viewer protocol mismatch.');
    }
    catch { throw new Error('The local Helios viewer needs its bundled executable, GTK 4.8+, libepoxy and a desktop session. Install the GTK4 runtime or use Browser Display.'); }
    try { await execFile(binary(), ['--check-gl'], {timeout: 8000, env: desktopEnvironment()}); }
    catch (error) {
        const detail = (error as Error & {stderr?: string}).stderr?.trim() || (error as Error).message;
        throw new Error(`Local Desktop cannot create a host OpenGL 3.3 context: ${detail.slice(-1500)}`);
    }
    const { stdout } = await execFile('docker', ['image', 'inspect', '--format', `{{ index .Config.Labels "${HELIOS_DISPLAY_CAPABILITY}" }}`, HELIOS_IMAGE], { timeout: 5000 });
    if (stdout.trim() !== HELIOS_DISPLAY_VERSION) throw new Error('Rebuild the Helios host image to enable local display support.');
}

async function startBus(): Promise<void> {
    const runtimeDirectory = hostEnvironment().XDG_RUNTIME_DIR;
    if (runtimeDirectory) {
        const runtime = fs.lstatSync(runtimeDirectory);
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
        try { await execFile(binary(), ['--ping', heliosDisplayAddress(directory)], { timeout: 3000, env: desktopEnvironment() }); return; }
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
    await execFile('dbus-daemon', [`--config-file=${config}`, '--fork'], { timeout: 5000, env: desktopEnvironment() });
    await execFile(binary(), ['--ping', heliosDisplayAddress(directory)], { timeout: 3000, env: desktopEnvironment() });
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
    await viewer.open(onFailure);
}
function displayFailure(message: string): void {
    console.warn(`Local Helios display: ${message}`);
    localDisplayState.value = 'failed';
    localDisplayMessage.value = `${message} Retry Local Desktop, or disable Local desktop in Configuration and save to restart this VM with Browser Display. Windows data is preserved.`;
}

export function followLocalDisplay(enabled: boolean): void {
    viewer.setAutomatic(enabled, displayFailure);
}
export function closeLocalDisplay(): void { viewer.close(); }
export function openLocalDesktop(): Promise<void> {
    if (!openingConsole) openingConsole = (async () => {
        try { await launchLocalDisplay(displayFailure); }
        catch (error) { if (!(error instanceof Error && error.name === 'AbortError')) console.warn(`Local Desktop start: ${error}`); }
    })().finally(() => { openingConsole = undefined; });
    return openingConsole;
}
