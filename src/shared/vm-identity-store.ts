import { createVmIdentity, validateVmIdentity, vmIdentitySmbios, VM_IDENTITY_FILE, type VmIdentity } from './vm-identity';

/** Filesystem dependency is supplied by Electron or the Node test runner. */
export function loadOrCreateVmIdentity(fs: typeof import('fs'), directory: string, cpu: string): VmIdentity {
    const filename = `${directory.replace(/\/$/, '')}/${VM_IDENTITY_FILE}`;
    const stage = (identity: VmIdentity) => {
        const target = `${directory.replace(/\/$/, '')}/.winboat-hardware`;
        fs.mkdirSync(target, { recursive: true, mode: 0o700 });
        const stat = fs.lstatSync(target);
        if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('Invalid VM hardware directory.');
        for (const [name, bytes] of Object.entries(vmIdentitySmbios(identity))) {
            const path = `${target}/${name}`;
            if (fs.existsSync(path) && (!fs.lstatSync(path).isFile() || fs.lstatSync(path).isSymbolicLink())) {
                throw new Error('Invalid VM SMBIOS file.');
            }
            const file = fs.openSync(path, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_TRUNC | fs.constants.O_NOFOLLOW, 0o600);
            try { fs.writeFileSync(file, bytes); } finally { fs.closeSync(file); }
        }
        return identity;
    };
    const read = () => {
        const stat = fs.lstatSync(filename);
        if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 8192) throw new Error('Invalid VM hardware identity file.');
        return validateVmIdentity(JSON.parse(fs.readFileSync(filename, 'utf8')));
    };
    if (fs.existsSync(filename)) return stage(read());
    if (fs.readdirSync(directory).some(file => /^(?:data\d*|windows|system)\.(?:img|qcow2|raw|vhdx?)$/i.test(file))) {
        throw new Error('This folder already contains a Windows disk. Restore winboat-hardware.json or disable the new hardware profile.');
    }
    const dmi: Record<string, string> = {};
    for (const key of ['sys_vendor', 'product_name', 'product_version', 'board_vendor', 'board_name', 'board_version']) {
        try { dmi[key] = fs.readFileSync(`/sys/class/dmi/id/${key}`, 'utf8').trim(); } catch { /* Use an explicit preset if public DMI names are unavailable. */ }
    }
    const identity = createVmIdentity(dmi, cpu);
    try { fs.writeFileSync(filename, JSON.stringify(identity, null, 2) + '\n', { flag: 'wx', mode: 0o600 }); }
    catch (error) { if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error; }
    return stage(read());
}
