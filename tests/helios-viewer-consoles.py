#!/usr/bin/env python3
"""Real GTK viewer/D-Bus handoff with synthetic VGA and virtio head-0 frames.

No Windows, KVM, physical GPU, or anonymous listener authentication is used.
"""
import json
import ctypes
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time

import gi
gi.require_version('Gio', '2.0')
from gi.repository import Gio, GLib

PREFIX = 'org.qemu.Display1.'
CONSOLE = '/org/qemu/Display1/Console_'
LISTENER = '/org/qemu/Display1/Listener'
XML = '''<node>
<interface name="org.qemu.Display1.VM"><property name="ConsoleIDs" type="au" access="read"/></interface>
<interface name="org.qemu.Display1.Console">
<method name="RegisterListenerReverse"><arg type="h" direction="out"/></method>
<method name="SetUIInfo"><arg type="q" direction="in"/><arg type="q" direction="in"/><arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="u" direction="in"/><arg type="u" direction="in"/></method>
<property name="Type" type="s" access="read"/><property name="Head" type="u" access="read"/>
<property name="Label" type="s" access="read"/><property name="Width" type="u" access="read"/><property name="Height" type="u" access="read"/>
</interface>
<interface name="org.qemu.Display1.Mouse"><property name="IsAbsolute" type="b" access="read"/></interface>
</node>'''


def visible_frame():
    """Inspect the Xvfb screen, independently of the viewer's GL readback."""
    x11 = ctypes.CDLL('libX11.so.6')
    pointer = ctypes.c_void_p
    x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x11.XOpenDisplay.restype = pointer
    for name in ['XDefaultScreen', 'XDefaultRootWindow', 'XDisplayWidth', 'XDisplayHeight']:
        getattr(x11, name).argtypes = [pointer] if name in ['XDefaultScreen', 'XDefaultRootWindow'] else [pointer, ctypes.c_int]
    x11.XDefaultRootWindow.restype = ctypes.c_ulong
    x11.XGetImage.argtypes = [pointer, ctypes.c_ulong, ctypes.c_int, ctypes.c_int, ctypes.c_uint, ctypes.c_uint, ctypes.c_ulong, ctypes.c_int]
    x11.XGetImage.restype = pointer
    x11.XGetPixel.argtypes = [pointer, ctypes.c_int, ctypes.c_int]
    x11.XGetPixel.restype = ctypes.c_ulong
    x11.XDestroyImage.argtypes = [pointer]
    x11.XCloseDisplay.argtypes = [pointer]
    display = x11.XOpenDisplay(None)
    assert display, 'Cannot inspect the actual X11 display'
    screen = x11.XDefaultScreen(display)
    width, height = x11.XDisplayWidth(display, screen), x11.XDisplayHeight(display, screen)
    image = x11.XGetImage(display, x11.XDefaultRootWindow(display), 0, 0, width, height, ctypes.c_ulong(-1).value, 2)
    assert image, 'No X11 screen image'
    try:
        points = {color: [] for color in [0xff0000, 0x00ff00, 0x0000ff, 0xffff00]}
        for y in range(0, height, 4):
            for x in range(0, width, 4):
                color = x11.XGetPixel(image, x, y)
                if color in points:
                    points[color].append((x, y))
        assert all(len(pixels) > 200 for pixels in points.values()), {hex(k): len(v) for k, v in points.items()}
        means = [(sum(x for x, y in pixels) / len(pixels), sum(y for x, y in pixels) / len(pixels)) for pixels in points.values()]
        assert means[0][0] < means[1][0] and means[2][0] < means[3][0], means
        assert means[0][1] < means[2][1] and means[1][1] < means[3][1], means
    finally:
        x11.XDestroyImage(image)
        x11.XCloseDisplay(display)

