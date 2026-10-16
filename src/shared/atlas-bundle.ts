import { ATLAS_ASSETS, ATLAS_OPTIONS, ATLAS_RELEASE, AME_RELEASE, type AtlasMode } from './atlas';

// Inject Node services so the renderer and tests use the same staging code.
export async function stageAtlasBundle(fs: typeof import('fs'), path: typeof import('path'),
    digest: (data: Uint8Array) => string, target: string, username: string, helios: boolean,
    download: (url: string) => Promise<Buffer>, progress: (message: string) => void, mode: AtlasMode = 'iso') {
    if (!/^[a-zA-Z0-9]{2,}$/.test(username)) throw new Error('Invalid Windows username for Atlas provisioning.');
    fs.mkdirSync(target, { recursive: true });
    for (const asset of ATLAS_ASSETS) {
        const file = path.join(target, asset.name);
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
    // Written last: partial downloads cannot become an enabled OEM installation.
    fs.writeFileSync(path.join(target, 'atlas.json'), JSON.stringify({ release: ATLAS_RELEASE,
        cliRelease: AME_RELEASE, mode, username, waitForHelios: helios,
        options: ATLAS_OPTIONS, assets: ATLAS_ASSETS }, null, 2));
}
