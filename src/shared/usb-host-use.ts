const fs:typeof import('fs')=require('fs');
const path:typeof import('path')=require('path');
/** Warn about keyboard/mouse capture and block actual mounted storage detachment. */
export function usbHostUse(bus:number,address:number,sys='/sys',mounts='/proc/self/mountinfo'):{input:boolean;mounted:boolean;known:boolean}{
 try{
  const directory=path.join(sys,'bus/usb/devices');
  const entry=fs.readdirSync(directory).find(name=>{
   try{return Number(fs.readFileSync(path.join(directory,name,'busnum'),'utf8'))===bus&&Number(fs.readFileSync(path.join(directory,name,'devnum'),'utf8'))===address;}catch{return false;}
  });
  if(!entry)return {input:false,mounted:false,known:false};
  const root=fs.realpathSync(path.join(directory,entry)),mountDevices=new Set(fs.readFileSync(mounts,'utf8').split('\n').map(line=>line.split(' ')[2]));
  const input=fs.readdirSync(directory).filter(name=>name.startsWith(entry+':')).some(name=>{try{return fs.readFileSync(path.join(directory,name,'bInterfaceClass'),'utf8').trim()==='03';}catch{return false;}});
  const mounted=fs.readdirSync(path.join(sys,'class/block')).some(name=>{
   const block=path.join(sys,'class/block',name);
   try{return fs.realpathSync(block).startsWith(root+'/')&&mountDevices.has(fs.readFileSync(path.join(block,'dev'),'utf8').trim());}catch{return false;}
  });return {input,mounted,known:true};
 }catch{return {input:false,mounted:false,known:false};}
}
