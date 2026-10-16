import { HELIOS_REVISION, HELIOS_GUEST_REVISION, HELIOS_IMAGE, HELIOS_LABEL, HELIOS_RUNTIME_LABEL, HELIOS_RUNTIME_VERSION } from '../../shared/helios';
const fs: typeof import('fs') = require('fs');
const path: typeof import('path') = require('path');
const crypto: typeof import('crypto') = require('crypto');
const { execFile }: typeof import('child_process') = require('child_process');
const os: typeof import('os') = require('os');
const { promisify }: typeof import('util') = require('util');
const remote: typeof import('@electron/remote') = require('@electron/remote');

export function heliosBundlePath(): string {
    return remote.app.isPackaged ? path.join(process.resourcesPath, 'helios')
        : path.resolve(remote.app.getAppPath(), '..', '..', 'resources', 'helios');
}

export function getHeliosHost(): { renderNode: string; nvidia: boolean } {
    const requested = process.env.WINBOAT_HELIOS_RENDER_NODE;
    if (requested && !/^\/dev\/dri\/renderD\d+$/.test(requested)) throw new Error('Invalid WINBOAT_HELIOS_RENDER_NODE.');
    const nodes = requested ? [path.basename(requested)] : fs.existsSync('/dev/dri') ? fs.readdirSync('/dev/dri').filter(name => /^renderD\d+$/.test(name)).sort() : [];
    for (const name of nodes) {
        const renderNode = path.join('/dev/dri', name);
        try {
            if (!fs.statSync(renderNode).isCharacterDevice()) continue;
            fs.accessSync(renderNode, fs.constants.R_OK | fs.constants.W_OK);
            const vendorPath = `/sys/class/drm/${name}/device/vendor`;
            const vendor = fs.existsSync(vendorPath) ? fs.readFileSync(vendorPath, 'utf8').trim() : '';
            return { renderNode, nvidia: vendor === '0x10de' };
        } catch { /* Try the next accessible render node. */ }
    }
    throw new Error('Helios needs an accessible GPU render node under /dev/dri. Check the GPU driver and render-group permissions.');
}

export async function requireHelios(): Promise<{ renderNode: string; nvidia: boolean }> {
    if (process.arch !== 'x64') throw new Error('This Helios stack supports Linux x86_64 hosts and Windows x64 guests.');
    const [major, minor] = os.release().split('.').map(Number);
    if (major < 6 || (major === 6 && minor < 13)) throw new Error('Helios requires Linux kernel 6.13 or newer.');
    const host = getHeliosHost();
    try {
        const { stdout } = await promisify(execFile)('vulkaninfo', ['--summary'], { timeout: 15000 });
        const versions = [...stdout.matchAll(/apiVersion\s*=\s*(\d+)\.(\d+)/g)];
        if (!versions.some(match => Number(match[1]) > 1 || (Number(match[1]) === 1 && Number(match[2]) >= 3))) throw new Error('No Vulkan 1.3 device found.');
    } catch (error) {
        throw new Error(`Helios requires a working Vulkan 1.3 GPU. Install vulkan-tools and a compatible graphics driver. ${error}`);
    }
    const directory = heliosBundlePath();
    let receipt: { revision: string; sha256: string };
    try {
        receipt = JSON.parse(fs.readFileSync(path.join(directory, 'helios-build.json'), 'utf8'));
        const exe = fs.readFileSync(path.join(directory, 'HeliosSetup.exe'));
        if (receipt.revision !== HELIOS_GUEST_REVISION || crypto.createHash('sha256').update(exe).digest('hex') !== receipt.sha256
            || exe.subarray(-8).toString('ascii') !== 'HLIOSET2') throw new Error('Bundle identity or checksum mismatch.');
    } catch (error) {
        throw new Error(`The matching Helios Windows installer is missing or damaged. Build and stage it with npm run helios:stage. ${error}`);
    }
    try {
        const { stdout } = await promisify(execFile)('docker', ['image', 'inspect', '--format', `{{ index .Config.Labels "${HELIOS_LABEL}" }}`, HELIOS_IMAGE]);
        if (stdout.trim() !== HELIOS_REVISION) throw new Error('Image revision mismatch.');
        const { stdout: runtime } = await promisify(execFile)('docker', ['image', 'inspect', '--format', `{{ index .Config.Labels "${HELIOS_RUNTIME_LABEL}" }}`, HELIOS_IMAGE]);
        if (runtime.trim() !== HELIOS_RUNTIME_VERSION) throw new Error('Image lacks the current Helios runtime and installation display.');
    } catch (error) {
        throw new Error(`Build the matching Helios host image with npm run build:helios:host. ${error}`);
    }
    if (host.nvidia) {
        const { stdout } = await promisify(execFile)('docker', ['info', '--format', '{{json .Runtimes}}']);
        if (!Object.prototype.hasOwnProperty.call(JSON.parse(stdout), 'nvidia')) {
            throw new Error('Install and configure NVIDIA Container Toolkit before enabling Helios on this GPU.');
        }
    }
    return host;
}
