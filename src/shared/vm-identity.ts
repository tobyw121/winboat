export const VM_IDENTITY_FILE = 'winboat-hardware.json';
export type VmIdentity = {
    version: 1; source: 'host-dmi' | 'preset'; uuid: string;
    systemManufacturer: string; systemProduct: string; systemVersion: string;
    boardManufacturer: string; boardProduct: string; boardVersion: string;
    systemSerial: string; boardSerial: string; chassisSerial: string;
};

function usable(value?: string): string | undefined {
    const text = value?.trim();
    if (!text || !/^[\x20-\x7e]{1,64}$/.test(text) ||
        /qemu|kvm|vmware|virtual|bochs|xen|parallels|amazon ec2/i.test(text) ||
        /^(default string|system product name|system manufacturer|to be filled.*|not specified|unknown|none)$/i.test(text)) return;
    return text;
}

/** Public manufacturer/model data only; never copy the host's serials or UUID. */
export function createVmIdentity(dmi: Record<string, string>, cpu: string): VmIdentity {
    const boardManufacturer = usable(dmi.board_vendor);
    const boardProduct = usable(dmi.board_name);
    const fromHost = !!(boardManufacturer && boardProduct);
    const manufacturer = fromHost ? boardManufacturer! : 'ASUSTeK COMPUTER INC.';
    const product = fromHost ? boardProduct! : /AMD|Ryzen/i.test(cpu) ? 'PRIME B450-PLUS' : 'PRIME B660-PLUS D4';
    const serial = () => Array.from(crypto.getRandomValues(new Uint8Array(10)), byte => byte.toString(16).padStart(2, '0')).join('').toUpperCase();
    return {
        version: 1, source: fromHost ? 'host-dmi' : 'preset', uuid: crypto.randomUUID(),
        systemManufacturer: fromHost ? usable(dmi.sys_vendor) || manufacturer : manufacturer,
        systemProduct: fromHost ? usable(dmi.product_name) || product : product,
        systemVersion: fromHost ? usable(dmi.product_version) || '1.0' : '1.0',
        boardManufacturer: manufacturer, boardProduct: product,
        boardVersion: fromHost ? usable(dmi.board_version) || '1.0' : '1.0',
        systemSerial: serial(), boardSerial: serial(), chassisSerial: serial(),
    };
}

export function validateVmIdentity(value: unknown): VmIdentity {
    const identity = value as VmIdentity;
    if (!identity || identity.version !== 1 || !['host-dmi', 'preset'].includes(identity.source) ||
        typeof identity.uuid !== 'string' || !/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/i.test(identity.uuid)) {
        throw new Error('Invalid saved VM hardware identity. Restore its backup instead of generating a new identity for this disk.');
    }
    for (const key of ['systemManufacturer', 'systemProduct', 'systemVersion', 'boardManufacturer', 'boardProduct', 'boardVersion'] as const) {
        if (typeof identity[key] !== 'string' || !/^[\x20-\x7e]{1,64}$/.test(identity[key])) throw new Error(`Invalid VM hardware field: ${key}.`);
    }
    for (const key of ['systemSerial', 'boardSerial', 'chassisSerial'] as const) {
        if (typeof identity[key] !== 'string' || !/^[A-Z0-9]{12,32}$/.test(identity[key])) throw new Error(`Invalid VM serial: ${key}.`);
    }
    return identity;
}

function entry(type: number, handle: number, formatted: number[], strings: string[]): Uint8Array {
    const text = new TextEncoder().encode(strings.join('\0') + '\0\0');
    return new Uint8Array([type, formatted.length + 4, handle & 255, handle >> 8, ...formatted, ...text]);
}

/** Separate SMBIOS entries preserve spaces without shell quoting or eval. */
export function vmIdentitySmbios(value: VmIdentity): Record<string, Uint8Array> {
    const p = validateVmIdentity(value);
    const uuid = p.uuid.replaceAll('-', '').match(/../g)!.map(byte => parseInt(byte, 16));
    // SMBIOS 2.6+ uses little-endian encoding for the first three UUID fields.
    const uuidBytes = [...uuid.slice(0, 4).reverse(), ...uuid.slice(4, 6).reverse(), ...uuid.slice(6, 8).reverse(), ...uuid.slice(8)];
    return {
        'system.bin': entry(1, 0x100, [1, 2, 3, 4, ...uuidBytes, 6, 5, 6],
            [p.systemManufacturer, p.systemProduct, p.systemVersion, p.systemSerial, 'Desktop', 'Desktop']),
        'baseboard.bin': entry(2, 0x200, [1, 2, 3, 4, 5, 1, 0, 0, 3, 10, 0],
            [p.boardManufacturer, p.boardProduct, p.boardVersion, p.boardSerial, 'Desktop']),
        'chassis.bin': entry(3, 0x300, [1, 3, 2, 3, 4, 3, 3, 3, 3, 0, 0, 0, 0, 0, 1, 0, 0],
            [p.systemManufacturer, '1.0', p.chassisSerial, 'Desktop']),
    };
}

export function configureVmIdentity<T extends { environment: Record<string, string>; entrypoint?: string[] }>(service: T, value: VmIdentity, reduceCpuMarkers: boolean): T {
    const p = validateVmIdentity(value);
    const next = JSON.parse(JSON.stringify(service)) as T;
    const entrypoint = ['/usr/bin/tini', '-s', '--', '/bin/bash', '/oem/.winboat-hardware/entry.sh'];
    if (next.entrypoint && JSON.stringify(next.entrypoint) !== JSON.stringify(entrypoint)) throw new Error('Existing container entrypoint conflicts with the VM hardware profile.');
    if (next.environment.SM_BIOS) throw new Error('Existing SMBIOS arguments conflict with the VM hardware profile.');
    if (next.environment.UUID && next.environment.UUID !== p.uuid) throw new Error('Existing VM UUID conflicts with its saved hardware profile.');
    next.entrypoint = entrypoint;
    next.environment.WINBOAT_HARDWARE_PROFILE = '1';
    next.environment.UUID = p.uuid;
    if (reduceCpuMarkers) {
        const flags = (next.environment.CPU_FLAGS || '').split(',').filter(Boolean).filter(flag =>
            !/^(?:[+-]?(?:kvm|hypervisor)(?:=|$)|[+-]?hv[-_])/.test(flag));
        // dockur adds +hypervisor; use its matching +/- feature syntax because
        // QEMU can otherwise let +hypervisor override hypervisor=off.
        next.environment.CPU_FLAGS = [...flags, 'kvm=off', '-hypervisor'].join(',');
        next.environment.HV = 'N'; // Keep KVM acceleration; omit Hyper-V enlightenments.
    }
    return next;
}
