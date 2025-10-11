import * as fs from 'node:fs';

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
