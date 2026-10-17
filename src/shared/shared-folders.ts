import type { ComposeVolume } from './compose-volumes';
import { volumeTarget, volumeSource, volumeReadOnly } from './compose-volumes';
import { ATLAS_IMAGE } from './atlas';
import { LEGACY_WINDOWS_IMAGE } from './helios';
export const SHARE_CAPABILITY = 'org.winboat.shared-folders';
export const SHARE_VERSION = 'authenticated-v1';
export const SHARE_ROOT = '/winboat-shares/';
export const SHARE_USER = 'winboat';
export type SharedFolder = { name: string; hostPath: string; enabled: boolean; readOnly: boolean };
export type SharedFolderService = {
    image: string; pull_policy?: string; volumes: ComposeVolume[];
    environment: Record<string, string>;
    'x-winboat-shared-folders'?: SharedFolder[];
};
const legacyNames: Record<string, string> = {'/shared': 'Data', '/shared2': 'Data2', '/shared3': 'Data3'};
export function sharedFolderErrors(folders: SharedFolder[]): string[] {
    const errors: string[] = [], names = new Set<string>();
    if (folders.length > 16) errors.push('A maximum of 16 shared folders is supported.');
    for (const folder of folders) {
        if (!folder.name || folder.name.length > 64 || /[\\/:*?"<>|,$%\[\]\x00-\x1f]/.test(folder.name) || /[. ]$/.test(folder.name) || folder.name !== folder.name.trim() || ['global','ipc$','admin$','.','..'].includes(folder.name.toLowerCase())) errors.push('Share names must be 1–64 characters without slashes, control characters, trailing spaces or reserved SMB names.');
        const key = folder.name.toLowerCase();
        if (names.has(key)) errors.push(`Duplicate share name: ${folder.name}`);
        names.add(key);
        if (!folder.hostPath.startsWith('/') || /[\x00-\x1f]/.test(folder.hostPath)) errors.push(`Choose an absolute Linux folder path for ${folder.name || 'each share'}.`);
    }
    return [...new Set(errors)];
}
export function sharePath(name: string): string { return `\\\\host.lan\\${name}`; }
export function readSharedFolders(service: SharedFolderService, home: string, base: string): SharedFolder[] {
    if (service['x-winboat-shared-folders']) return service['x-winboat-shared-folders'].map(folder=>({...folder,hostPath:folder.hostPath.replace(/\$\$/g,'$')}));
    const additional = (service.environment.SHARES || '').split(',');
    const folders: SharedFolder[] = [];
    for (const mount of service.volumes) {
        const target = volumeTarget(mount), source = volumeSource(mount);
        const name = legacyNames[target] || (target.startsWith(SHARE_ROOT) || additional.includes(target) ? target.split('/').at(-1) : undefined);
        if (!name || !source) continue;
        let hostPath = source.replace(/\$\$/g, '$');
        if (['${HOME}','$HOME'].includes(hostPath)) hostPath = home;
        else if (hostPath.startsWith('./') || hostPath.startsWith('../')) hostPath = `${base}/${hostPath}`;
        if (!hostPath.startsWith('/')) continue; // Preserve manually managed named volumes.
        folders.push({name, hostPath, enabled: !/^[Nn]/.test(service.environment.SAMBA || ''), readOnly: volumeReadOnly(mount)});
    }
    return folders;
}
export function configureSharedFolders<T extends SharedFolderService>(service: T, folders: SharedFolder[], uid: number, gid: number): T {
    const errors = sharedFolderErrors(folders);
    if (errors.length) throw new Error(errors.join('\n'));
    if (![uid,gid].every(id => Number.isSafeInteger(id) && id >= 0 && id <= 2147483647)) throw new Error('Invalid Linux share user or group.');
    const next = JSON.parse(JSON.stringify(service)) as T;
    const importedTargets = new Set((next.environment.SHARES || '').split(','));
    next.volumes = next.volumes.filter(mount => {
        const target = volumeTarget(mount), source = volumeSource(mount);
        const hostBind = typeof mount !== 'string' ? mount.type === 'bind' : !!source && /^(\/|\.\.?\/|\$\{?HOME)/.test(source);
        return !target.startsWith(SHARE_ROOT) && !(hostBind && (legacyNames[target] || importedTargets.has(target)));
    });
    next['x-winboat-shared-folders'] = folders.map(folder=>({...folder,hostPath:folder.hostPath.replace(/\$/g,()=> '$$')}));
    const active = folders.filter(folder => folder.enabled);
    if (active.length && (!next.environment.PASSWORD || /[\r\n\0]/.test(next.environment.PASSWORD))) throw new Error('Shared folders require a non-empty Windows password without line breaks.');
    next.environment.SAMBA = active.length ? 'Y' : 'N';
    next.environment.WINBOAT_SHARE_UID = String(uid);next.environment.WINBOAT_SHARE_GID = String(gid);
    next.environment.WINBOAT_SHARED_FOLDERS = JSON.stringify(active.map(folder => ({name:folder.name, path:SHARE_ROOT + folder.name, readOnly:folder.readOnly})));
    for (const folder of active) next.volumes.push({type:'bind', source:folder.hostPath.replace(/\$/g,()=> '$$'), target:SHARE_ROOT+folder.name, read_only:folder.readOnly, bind:{create_host_path:false}});
    if (active.length && next.image === LEGACY_WINDOWS_IMAGE) {next.image = ATLAS_IMAGE;next.pull_policy='never';}
    return next;
}
