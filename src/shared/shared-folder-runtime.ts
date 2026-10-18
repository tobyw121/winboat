const fs: typeof import('fs') = require('fs');
const path: typeof import('path') = require('path');
const crypto: typeof import('crypto') = require('crypto');
import {volumeTarget, volumeSource, type ComposeVolume} from './compose-volumes';

// AppImage mounts disappear on exit. Keep versioned helper files beside the
// saved Compose file, so container restarts also work without the UI running.
export function sharedFolderRuntimeMounts(base: string, bundle: string): ComposeVolume[] {
    const names = ['manage.py', 'samba.sh'];
    const files = names.map(name => fs.readFileSync(path.join(bundle, name)));
    const hash = crypto.createHash('sha256');
    for (const bytes of files) hash.update(bytes);
    const directory = path.join(base, 'shared-folder-runtime', hash.digest('hex'));
    fs.mkdirSync(directory, {recursive:true, mode:0o700});
    names.forEach((name, index) => {
        const target = path.join(directory, name);
        try {fs.writeFileSync(target, files[index], {flag:'wx', mode:0o600});}
        catch (error) {
            if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error;
            if (!fs.readFileSync(target).equals(files[index])) throw new Error('Saved shared-folder helpers are damaged.');
        }
    });
    const bind = (source:string, target:string):ComposeVolume => ({type:'bind', source:source.replace(/\$/g,()=> '$$'), target, read_only:true, bind:{create_host_path:false}});
    return [bind(directory, '/opt/winboat-shares'), bind(path.join(directory,'samba.sh'), '/run/samba.sh')];
}

export function removeSharedFolderRuntimeMounts(volumes: ComposeVolume[], base:string): ComposeVolume[] {
    const prefix = path.join(base,'shared-folder-runtime')+path.sep;
    return volumes.filter(mount => !(['/opt/winboat-shares','/run/samba.sh'].includes(volumeTarget(mount)) &&
        volumeSource(mount)?.replace(/\$\$/g,'$').startsWith(prefix)));
}
