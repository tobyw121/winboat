#!/usr/bin/env python3
"""Local, authenticated QEMU D-Bus audio. Recording requires --microphone."""
import argparse
import json
import signal
import socket
import sys

MAX_CHUNK=262144

def pcm(bits,signed,floating,frequency,channels,frame,rate,big_endian):
    if bits not in (8,16,32) or not 8000<=frequency<=192000 or not 1<=channels<=8 or (floating and bits!=32):raise ValueError('Unsupported PCM format')
    if frame!=bits//8*channels or rate!=frame*frequency:raise ValueError('Inconsistent PCM frame size')
    return ('F' if floating else 'S' if signed else 'U')+str(bits)+(('BE' if big_endian else 'LE') if bits>8 else '')

def xml(direction):
    init=''.join('<arg type="'+t+'" direction="in"/>' for t in ('t','y','b','b','u','y','u','u','b'))
    return '<node><interface name="org.qemu.Display1.Audio'+direction+'Listener"><method name="Init">'+init+'</method><method name="Fini"><arg type="t" direction="in"/></method><method name="SetEnabled"><arg type="t" direction="in"/><arg type="b" direction="in"/></method><method name="SetVolume"><arg type="t" direction="in"/><arg type="b" direction="in"/><arg type="ay" direction="in"/></method>'+('<method name="Write"><arg type="t" direction="in"/><arg type="ay" direction="in"/></method>' if direction=='Out' else '<method name="Read"><arg type="t" direction="in"/><arg type="t" direction="in"/><arg type="ay" direction="out"/></method>')+'<property name="Interfaces" type="as" access="read"/></interface></node>'

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--check',action='store_true');p.add_argument('--address');p.add_argument('--microphone',action='store_true');a=p.parse_args()
    try:
        import gi
        gi.require_version('Gst','1.0');from gi.repository import Gio,GLib,Gst
        Gst.init(None)
        required=['appsrc','appsink','audioconvert','audioresample','volume','autoaudiosink']+(['autoaudiosrc'] if a.microphone else [])
        missing=[name for name in required if not Gst.ElementFactory.find(name)]
        if missing:raise ValueError('Missing GStreamer components: '+', '.join(missing))
        if a.check:print(json.dumps({'available':True,'microphone':a.microphone}));return
        if not a.address or not a.address.startswith('unix:path='):raise ValueError('Private local display bus required')
        bus=Gio.DBusConnection.new_for_address_sync(a.address,Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT|Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION,None,None)
        owner=bus.call_sync('org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus','GetConnectionUnixUser',GLib.Variant('(s)',('org.qemu',)),GLib.VariantType.new('(u)'),Gio.DBusCallFlags.NONE,3000,None).unpack()[0]
        # The private bus policy grants ownership of org.qemu only to QEMU/root.
        if owner!=0:raise ValueError('Authenticated root QEMU owner required')
        loop=GLib.MainLoop();voices={};connections=[];failure=[]
        def close():
            for voice in list(voices.values()):voice['pipe'].set_state(Gst.State.NULL)
            voices.clear();loop.quit()
        bus.connect('closed',lambda *_:close())
        # Parent pipe closure must stop playback and microphone capture immediately.
        GLib.io_add_watch(sys.stdin.fileno(),GLib.IO_HUP|GLib.IO_ERR,lambda *_:(close(),False)[1])
        def audio_error(bus,message):
            failure.append('Host audio pipeline failed; check the selected Linux audio device.')
            close()

        def method(conn,sender,path,interface,name,parameters,invocation):
            values=parameters.unpack();key=(interface,values[0]);voice=voices.get(key);capture='AudioInListener' in interface
            try:
                if name=='Init':
                    if key in voices:voices.pop(key)['pipe'].set_state(Gst.State.NULL)
                    if len(voices)>=8:raise ValueError('Audio stream limit reached')
                    _,bits,signed,floating,freq,channels,frame,rate,big=values
                    form=pcm(bits,signed,floating,freq,channels,frame,rate,big)
                    caps=f'audio/x-raw,format={form},layout=interleaved,rate={freq},channels={channels}'
                    if capture:
                        pipeline=Gst.parse_launch('autoaudiosrc ! audioconvert ! audioresample ! '+caps+' ! volume name=volume ! appsink name=endpoint max-buffers=4 drop=true sync=false')
                    else:
                        pipeline=Gst.parse_launch('appsrc name=endpoint is-live=true do-timestamp=true format=time block=false ! queue max-size-buffers=8 max-size-bytes=262144 max-size-time=100000000 leaky=downstream ! audioconvert ! audioresample ! volume name=volume ! autoaudiosink sync=false')
                        pipeline.get_by_name('endpoint').set_property('caps',Gst.Caps.from_string(caps))
                    pipeline.get_bus().add_signal_watch();pipeline.get_bus().connect('message::error',audio_error)
                    voices[key]={'pipe':pipeline,'endpoint':pipeline.get_by_name('endpoint'),'enabled':False,'frame':frame,'bytes':bytearray()}
                elif name=='Fini':
                    if voice:voice['pipe'].set_state(Gst.State.NULL);voices.pop(key)
                elif voice is None:raise ValueError('Unknown audio stream')
                elif name=='SetEnabled':
                    voice['enabled']=values[1];voice['bytes'].clear()
                    result=voice['pipe'].set_state(Gst.State.PLAYING if values[1] else Gst.State.NULL)
                    if result==Gst.StateChangeReturn.FAILURE:raise ValueError('Host audio device unavailable')
                elif name=='SetVolume':
                    _,mute,volume=values
                    if len(volume)>8:raise ValueError('Invalid channel volume')
                    control=voice['pipe'].get_by_name('volume');control.set_property('mute',mute)
                    control.set_property('volume',sum(volume)/len(volume)/255 if volume else 1.0)
                elif name=='Write':
                    data=bytes(values[1])
                    if len(data)>MAX_CHUNK or len(data)%voice['frame']:raise ValueError('Invalid PCM chunk')
                    if voice['enabled'] and voice['endpoint'].get_property('current-level-bytes')<=MAX_CHUNK:
                        buffer=Gst.Buffer.new_wrapped(data);voice['endpoint'].emit('push-buffer',buffer)
                elif name=='Read':
                    size=values[1]
                    if size>MAX_CHUNK or size%voice['frame']:raise ValueError('Invalid recording size')
                    if voice['enabled']:
                        sample=voice['endpoint'].emit('try-pull-sample',0)
                        if sample:
                            buffer=sample.get_buffer();data=buffer.extract_dup(0,min(buffer.get_size(),MAX_CHUNK))
                            if len(voice['bytes'])+len(data)<=MAX_CHUNK:voice['bytes'].extend(data)
                    data=bytes(voice['bytes'][:size]);del voice['bytes'][:len(data)]
                    invocation.return_value(GLib.Variant('(ay)',(data,)));return
                else:raise ValueError('Unsupported audio operation')
                invocation.return_value(None)
            except (ValueError,GLib.Error) as e:invocation.return_dbus_error('org.winboat.Audio.Error',str(e))
        def register(direction):
            left,right=socket.socketpair();fds=Gio.UnixFDList.new();handle=fds.append(right.fileno())
            try:
                bus.call_with_unix_fd_list_sync('org.qemu','/org/qemu/Display1/Audio','org.qemu.Display1.Audio','Register'+direction+'Listener',GLib.Variant('(h)',(handle,)),None,Gio.DBusCallFlags.NONE,5000,fds,None)
                stream=Gio.Socket.new_from_fd(left.detach()).connection_factory_create_connection()
                auth=Gio.DBusAuthObserver.new();auth.connect('allow-mechanism',lambda _,mechanism:mechanism=='EXTERNAL')
                peer=Gio.DBusConnection.new_sync(stream,None,Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT|Gio.DBusConnectionFlags.DELAY_MESSAGE_PROCESSING,auth,None)
                node=Gio.DBusNodeInfo.new_for_xml(xml(direction));peer.register_object('/org/qemu/Display1/Audio'+direction+'Listener',node.interfaces[0],method,lambda *_:GLib.Variant('as',[]),None)
                peer.connect('closed',lambda *_:close());peer.start_message_processing();connections.append(peer)
            finally:left.close();right.close()
        register('Out')
        if a.microphone:register('In')
        for sig in (signal.SIGINT,signal.SIGTERM):GLib.unix_signal_add(GLib.PRIORITY_DEFAULT,sig,lambda:(close(),False)[1])
        print(json.dumps({'state':'connected','microphone':a.microphone}),flush=True)
        try:loop.run()
        finally:
            close()
            for connection in connections:
                if not connection.is_closed():connection.close_sync(None)
        if failure:raise ValueError(failure[0])
    except Exception as e:p.exit(1,str(e)+'\n')
if __name__=='__main__':main()
