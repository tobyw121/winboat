#!/usr/bin/env python3
"""Real FD-passed D-Bus peers and GStreamer; replaces only host audio devices."""
import importlib.util
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import gi
gi.require_version('Gst','1.0')
from gi.repository import Gio,GLib,Gst
ROOT=Path(__file__).resolve().parents[1]
s=importlib.util.spec_from_file_location('audio',ROOT/'native/helios-audio/audio.py');audio=importlib.util.module_from_spec(s);s.loader.exec_module(audio)
assert os.getuid()==0,'Fixture runs as root QEMU inside the disposable test container'
with tempfile.TemporaryDirectory() as temporary:
 address='unix:path='+temporary+'/bus'
 daemon=subprocess.Popen(['dbus-daemon','--session','--nofork','--address='+address],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
 for _ in range(100):
  if Path(temporary+'/bus').exists():break
  time.sleep(.01)
 bus=Gio.DBusConnection.new_for_address_sync(address,Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT|Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION,None,None)
 bus.call_sync('org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus','RequestName',GLib.Variant('(su)',('org.qemu',0)),None,Gio.DBusCallFlags.NONE,1000,None)
 xml='<node><interface name="org.qemu.Display1.Audio">'+''.join('<method name="Register'+d+'Listener"><arg type="h" direction="in"/></method>' for d in ('Out','In'))+'</interface></node>'
 node=Gio.DBusNodeInfo.new_for_xml(xml);peers={};errors=[];loop=GLib.MainLoop()
 def accept(direction,fd):
  try:
   stream=Gio.Socket.new_from_fd(fd).connection_factory_create_connection()
   peer=Gio.DBusConnection.new_sync(stream,Gio.dbus_generate_guid(),Gio.DBusConnectionFlags.AUTHENTICATION_SERVER,None,None)
   peers[direction]=peer
  except Exception as e:errors.append(e)
 def register(conn,sender,path,interface,name,parameters,invocation):
  fd=invocation.get_message().get_unix_fd_list().get(parameters.unpack()[0])
  invocation.return_value(None)
  threading.Thread(target=accept,args=('In' if name=='RegisterInListener' else 'Out',fd),daemon=True).start()
 bus.register_object('/org/qemu/Display1/Audio',node.interfaces[0],register,None,None)
 script="""import sys,runpy,gi
gi.require_version('Gst','1.0');from gi.repository import Gst
original=Gst.parse_launch
Gst.parse_launch=lambda text:original(text.replace('autoaudiosink sync=false','fakesink sync=false').replace('autoaudiosrc','audiotestsrc is-live=true'))
runpy.run_path(sys.argv.pop(1),run_name='__main__')
"""
 child=subprocess.Popen([sys.executable,'-c',script,str(ROOT/'native/helios-audio/audio.py'),'--address',address,'--microphone'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 started=time.monotonic();finished=False
 def tick():
  global finished
  try:
   if errors:raise errors[0]
   if child.poll() is not None:raise RuntimeError(child.stderr.read().decode())
   if time.monotonic()-started>15:raise TimeoutError('Audio FD registration timed out')
   if len(peers)!=2:return True
   for direction,peer in peers.items():
    target='/org/qemu/Display1/Audio'+direction+'Listener';iface='org.qemu.Display1.Audio'+direction+'Listener'
    def call(name,value):return peer.call_sync(None,target,iface,name,value,None,Gio.DBusCallFlags.NONE,2000,None)
    call('Init',GLib.Variant('(tybbuyuub)',(1,16,True,False,48000,2,4,192000,False)))
    call('SetVolume',GLib.Variant('(tbay)',(1,False,[255,255])))
    call('SetEnabled',GLib.Variant('(tb)',(1,True)))
    if direction=='Out':call('Write',GLib.Variant('(tay)',(1,bytes(1920))))
    else:
     result=call('Read',GLib.Variant('(tt)',(1,1920))).unpack()[0];assert len(result)<=1920
    call('SetEnabled',GLib.Variant('(tb)',(1,False)));call('Fini',GLib.Variant('(t)',(1,)))
   finished=True;loop.quit();return False
  except Exception as e:errors.append(e);loop.quit();return False
 GLib.timeout_add(100,tick)
 try:
  loop.run()
  if errors:raise errors[0]
  assert finished
  child.stdin.close();assert child.wait(timeout=5)==0,child.stderr.read().decode()
  print('Real D-Bus audio FD handshake, PCM playback/capture calls and parent-exit cleanup passed.')
 finally:
  child.kill() if child.poll() is None else None
  for peer in peers.values():
   if not peer.is_closed():peer.close_sync(None)
  bus.close_sync(None);daemon.terminate();daemon.wait(timeout=5)
