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
        timeout:180000,maxBuffer:2*1024*1024,
        env:nativeDesktopEnvironment(hostEnvironment(),remote.app.isPackaged?path.dirname(process.resourcesPath):undefined),
    });
    return result.stdout;
});
export async function captureGraphics():Promise<void> {
    if (captureRunning.value) return;
    captureRunning.value=true;captureMessage.value='Recording graphics status and existing logs. Leave the VM running…';
    try {
        const report=await capture();captureMessage.value=`Report saved: ${report}`;
        remote.shell.showItemInFolder(report);
    } catch(error) {captureMessage.value=`Capture failed: ${error instanceof Error?error.message:String(error)}. Python 3 and a running guest API are required.`;}
    finally {captureRunning.value=false;}
}
