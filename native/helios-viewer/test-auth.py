#!/usr/bin/env python3
"""Compile and test the exact authorization callbacks carried by the QEMU patch."""
import pathlib
import shlex
import subprocess
import tempfile
root = pathlib.Path(__file__).resolve().parents[2]
patch = (root / 'helios/host/patches/0001-dbus-listener-authenticated-owner.patch').read_text()
added = '\n'.join(line[1:] for line in patch.splitlines() if line.startswith('+') and not line.startswith('+++'))
start = added.index('static gboolean dbus_listener_mechanism')
functions = added[start:added.index('#endif', start)]
program = '#include <gio/gio.h>\n#include <sys/types.h>\n' + functions + r'''
int main(void) {
 GDBusAuthObserver *observer = g_dbus_auth_observer_new();
 GCredentials *credentials = g_credentials_new();
 GError *error = NULL;
 g_assert_true(g_credentials_set_unix_user(credentials, 1234, &error));
 g_assert_no_error(error);
 g_assert_true(dbus_listener_authorize(observer, NULL, credentials, GUINT_TO_POINTER(1234)));
 g_assert_false(dbus_listener_authorize(observer, NULL, credentials, GUINT_TO_POINTER(5678)));
 g_assert_false(dbus_listener_authorize(observer, NULL, NULL, GUINT_TO_POINTER(1234)));
 g_assert_true(dbus_listener_mechanism(observer, "EXTERNAL", NULL));
 g_assert_false(dbus_listener_mechanism(observer, "ANONYMOUS", NULL));
 g_assert_false(dbus_listener_mechanism(observer, "DBUS_COOKIE_SHA1", NULL));
 g_object_unref(credentials); g_object_unref(observer);
 g_print("QEMU listener authorization: matching UID accepted, different/missing UID and weaker mechanisms rejected.\n");
 return 0;
}
'''
with tempfile.TemporaryDirectory() as tmp:
    source = pathlib.Path(tmp) / 'peer-auth.c'
    output = pathlib.Path(tmp) / 'peer-auth'
    source.write_text(program)
    flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', 'gio-2.0'], text=True))
    subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter', str(source), *flags, '-o', str(output)], check=True)
    subprocess.run([str(output)], check=True)
