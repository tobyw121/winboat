# Shared folders

In **Configuration → Shared Folders**, add a Linux directory, choose its Windows
share name and optionally enable **Read only**. Multiple folders are supported.
Disable an entry to keep its settings without exporting it, or remove it.
**Save shared folders** applies just these folders and restarts the VM, even
when unrelated CPU or RAM settings cannot be saved. Errors appear directly
below that button. The same folder controls are
available during initial setup.

Copy the Windows path and paste it into Explorer's address bar, for example
`\\host.lan\Projects`. Sign in as **winboat** with the Windows VM password. This
SMB account name stays `winboat` even if the Windows account has another name.
Neither Windows network discovery nor FreeRDP is required. If hostname lookup
fails, **Test saved shares** also provides a direct IP path when available.
The test authenticates to each saved share from inside the container; it does
not test Windows firewall settings or the Windows client's cached credentials.
For NAT networking its direct IP path uses the container's bridge address,
not the Windows guest's own IP address.

The server requires signed SMB and authenticated access, including on Windows
11 with mandatory SMB signing. It does not enable insecure guest access or
weaken Windows signing policy. Host directory permissions are preserved; new
files use the Linux user's UID/GID. Read-only shares also use read-only Docker
bind mounts. Symlinks outside an exported directory are not followed.

Existing home-folder shares are imported as `Data` (and additional legacy
mounts as `Data2`/`Data3`). Save Configuration once to migrate to the managed
authenticated server. Share names and permissions are editable; VM disks and
unrelated mounts remain intact. Folder paths must exist and be accessible before
the VM starts; disabled entries may point to disconnected disks.

## Updating existing installations

Both the Atlas and Helios runtime images must expose
`org.winboat.shared-folders=authenticated-v1`. A new AppImage alone does not
add missing image dependencies; rebuild with `./scripts/build-helios.sh` if
that capability is absent. Saving stages the current Samba helpers beside the
Compose file and mounts them read-only, so helper updates work with an existing
capable image and remain available when the AppImage is closed.
Ordinary Windows installations with managed shares
use the patched Atlas runtime image; this does not enable the Atlas playbook.
Configurations without managed shares retain the upstream Samba handler.

## Verification

`npm run test:shared-folders` exercises migration, path preservation, disabled
entries, read-only mounts, validation and graphics configuration compatibility.
`.github/workflows/test-shared-folders.yml` additionally runs a real Samba server
in a disposable container with fixture directories: signed authentication,
upload/download, wrong-password and guest rejection, read-only enforcement,
empty folders, diagnostic paths and host ownership/permission preservation.
It publishes no SMB ports and does not use personal folders.
