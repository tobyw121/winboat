import {type VmRecovery} from '../../shared/vm-recovery';
import {importVmRecovery} from '../../shared/vm-import';
import {resolveHeliosDisplay} from '../../shared/helios-display';
import {prepareLocalDisplay,localDisplayDirectory} from './helios-display';
import {WINBOAT_DIR} from './constants';
const {execFile}:typeof import('child_process')=require('child_process');
const execute=require('util').promisify(execFile);
export async function importExistingVm(preview:VmRecovery):Promise<void>{
 await importVmRecovery(preview,WINBOAT_DIR,async args=>{
  const {stdout}=await execute('docker',args,{timeout:120000,maxBuffer:2*1024*1024});return stdout;
 },async vm=>{
  const preferred=vm.preferences.localDisplayPreferred??vm.compose.services.windows.environment.HELIOS_DISPLAY==='dbus';
  vm.preferences.localDisplayPreferred=preferred;
  const display=await resolveHeliosDisplay(vm.compose.services.windows,preferred===true,localDisplayDirectory,
   service=>prepareLocalDisplay({...vm.compose,services:{windows:service}}));
  vm.compose.services.windows=display.service;
 });
}
