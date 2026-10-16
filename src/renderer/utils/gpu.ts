// Node 22+ in Electron and the test runner; avoids Vite's browser fs shim.
const fs = process.getBuiltinModule('fs');

const VIRGL_DEVICE_PREFIXES = [/^card\d+$/, /^renderD\d+$/];

export function checkVirglSupport(): boolean {
    try {
        if (!fs.existsSync('/dev/dri')) {
            return false;
        }

        const entries = fs.readdirSync('/dev/dri');
        return entries.some(entry => VIRGL_DEVICE_PREFIXES.some(prefix => prefix.test(entry)));
    } catch (error) {
        console.warn('[VirGL] Failed to inspect /dev/dri for VirGL support', error);
        return false;
    }
}

export function hasVirglDeviceMapping(devices: string[]): boolean {
    return devices.some(device => device.startsWith('/dev/dri'));
}

/** Availability only, not a claim of Vulkan/DirectX compatibility. */
export function checkHeliosSupport(): boolean {
    try {
        return process.arch === 'x64' && fs.readdirSync('/dev/dri').some(name => /^renderD\d+$/.test(name));
    } catch { return false; }
}
