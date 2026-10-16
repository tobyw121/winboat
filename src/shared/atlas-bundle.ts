import { ATLAS_ASSETS, ATLAS_OPTIONS, ATLAS_RELEASE, AME_RELEASE, AME_WIZARD_ASSET, type AtlasMode } from './atlas';

// Inject Node services so the renderer and tests use the same staging code.
export async function stageAtlasBundle(fs: typeof import('fs'), path: typeof import('path'),
    digest: (data: Uint8Array) => string, target: string, username: string, helios: boolean,
    download: (url: string) => Promise<Buffer>, progress: (message: string) => void, mode: AtlasMode = 'iso',
    bundledPath?: string, password?: string) {
    if (!/^[a-zA-Z0-9]{2,}$/.test(username)) throw new Error('Invalid Windows username for Atlas provisioning.');
    if (mode === 'iso' && !password) throw new Error('AME OOBE requires the chosen Windows password.');
    fs.mkdirSync(target, { recursive: true });
    const assets = mode === 'iso' ? [ATLAS_ASSETS[1], AME_WIZARD_ASSET] : ATLAS_ASSETS;
    for (const asset of assets) {
        const file = path.join(target, asset.name);
        if (asset.name === 'AtlasPlaybook.apbx' && bundledPath) {
            const bundled = fs.readFileSync(path.join(bundledPath, asset.name));
            if (digest(bundled) !== asset.sha256) throw new Error('The bundled Atlas playbook is damaged. Rebuild WinBoat.');
            fs.writeFileSync(file, bundled, { mode: 0o600 });
            continue;
        }
        if (fs.existsSync(file) && digest(fs.readFileSync(file)) === asset.sha256) continue;
        progress(`Downloading ${asset.name} (${asset.name.endsWith('.apbx') ? ATLAS_RELEASE : AME_RELEASE})`);
        const data = await download(asset.url);
        if (digest(data) !== asset.sha256) throw new Error(`SHA-256 mismatch for ${asset.name}. Nothing will be executed.`);
        const temporary = `${file}.partial`;
        try {
            fs.writeFileSync(temporary, data, { mode: 0o600 });
            fs.renameSync(temporary, file);
        } finally { fs.rmSync(temporary, { force: true }); }
    }
    for (const asset of [...ATLAS_ASSETS, AME_WIZARD_ASSET]) {
        if (!assets.some(a => a.name === asset.name)) fs.rmSync(path.join(target, asset.name), { force: true });
    }
    const credentials = path.join(target, 'oobe-credentials.json');
    if (mode === 'iso') {
        fs.writeFileSync(credentials, JSON.stringify({ username, password }), { mode: 0o600 });
        fs.chmodSync(credentials, 0o600);
    } else fs.rmSync(credentials, { force: true });
    // Written last: partial downloads cannot become an enabled OEM installation.
    fs.writeFileSync(path.join(target, 'atlas.json'), JSON.stringify({ release: ATLAS_RELEASE,
        cliRelease: AME_RELEASE, mode, username, waitForHelios: helios,
        options: ATLAS_OPTIONS, assets }, null, 2));
}