with tempfile.TemporaryDirectory(prefix='winboat-console-test-') as temporary:
    root = Path(temporary)
    daemon = subprocess.Popen(['dbus-daemon', '--session', '--nofork', '--print-address=1'], stdout=subprocess.PIPE, text=True)
    viewer = None
    try:
        address = daemon.stdout.readline().strip()
        bus = Gio.DBusConnection.new_for_address_sync(address, Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
        bus.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'RequestName', GLib.Variant('(su)', ('org.qemu', 0)), None, 0, 3000, None)
        peers, resizes, failures = {}, [], []
        info = Gio.DBusNodeInfo.new_for_xml(XML)

        def prop(connection, sender, path, interface, name):
            if interface == PREFIX + 'VM':
                return GLib.Variant('au', [0, 1, 2])
            identifier = int(path.rsplit('_', 1)[1])
            values = {'Type': ('s', 'Text' if identifier == 2 else 'Graphic'),
                      'Head': ('u', 0), 'Label': ('s', 'VGA' if identifier == 0 else 'virtio-gpu-gl-pci'),
                      'Width': ('u', 32), 'Height': ('u', 24), 'IsAbsolute': ('b', True)}
            kind, value = values[name]
            return GLib.Variant(kind, value)

        def authenticate(identifier, stream):
            try:
                peers[identifier] = Gio.DBusConnection.new_sync(stream, None, Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT, None, None)
            except Exception as error:
                failures.append(str(error))

        def method(connection, sender, path, interface, name, parameters, invocation):
            identifier = int(path.rsplit('_', 1)[1])
            if name == 'SetUIInfo':
                resizes.append(identifier)
                invocation.return_value(None)
                return
            assert identifier != 2, 'Viewer registered a text console'
            client, server = socket.socketpair()
            fdlist = Gio.UnixFDList.new()
            handle = fdlist.append(server.fileno())
            invocation.return_value_with_unix_fd_list(GLib.Variant('(h)', (handle,)), fdlist)
            server.close()
            stream = Gio.UnixConnection(socket=Gio.Socket.new_from_fd(client.detach()))
            threading.Thread(target=authenticate, args=(identifier, stream), daemon=True).start()

        bus.register_object('/org/qemu/Display1/VM', info.interfaces[0], None, prop, None)
        for identifier in range(3):
            for interface in info.interfaces[1:]:
                bus.register_object(CONSOLE + str(identifier), interface, method, prop, None)

        def call(identifier, method_name, signature, arguments):
            peers[identifier].call_sync(None, LISTENER, PREFIX + 'Listener', method_name,
                                       GLib.Variant(signature, arguments), None, 0, 5000, None)

        colors = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0)]
        pixels = bytes(component for y in range(24) for x in range(32)
                       for component in (*reversed(colors[(y // 12) * 2 + x // 16]), 255))
        red = bytes([0, 0, 255, 255]) * (32 * 24)
        gray = bytes([80, 80, 80, 255]) * (32 * 24)
        stage = 0
        visible = False
        started = time.monotonic()
        loop = GLib.MainLoop()

        def tick():
            global stage, visible
            try:
                if failures:
                    raise RuntimeError(failures[0])
                if viewer.poll() is not None:
                    loop.quit()
                    return False
                if time.monotonic() - started > 20:
                    raise RuntimeError('Viewer handoff test timed out')
                if len(peers) != 2:
                    return True
                if stage == 0:
                    call(0, 'Scanout', '(uuuuay)', (32, 24, 128, 0x20020888, red))
                    # An idle secondary scanout must not replace the boot VGA.
                    call(1, 'Scanout', '(uuuuay)', (32, 24, 128, 0x20020888, gray))
                elif stage == 1:
                    call(1, 'Update', '(iiiiuuay)', (0, 0, 32, 24, 128, 0x20020888, pixels))
                elif stage == 2:
                    # Stale VGA updates must not steal the accelerated desktop.
                    call(0, 'Update', '(iiiiuuay)', (0, 0, 32, 24, 128, 0x20020888, red))
                    call(0, 'Disable', '()', ())
                elif stage == 3:
                    call(1, 'Disable', '()', ())
                    call(0, 'Scanout', '(uuuuay)', (32, 24, 128, 0x20020888, red))
                elif stage == 4:
                    call(1, 'Scanout', '(uuuuay)', (32, 24, 128, 0x20020888, pixels))
                    call(1, 'Update', '(iiiiuuay)', (0, 0, 32, 24, 128, 0x20020888, pixels))
                elif stage == 8:
                    visible_frame()
                    visible = True
                stage += 1
                return True
            except Exception as error:
                failures.append(str(error))
                loop.quit()
                return False

        environment = dict(os.environ, TMPDIR=temporary)
        viewer = subprocess.Popen([sys.argv[1], '--smoke-test', address], env=environment,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        GLib.timeout_add(400, tick)
        loop.run()
        if failures:
            raise RuntimeError(failures[0])
        output, errors = viewer.communicate(timeout=3)
        assert viewer.returncode == 0, errors
        assert '{"event":"ready","transport":"dbus"}' in output, output
        selections = [json.loads(line)['id'] for line in errors.splitlines() if line.startswith('{"event":"console"')]
        assert selections == [0, 1, 0, 1], (selections, errors)
        assert 1 in resizes, 'Guest resize did not follow the selected Helios console'
        assert visible, 'The actual displayed frame was not checked'
        magic, dimensions, maximum, pixels = (root / 'helios-viewer-smoke.ppm').read_bytes().split(b'\n', 3)
        width, height = map(int, dimensions.split())
        assert magic == b'P6' and maximum == b'255'
        scale = min(width / 32, height / 24)
        for index, color in enumerate(colors):
            x = int(width / 2 + (-8 if index % 2 == 0 else 8) * scale)
            y = int(height / 2 + (-6 if index < 2 else 6) * scale)
            offset = (y * width + x) * 3
            assert tuple(pixels[offset:offset + 3]) == color, (index, pixels[offset:offset + 3])
        print('Actual viewer: VGA -> Helios, stale VGA isolation, disable/re-enable handoff, console-1 resize, visible X11 frame and four readback corners passed.')
        # Losing one adapter is recoverable; losing the VM must report failure
        # instead of leaving a permanently blank window marked as connected.
        peers.clear()
        viewer = subprocess.Popen([sys.argv[1], '--address', address], env=environment,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        disconnect_stage = 0
        disconnect_started = time.monotonic()

        def disconnect_tick():
            global disconnect_stage
            if viewer.poll() is not None:
                loop.quit()
                return False
            if time.monotonic() - disconnect_started > 12:
                failures.append('Viewer did not terminate after VM disconnection')
                loop.quit()
                return False
            if len(peers) != 2:
                return True
            if disconnect_stage == 0:
                peers[0].close_sync(None)
            elif disconnect_stage == 1:
                peers[1].close_sync(None)
            disconnect_stage += 1
            return True

        GLib.timeout_add(400, disconnect_tick)
        loop.run()
        assert not failures, failures
        output, errors = viewer.communicate(timeout=3)
        assert viewer.returncode != 0 and 'All QEMU display consoles disconnected.' in errors, errors
        print('Actual viewer reports complete VM disconnection while tolerating one disconnected adapter.')
    finally:
        if viewer is not None and viewer.poll() is None:
            viewer.terminate()
            viewer.wait(timeout=5)
        daemon.terminate()
        daemon.wait(timeout=5)
