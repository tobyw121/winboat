"""Actual pinned qemu-img staging; exclusively temporary synthetic disk files."""
import importlib.util,json,os,subprocess,tempfile,sys
from pathlib import Path
s=importlib.util.spec_from_file_location('manager',Path(__file__).resolve().parents[1]/'scripts/helios/backup-manager.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
image=sys.argv[1] if len(sys.argv)>1 else 'winboat/helios:d82ce565ac79'
with tempfile.TemporaryDirectory(prefix='winboat-export-test-') as tmp:
 root=Path(tmp);key='b'*32;folder=root/key;folder.mkdir(mode=0o700)
 image_id=subprocess.check_output(['docker','image','inspect','--format','{{.Id}}',image],text=True).strip()
 subprocess.run(['docker','run','--rm','--network','none','--user',f'{os.getuid()}:{os.getgid()}','--mount',f'type=bind,src={folder},dst=/out','--entrypoint','/opt/helios/qemu/bin/qemu-img',image,'create','-q','-f','qcow2','/out/disk-0.qcow2','4M'],check=True)
 with (folder/'disk-0.qcow2').open('rb') as stream:sha=__import__('hashlib').file_digest(stream,'sha256').hexdigest()
 (folder/'status.json').write_text(json.dumps({'schema':1,'status':'completed','disks':[{'target':f'/backup/{key}/disk-0.qcow2','source':'/storage/windows.img','sourceFormat':'raw','bytes':4*1024*1024,'sha256':sha}]}))
 (root/(key+'.container.json')).write_text(json.dumps({'Image':image_id}))
 result=m.stage(root,key,root)
 assert result['status']=='staged-not-bootable' and result['bootBlocked']
 output=Path(result['directory'])/'windows.img';assert output.stat().st_size==4*1024*1024
 assert (folder/'disk-0.qcow2').exists()
 print('Actual qemu-img check, conversion and exact comparison passed; original export untouched. TPM/Windows not tested.')
