import { GUEST_API_PORT } from './constants';
import { skipWhileRunning } from '../utils/interval';
import { hostEnvironment } from './host-environment';
import { nativeDesktopEnvironment } from '../../shared/native-desktop-environment';
import { selectHeliosGLAPI, type HeliosGLAPI } from '../../shared/helios-gl';
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
let adapterTimer: ReturnType<typeof setInterval> | undefined;
let adapterGeneration=0;
let adapterAPIPort:number|undefined;
let lastFallback=-Infinity;
let viewerUnavailable=false;
let graphicsAPI: HeliosGLAPI = 'gl';
const viewer = new HeliosViewer(() => child.spawn(binary(), ['--address', heliosDisplayAddress(localDisplayDirectory()), '--control-stdin'],
    { env: desktopEnvironment(), stdio: ['pipe', 'pipe', 'pipe'] }), (state, message) => {
    localDisplayState.value = state; localDisplayMessage.value = message;
    if (state==='closed' || state==='failed') reportViewerAvailability(false);
},10000,1000,reportViewerAvailability);

function reportViewerAvailability(unavailable:boolean):void {
    viewerUnavailable=unavailable;
    if (adapterAPIPort===undefined) return;
    const now=performance.now();
    if (unavailable && now-lastFallback<5000) return;
    lastFallback=unavailable ? now : -Infinity;
    const nodeFetch: typeof import('node-fetch').default = require('node-fetch');
    void nodeFetch(`http://127.0.0.1:${adapterAPIPort}/graphics/adapters/recovery`,{
        method:'POST',timeout:3000,headers:{'X-WinBoat-Recovery':unavailable?'display-fallback':'display-ready'},
    }).then(response=>{if(!response.ok) console.warn(`Display recovery hint rejected: ${response.status}`);})
      .catch(()=>{}); // Guest API can be offline during installation/reboot.
}
function desktopEnvironment(api: HeliosGLAPI = graphicsAPI): NodeJS.ProcessEnv {
    return {...nativeDesktopEnvironment(hostEnvironment(), remote.app.isPackaged ? path.dirname(process.resourcesPath) : undefined),
        WINBOAT_HELIOS_GL_API: api};
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
        if (stdout.trim() !== 'winboat-helios-viewer 10') throw new Error('Viewer protocol mismatch.');
    }
    catch { throw new Error('The local Helios viewer needs its bundled executable, GTK 4.8+, libepoxy and a desktop session. Install the GTK4 runtime or use Browser Display.'); }
    try {
        graphicsAPI = await selectHeliosGLAPI(async api => {
            const {stdout} = await execFile(binary(), ['--check-gl'], {timeout: 8000, env: desktopEnvironment(api)});
            console.info(`Local Desktop ${api} probe: ${stdout.trim()}`);return stdout;
        });
    }
    catch (error) {
        const detail = (error as Error & {stderr?: string}).stderr?.trim() || (error as Error).message;
        throw new Error(`Local Desktop cannot initialize host OpenGL 3.3 or OpenGL ES 3.0: ${detail.slice(-1500)}`);
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

export function followLocalDisplay(enabled: boolean, apiPort = GUEST_API_PORT): void {
    if (adapterTimer) {clearInterval(adapterTimer);adapterTimer=undefined;}
    adapterAPIPort=enabled ? apiPort : undefined;lastFallback=-Infinity;viewerUnavailable=false;
    const generation=++adapterGeneration;
    viewer.updateAdapters(null);
    if (enabled) {
        const nodeFetch: typeof import('node-fetch').default = require('node-fetch');
        const poll = skipWhileRunning(async () => {
            if (viewerUnavailable) reportViewerAvailability(true);
            try {
                const response=await nodeFetch(`http://127.0.0.1:${apiPort}/graphics/adapters`,{timeout:3000});
                const state=response.ok ? await response.json() : null;
                if (generation===adapterGeneration) viewer.updateAdapters(state);
            } catch {if (generation===adapterGeneration) viewer.updateAdapters(null);}
        });
        void poll();adapterTimer=setInterval(poll,2000);
    }
    viewer.setAutomatic(enabled, displayFailure);
}
export function closeLocalDisplay(): void { followLocalDisplay(false); }
export function openLocalDesktop(): Promise<void> {
    if (!openingConsole) openingConsole = (async () => {
        try { await launchLocalDisplay(displayFailure); }
        catch (error) { if (!(error instanceof Error && error.name === 'AbortError')) console.warn(`Local Desktop start: ${error}`); }
    })().finally(() => { openingConsole = undefined; });
    return openingConsole;
}
