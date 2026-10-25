import {inspectVmRecovery,stageVmRecovery,type VmRecovery,trySaveVmRecovery} from './vm-recovery';
const fs:typeof import('fs')=require('fs');
const path:typeof import('path')=require('path');
/** No shell, starts, removals or volume operations. Docker access is supplied by Electron. */
export async function importVmRecovery(preview:VmRecovery,destination:string,run:(args:string[])=>Promise<string>,prepare:(vm:VmRecovery)=>Promise<void>=async()=>{}):Promise<void>{
 // Re-read after consent: disks and mounts may have disappeared while the preview was open.
 const vm=inspectVmRecovery(preview.source);
 if(JSON.stringify(vm)!==JSON.stringify(preview))throw Error('The saved VM configuration changed. Select the folder again.');
 const names=(await run(['container','ls','-a','--format','{{.Names}}'])).trim().split('\n');
 const exists=names.includes('WinBoat');
 if(exists){
  const containers=JSON.parse(await run(['container','inspect','WinBoat']));
  const storage=containers[0].Mounts.find((m:{Destination:string})=>m.Destination==='/storage');
  if(!storage||storage.Type!=='bind'||fs.realpathSync(storage.Source)!==fs.realpathSync(vm.storage))throw Error('A different WinBoat container already exists. Import cannot replace it.');
 }else{
  try{await run(['image','inspect',vm.compose.services.windows.image]);}
  catch{throw Error('The saved Docker image is unavailable. Install/build this image first: '+vm.compose.services.windows.image);}
 }
 if(!exists)await prepare(vm);
 const transaction=stageVmRecovery(vm,destination);
 try{
  const file=path.join(destination,'docker-compose.yml');
  await run(['compose','-f',file,'config','--quiet']);
  if(!exists)await run(['compose','-f',file,'create','--no-recreate','--no-build','--pull','never']);
 }catch(error){transaction.rollback();throw error;}
 transaction.commit();trySaveVmRecovery(destination);
}
