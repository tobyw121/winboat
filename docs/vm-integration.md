# VM integration

The Configuration page contains VM integration controls for offline snapshots,
plain-text clipboard exchange, authenticated file exchange, Windows power,
local audio and additional display windows. Update the host AppImage **and** the
Windows guest service. This does not require a new Helios driver package. The
bundled stable .291 installer and separate candidate installers remain unchanged.

Build from the work branch on the Linux desktop with:

```bash
./scripts/build-helios.sh
```

The host image must also be rebuilt for local audio; an older host image lacks
its opt-in routing capability. The new audio capability label is advertised only
by the updated host recipe, and its QEMU build checks the D-Bus audio backend.

## Snapshots

These are verified, uncompressed **offline storage checkpoints**. Shut Windows
and the container down cleanly first. Snapshots include bind-mounted `/storage`,
including firmware stored there, and a private container description. Shared
folders and external disks are excluded; external QEMU disk arguments and QCOW2
backing chains are rejected. No live VSS snapshot, RAM snapshot or GPU-state
restoration is advertised or implemented.

Archives and records are private under `~/.winboat/snapshots`. They can contain
Windows data and configuration secrets. Allow enough space for the complete
archive, the staged restoration and retained previous storage.

Restore requires the same storage path and pinned image ID. The manager verifies
the archive into a staging directory, removes the stopped container without
force or volume deletion to fence concurrent starts, then swaps storage and
recreates the container **stopped**. The previous storage remains alongside it
as `storage.before-…` (using the original directory's name). Start the VM manually
after inspecting the result. This restores storage, not host configuration
changes made since the snapshot.

A private journal records interruption states. If a container-creation response
is uncertain, the manager does not move storage underneath a possibly running
container. Use **Recover interrupted restore**; unresolved name conflicts require
inspection of `restore-transaction.json`. Never publish that journal unredacted.
Retained storage is not automatically deleted.

CLI equivalents:

```bash
python3 scripts/helios/vm-snapshots.py list
```

```bash
python3 scripts/helios/vm-snapshots.py create --label "Before update"
```

## Clipboard and files

Clipboard directions are separately selectable. Connecting launches a helper in
the signed-in Windows console session and asks there for permission. It does not
read another user's clipboard or run a SYSTEM clipboard fallback. Synchronization
is plain Unicode text, capped at 256 KiB UTF-8; files and images are excluded.
Existing clipboard contents are not automatically sent when connecting. Manual
Send/Receive requests can explicitly transfer current text. Automatic Linux
empty-text changes are ignored; a Windows Unicode text clear can propagate.

Text and tokens stay in memory. Origin/revision tracking prevents echoes. Lock,
logoff, session disconnect, helper exit or 30 seconds without host heartbeat ends
the session; reconnect after unlocking. Windows uses clipboard notifications;
the Linux application polls while sharing is connected. Directions are not
silently persisted across application restarts.

File exchange uses the existing authenticated SMB support and the dedicated
`\\host.lan\WinBoatExchange` share. Setup explicitly restarts Windows. Linux sends
files into `ToWindows`; Windows saves outgoing files into `ToLinux`. Transfers
show progress and support cancellation. Copies publish only after completion,
refuse existing destinations and symlink sources, and report a SHA-256 digest.
This is a controlled exchange folder, not arbitrary guest filesystem access.

## Audio, USB and display windows

Local audio uses QEMU's authenticated private D-Bus connection and bounded PCM
queues. Install Linux Python GI, GStreamer GI bindings and base/good plugins
(e.g. `python3-gi gir1.2-gstreamer-1.0 gstreamer1.0-plugins-base
 gstreamer1.0-plugins-good`). Enable VM audio with an explicit restart, then connect
playback. Microphone registration requires an additional host confirmation; Stop
or closing WinBoat terminates the helper and recording. The host may require its
own microphone permission. A connected listener does not prove Windows is
producing audio or that a physical audio device works.

USB retains the existing passthrough UI. Connecting warns before exclusive host
capture, highlights HID devices and rejects detected mounted Linux block storage,
including automatic reconnection. If inspection is unavailable, the dialog says
so. Eject storage in Windows before releasing it. QMP command completion is
matched by request ID; removal waits for the device to disappear before updating
the saved selection. Duplicate VID/PID device selection remains a limitation.

The output list contains actual graphical QEMU consoles. Opening one subscribes
only to that console, including a nonzero head. Move separate windows between
host monitors with the window manager. This does not create additional virtual
heads, change Windows display topology or increase driver multi-monitor support.
Resize guest sends QEMU size hints; successful resolution changes depend on the
Windows driver. The existing VGA/Helios selection and fallback remain available.

Windows shutdown/restart requests use normal Windows shutdown without forced
application termination. Apps may block completion. Refresh reports container,
QEMU run state and guest API availability independently; none alone proves a
working desktop.

## Validation and limits

`npm run test:integration` covers text echo/bounds, QMP framing/concurrency,
atomic file transfer/cancellation, mounted USB detection and snapshot recovery.
The Windows service cross-build and portable broker/power tests are separate.
`python3 tests/vm-snapshots-engine.py` additionally exercises restore against a
disposable uniquely named Docker container using the local `node:24-bookworm-slim`
image; it never addresses the WinBoat container.
`tests/helios-audio-peer.py` uses actual passed D-Bus FDs and GStreamer with
simulated audio devices. Native GTK tests exercise independent output selection,
nonzero-head resize, real displayed software frames and VGA fallback. CI runs
these checks; physical Windows/NVIDIA, microphone and audio-device validation
still need a real desktop VM. Existing upstream declaration errors require
`--skipLibCheck` for the renderer type check.
