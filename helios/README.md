# Helios sources in WinBoat

`upstream/` contains the complete Helios root-source snapshot from
`https://github.com/winboat-org/helios` at the host revision in `stack.lock.json`.
It is ordinary source in this Git repository, not a submodule or a separate
checkout. Reviewed WinBoat changes are recorded under `localChanges` in
`source.lock.json`; its file hashes identify the effective build inputs.
The revision/tree still identify the original upstream baseline. Cloning WinBoat also obtains these Helios sources.

`source.lock.json` records the original Git tree, every effective source-file SHA-256 and
all seven upstream dependency gitlinks. The dependency directories in the
snapshot are empty, as in an upstream Git archive. Mesa, QEMU, virglrenderer and
Venus protocol are downloaded at those exact revisions during the Linux host
image build. QEMU also initializes its recorded build-time submodules. The
Windows build has additional DXVK/vkd3d/loader dependencies. Its first-party
installer, packaging scripts and driver sources are already part of this snapshot.

The Linux build applies the tracked, checksummed QEMU listener-authentication
patch under `host/patches/` after checking out its recorded gitlink. Its optional
reverse-listener method returns a QEMU-created socket FD to the desktop viewer;
the viewer authenticates its kernel UID against the QEMU display-bus owner.
The original registration method also binds its peer to the authenticated
display-bus caller. Host patches remain separate from the Windows source
divergence described above. See [the native display notes](../docs/helios-local-display.md).

Check the snapshot with `python3 scripts/helios/verify-source.py`. To update it,
import a reviewed upstream Git archive, regenerate `source.lock.json` from that
same commit and update the host/guest compatibility lock and image pins together.
Do not edit the vendored snapshot without recording the resulting divergence.

Original notices and component licenses are preserved in the snapshot. WinBoat's
MIT license does not grant additional rights to Helios or its dependencies.
The upstream root currently has no explicit root license; redistribution rights
must be clarified before publishing a combined distribution.

See [the local build instructions](../docs/build-helios-local.md).

The complete Windows installer is tracked in `resources/helios/HeliosSetup.exe`,
together with its receipt. The current 22.22.291.0 package is built by WinBoat's
Windows CI from the effective sources, including the recorded UAV ClearView
change and live VidPn display modes. `stack.lock.json` and the receipt record the actual build commit,
baseline snapshot and effective source-lock hash. The original imported package
was replaced after a successful full Windows build and checksum verification.
Linux packaging uses this local checksum-pinned file and does not download an
Actions artifact.

The WinBoat Windows workflow prepares a separate build tree from these embedded
sources; it never checks out the Helios root repository. `sharedSources` also
records the installer/Windows-build/packaging/tool trees shared by the host
snapshot and guest compatibility commit. New CI receipts record the actual
WinBoat build commit and snapshot separately. Rebuild/import instructions are in
[Windows build](../docs/helios-windows-build.md).
