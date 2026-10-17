/** Native GTK helpers must load host graphics libraries, not Electron's EGL. */
export function nativeDesktopEnvironment(source: NodeJS.ProcessEnv, bundledRoot?: string): NodeJS.ProcessEnv {
    const env = {...source};
    const roots = [source.APPDIR, bundledRoot].filter((root): root is string => !!root && root.startsWith('/'))
        .map(root => root.replace(/\/+$/, ''));
    const bundled = (entry: string) => roots.some(root => entry === root || entry.startsWith(root + '/'));
    for (const name of ['PATH', 'LD_LIBRARY_PATH', 'GI_TYPELIB_PATH', 'GTK_PATH', 'GIO_EXTRA_MODULES',
        'LIBGL_DRIVERS_PATH', '__EGL_VENDOR_LIBRARY_DIRS', '__EGL_VENDOR_LIBRARY_FILENAMES']) {
        if (!env[name]) continue;
        const entries = env[name]!.split(':').filter(entry => !bundled(entry));
        if (entries.length) env[name] = entries.join(':'); else delete env[name];
    }
    for (const name of ['GTK_EXE_PREFIX', 'GTK_DATA_PREFIX', 'GDK_PIXBUF_MODULE_FILE']) {
        if (env[name] && bundled(env[name]!)) delete env[name];
    }
    if (env.LD_PRELOAD) {
        const entries = env.LD_PRELOAD.split(/[\s:]+/).filter(entry => entry && !bundled(entry));
        if (entries.length) env.LD_PRELOAD = entries.join(' '); else delete env.LD_PRELOAD;
    }
    return env;
}
