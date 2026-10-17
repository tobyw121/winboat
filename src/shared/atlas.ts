// Official, immutable release assets. No dependency on GitHub Actions artifacts.
export const ATLAS_RELEASE = '0.5.0-hotfix';
export const AME_RELEASE = '0.8.4';
export type AtlasMode = 'iso' | 'live';
export const ATLAS_IMAGE = `winboat/atlas:${ATLAS_RELEASE}`;
export const ATLAS_ISO_LABEL = 'org.winboat.atlas.iso';
export const ATLAS_ISO_VERSION = 'ame-oobe-v2';
export const AME_WIZARD_ASSET = { name: 'AME-Beta-v0.8.4.exe',
    sha256: 'a637f32b64e1493b315db9139065105656c84518dca20ce3b18c89750ee40c82',
    url: 'https://github.com/Ameliorated-LLC/trusted-uninstaller-cli/releases/download/0.8.4/AME-Beta-v0.8.4.exe' } as const;
export const ATLAS_OPTIONS = ['defender-enable', 'mitigations-default', 'auto-updates-default'] as const;
export const ATLAS_ASSETS = [
    { name: 'CLI-Standalone.zip', sha256: '70e4946b52c9384ca88730c0dd25646defc63affdef7acadd69cb6317f21825a',
        url: `https://github.com/Ameliorated-LLC/trusted-uninstaller-cli/releases/download/${AME_RELEASE}/CLI-Standalone.zip` },
    { name: 'AtlasPlaybook.apbx', sha256: '13c4d8e7fc0ed38c37c5942ebcabf7f636389972e6de391a192ae649967602d8',
        url: `https://github.com/Atlas-OS/Atlas/releases/download/${ATLAS_RELEASE}/AtlasPlaybook_v${ATLAS_RELEASE}.apbx` },
] as const;

export function validateAtlasSelection(enabled: boolean, version: string, iso?: string) {
    if (enabled && !((version === '11' && !iso) || (version === 'custom' && !!iso))) {
        throw new Error('Atlas requires Windows 11 Pro or a custom Windows ISO. Custom ISO edition/build compatibility is checked before applying Atlas.');
    }
}

export function configureAtlasIso<T extends { image?: string; pull_policy?: string; entrypoint?: string[]; environment: Record<string, string> }>(service: T, mode: AtlasMode = 'iso'): T {
    const result = JSON.parse(JSON.stringify(service)) as T;
    if (result.entrypoint && result.entrypoint.at(-1) !== '/oem/.winboat-hardware/entry.sh') {
        throw new Error('Atlas ISO injection cannot replace a custom container entrypoint.');
    }
    result.entrypoint = ['/usr/bin/tini', '-s', '--', '/bin/bash', '/oem/.winboat-atlas/entry.sh'];
    result.environment.WINBOAT_ATLAS_ISO = '1';
    result.environment.WINBOAT_ATLAS_MODE = mode;
    if (result.environment.HELIOS !== '1' && result.image) {
        result.image = ATLAS_IMAGE;
        result.pull_policy = 'never';
    }
    return result;
}

export type AtlasProgress = { status: string; message: string; release: string };
export function validateAtlasProgress(value: unknown): AtlasProgress {
    const p = value as Partial<AtlasProgress> | null;
    if (!p || typeof p.message !== 'string' || p.release !== ATLAS_RELEASE ||
        !['waiting', 'waiting-helios', 'running', 'awaiting-user', 'finished', 'failed'].includes(p.status || '')) {
        throw new Error('Invalid Atlas provisioning status. Update the Windows guest server.');
    }
    if (p.status === 'failed') throw new Error(`Atlas installation failed: ${p.message}`);
    return p as AtlasProgress;
}
