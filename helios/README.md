# Helios sources in WinBoat

`upstream/` is the complete, unmodified Helios root-source snapshot from
`https://github.com/winboat-org/helios` at the host revision in `stack.lock.json`.
It is ordinary source in this Git repository, not a submodule or a separate
checkout. Cloning WinBoat also obtains these Helios sources.

`source.lock.json` records the original Git tree, every source-file SHA-256 and
all seven upstream dependency gitlinks. The dependency directories in the
snapshot are empty, as in an upstream Git archive. Mesa, QEMU, virglrenderer and
Venus protocol are downloaded at those exact revisions during the Linux host
image build. QEMU also initializes its recorded build-time submodules. The
Windows build has additional DXVK/vkd3d/loader dependencies.

The Linux build applies the tracked, checksummed QEMU listener-authentication
patch under `host/patches/` after checking out its recorded gitlink. Its optional
reverse-listener method returns a QEMU-created socket FD to the desktop viewer;
the viewer authenticates its kernel UID against the QEMU display-bus owner.
The original registration method also binds its peer to the authenticated
display-bus caller. This local divergence is separate from the unchanged
upstream snapshot. See [the native display notes](../docs/helios-local-display.md).

Check the snapshot with `python3 scripts/helios/verify-source.py`. To update it,
import a reviewed upstream Git archive, regenerate `source.lock.json` from that
same commit and update the host/guest compatibility lock and image pins together.
Do not edit the vendored snapshot without recording the resulting divergence.

Original notices and component licenses are preserved in the snapshot. WinBoat's
MIT license does not grant additional rights to Helios or its dependencies.
The upstream root currently has no explicit root license; redistribution rights
must be clarified before publishing a combined distribution.

See [the local build instructions](../docs/build-helios-local.md).
