import type { ComposeConfig } from '../../types';
import { configureSharedFolders, readSharedFolders, SHARE_CAPABILITY, SHARE_VERSION, sharedFolderErrors, type SharedFolder } from '../../shared/shared-folders';
import { WINBOAT_DIR } from './constants';
import {sharedFolderRuntimeMounts, removeSharedFolderRuntimeMounts} from '../../shared/shared-folder-runtime';
import {volumeTarget} from '../../shared/compose-volumes';
const fs: typeof import('fs') = require('fs');
const os: typeof import('os') = require('os');
const path: typeof import('path') = require('path');
const child: typeof import('child_process') = require('child_process');
const {promisify}: typeof import('util') = require('util');
const execFile = promisify(child.execFile);
export type ShareCheck = {name:string; ok:boolean; message:string; windowsPath?:string};
export function configuredSharedFolders(service: ComposeConfig['services']['windows']): SharedFolder[] {
    return readSharedFolders(service, os.homedir(), WINBOAT_DIR);
}
export async function prepareSharedFolders(service: ComposeConfig['services']['windows'], folders: SharedFolder[]): Promise<typeof service> {
    const errors = sharedFolderErrors(folders);
    if (errors.length) throw new Error(errors.join('\n'));
    const checked = folders.map(folder => {
        if (!folder.enabled) return {...folder};
        const hostPath = fs.realpathSync(folder.hostPath);
        if (!fs.statSync(hostPath).isDirectory()) throw new Error(`Not a directory: ${folder.hostPath}`);
        fs.accessSync(hostPath, fs.constants.R_OK | fs.constants.X_OK | (folder.readOnly ? 0 : fs.constants.W_OK));
        return {...folder,hostPath};
    });
    const next = configureSharedFolders(service, checked, process.getuid!(), process.getgid!());
    if (service['x-winboat-shared-folders']) next.volumes = removeSharedFolderRuntimeMounts(next.volumes, WINBOAT_DIR);
    if (checked.some(folder => folder.enabled)) {
        const {stdout} = await execFile('docker', ['image','inspect','--format',`{{ index .Config.Labels "${SHARE_CAPABILITY}" }}`,next.image], {timeout:5000});
        if (stdout.trim() !== SHARE_VERSION) throw new Error('Rebuild the host images with ./scripts/build-helios.sh to enable authenticated shared folders.');
        if (/^[Nn]/.test(next.environment.NETWORK || '')) throw new Error('Shared folders require the VM network to be enabled.');
        if (next.volumes.some(mount => ['/opt/winboat-shares','/run/samba.sh'].includes(volumeTarget(mount)))) {
            throw new Error('The shared-folder runtime paths are already mounted by a custom configuration.');
        }
        const {app}:typeof import('@electron/remote') = require('@electron/remote');
        const bundle = app.isPackaged ? path.join(process.resourcesPath,'shared-folders')
            : path.resolve(app.getAppPath(),'..','..','resources','shared-folders');
        next.volumes.push(...sharedFolderRuntimeMounts(WINBOAT_DIR,bundle));
    }
    return next;
}
export async function validateConfiguredShares(service: ComposeConfig['services']['windows']): Promise<void> {
    if (!service['x-winboat-shared-folders']) return;
    await prepareSharedFolders(service, configuredSharedFolders(service));
}
export async function checkSharedFolders(): Promise<ShareCheck[]> {
    const {stdout} = await execFile('docker', ['exec','WinBoat','python3','/opt/winboat-shares/manage.py','check'], {timeout:180000,maxBuffer:1024*1024});
    const results: unknown = JSON.parse(stdout);
    if (!Array.isArray(results) || results.some(result => typeof result?.name !== 'string' || typeof result?.ok !== 'boolean' || typeof result?.message !== 'string' || (result.windowsPath !== undefined && typeof result.windowsPath !== 'string'))) throw new Error('The shared folder service returned an invalid diagnostic response.');
    return results;
}
export async function selectSharedFolder(defaultPath?: string): Promise<string | undefined> {
    const {dialog}: typeof import('@electron/remote') = require('@electron/remote');
    const result = await dialog.showOpenDialog({title:'Choose a Linux folder to share',defaultPath:defaultPath || os.homedir(),properties:['openDirectory']});
    return result.canceled ? undefined : result.filePaths[0];
}
export function defaultShareName(hostPath: string, existing: SharedFolder[]): string {
    const base = path.basename(hostPath).replace(/[\\/:*?"<>|,$%\[\]\x00-\x1f]/g, '-').replace(/[. ]+$/g,'').trim().slice(0,55) || 'Files';
    let name = ['global','.','..'].includes(base.toLowerCase()) ? 'Files' : base;
    for (let index=2;existing.some(folder=>folder.name.toLowerCase() === name.toLowerCase());index++) name = `${base} ${index}`;
    return name;
}
