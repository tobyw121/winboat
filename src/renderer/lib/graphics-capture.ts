import { ref } from 'vue';
import { graphicsCapture } from '../../shared/graphics-capture';
import { nativeDesktopEnvironment } from '../../shared/native-desktop-environment';
import { hostEnvironment } from './host-environment';
import {HELIOS_RUNTIME_VERSION} from '../../shared/helios';
const remote: typeof import('@electron/remote') = require('@electron/remote');
const child: typeof import('child_process') = require('child_process');
const path: typeof import('path') = require('path');
const {promisify}: typeof import('util') = require('util');
export const captureRunning = ref(false);
export const captureMessage = ref('');
const capture = graphicsCapture(async () => {
    const script = remote.app.isPackaged ? path.join(process.resourcesPath,'graphics-tools','diagnose-graphics.py')
        : path.resolve(remote.app.getAppPath(),'../..','scripts/helios/diagnose-graphics.py');
    const result = await promisify(child.execFile)('python3',[script,'--samples','12','--interval','2','--expected-runtime',HELIOS_RUNTIME_VERSION],{
        timeout:240000,maxBuffer:2*1024*1024,
        env:nativeDesktopEnvironment(hostEnvironment(),remote.app.isPackaged?path.dirname(process.resourcesPath):undefined),
    });
    return result.stdout;
});
export async function captureGraphics(bundle=false):Promise<void> {
    if (captureRunning.value) return;
    captureRunning.value=true;captureMessage.value='Recording graphics status and existing logs. Leave the VM running…';
    try {
        const report=await capture();
        if(bundle) {
            const script=remote.app.isPackaged?path.join(process.resourcesPath,'graphics-tools','support-bundle.py')
                :path.resolve(remote.app.getAppPath(),'../..','scripts/helios/support-bundle.py');
            const run=promisify(child.execFile);
            const env=nativeDesktopEnvironment(hostEnvironment(),remote.app.isPackaged?path.dirname(process.resourcesPath):undefined);
            const {stdout}=await run('python3',[script,report],{timeout:15000,maxBuffer:2*1024*1024,env});
            const preview=JSON.parse(stdout);
            if(!/^[a-f0-9]{64}$/.test(preview.sha256) || typeof preview.preview!=='object') throw new Error('Invalid filtered preview.');
            const decision=await remote.dialog.showMessageBox({type:'question',title:'Save graphics support packet',
                message:'Save this filtered diagnostic packet locally? Nothing is uploaded.',
                detail:JSON.stringify(preview.preview,null,2),buttons:['Save ZIP','Cancel'],defaultId:1,cancelId:1});
            if(decision.response!==0){captureMessage.value=`Report saved: ${report}. ZIP cancelled.`;return;}
            const choice=await remote.dialog.showSaveDialog({title:'Save graphics support packet',defaultPath:report.replace(/\.json$/,'.support.zip'),filters:[{name:'ZIP archive',extensions:['zip']}]});
            if(choice.canceled || !choice.filePath){captureMessage.value=`Report saved: ${report}. ZIP cancelled.`;return;}
            await run('python3',[script,report,'--output',choice.filePath,'--review-sha256',preview.sha256],{timeout:15000,maxBuffer:65536,env});
            captureMessage.value=`Filtered ZIP saved: ${choice.filePath}`;remote.shell.showItemInFolder(choice.filePath);
        } else {captureMessage.value=`Report saved: ${report}`;remote.shell.showItemInFolder(report);}
    } catch(error) {captureMessage.value=`Capture failed: ${error instanceof Error?error.message:String(error)}. Python 3 and a running guest API are required.`;}
    finally {captureRunning.value=false;}
}
