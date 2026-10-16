#!/bin/sh
# QEMU/epoxy dlopen these libraries; ldd on QEMU alone cannot detect their absence.
set -eu
export LD_LIBRARY_PATH=/opt/helios/renderer/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
perl -MDynaLoader -e '
    for my $lib (qw(libGL.so.1 libOpenGL.so.0 libEGL.so.1)) {
        my $handle = DynaLoader::dl_load_file($lib, 1);
        die "Helios OpenGL runtime: " . DynaLoader::dl_error() unless $handle;
        print "$lib loaded\n";
    }
'
for binary in /opt/helios/qemu/bin/qemu-system-x86_64 /opt/helios/renderer/lib/libvirglrenderer.so.1 /opt/helios/renderer/libexec/virgl_render_server; do
    dependencies=$(ldd "$binary")
    if printf '%s\n' "$dependencies" | grep -q 'not found'; then
        printf '%s\n' "$dependencies" >&2
        exit 1
    fi
done
