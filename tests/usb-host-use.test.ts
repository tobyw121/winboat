import {test} from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs';import os from 'node:os';import path from 'node:path';
import {createRequire} from 'node:module';
(globalThis as any).require=createRequire(import.meta.url);
const {usbHostUse}=await import('../src/shared/usb-host-use');
test('USB input warning and mounted storage detection use exact device ancestry',()=>{
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'usb-use-'));
 try{
  const devices=path.join(root,'bus/usb/devices'),block=path.join(root,'class/block');fs.mkdirSync(devices,{recursive:true});fs.mkdirSync(block,{recursive:true});
  const device=path.join(devices,'1-2');fs.mkdirSync(device);fs.writeFileSync(path.join(device,'busnum'),'1');fs.writeFileSync(path.join(device,'devnum'),'7');
  const iface=path.join(devices,'1-2:1.0');fs.mkdirSync(iface);fs.writeFileSync(path.join(iface,'bInterfaceClass'),'03');
  const partition=path.join(device,'storage/sda1');fs.mkdirSync(partition,{recursive:true});fs.writeFileSync(path.join(partition,'dev'),'8:1');fs.symlinkSync(partition,path.join(block,'sda1'));
  const mounts=path.join(root,'mountinfo');fs.writeFileSync(mounts,'23 1 8:1 / /mnt rw - ext4 /dev/sda1 rw\n');
  assert.deepEqual(usbHostUse(1,7,root,mounts),{input:true,mounted:true,known:true});fs.writeFileSync(mounts,'');assert.equal(usbHostUse(1,7,root,mounts).mounted,false);
  assert.equal(usbHostUse(1,8,root,mounts).known,false);
 }finally{fs.rmSync(root,{recursive:true,force:true});}
});
