import {test} from 'node:test';
import assert from 'node:assert/strict';
import {nativeDesktopEnvironment} from '../src/shared/native-desktop-environment';

test('GTK child discards AppImage libraries while keeping host NVIDIA and desktop configuration', () => {
    const source = {
        APPDIR:'/tmp/.mount_winboat', DISPLAY:':0.0', XAUTHORITY:'/run/user/1000/xauth',
        XDG_RUNTIME_DIR:'/run/user/1000', DBUS_SESSION_BUS_ADDRESS:'unix:path=/run/user/1000/bus',
        PATH:'/tmp/.mount_winboat/usr/bin:/usr/bin:/bin',
        LD_LIBRARY_PATH:'/tmp/.mount_winboat/usr/lib:/usr/lib/nvidia:/tmp/.mount_winboat-tools',
        __EGL_VENDOR_LIBRARY_FILENAMES:'/usr/share/glvnd/egl_vendor.d/10_nvidia.json',
        GI_TYPELIB_PATH:'/tmp/.mount_winboat/usr/lib/girepository-1.0',
        GDK_PIXBUF_MODULE_FILE:'/tmp/.mount_winboat/cache/loaders.cache',
        LD_PRELOAD:'/tmp/.mount_winboat/lib/shim.so /usr/lib/host-shim.so',
        GDK_BACKEND:'x11', GDK_DEBUG:'gl-debug',
    };
    const before=JSON.stringify(source);
    const env=nativeDesktopEnvironment(source);
    assert.equal(env.LD_LIBRARY_PATH,'/usr/lib/nvidia:/tmp/.mount_winboat-tools');
    assert.equal(env.PATH,'/usr/bin:/bin');
    assert.equal(env.LD_PRELOAD,'/usr/lib/host-shim.so');
    assert.equal(env.GI_TYPELIB_PATH,undefined);
    assert.equal(env.GDK_PIXBUF_MODULE_FILE,undefined);
    for (const key of ['DISPLAY','XAUTHORITY','XDG_RUNTIME_DIR','DBUS_SESSION_BUS_ADDRESS',
        '__EGL_VENDOR_LIBRARY_FILENAMES','GDK_BACKEND','GDK_DEBUG'] as const) assert.equal(env[key],source[key]);
    assert.equal(JSON.stringify(source),before);
});

test('packaged helpers also remove Electron library paths without APPDIR', () => {
    const env=nativeDesktopEnvironment({LD_LIBRARY_PATH:'/opt/WinBoat',GTK_EXE_PREFIX:'/opt/WinBoat'},'/opt/WinBoat');
    assert.equal(env.LD_LIBRARY_PATH,undefined);assert.equal(env.GTK_EXE_PREFIX,undefined);
});

test('development and host custom library settings remain unchanged', () => {
    const env={LD_LIBRARY_PATH:'/usr/local/lib',LIBGL_ALWAYS_SOFTWARE:'1',WAYLAND_DISPLAY:'wayland-0'};
    assert.deepEqual(nativeDesktopEnvironment(env),env);
});
