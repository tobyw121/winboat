# Reconnect an existing WinBoat VM

WinBoat can reconnect its existing Windows VM after the application is removed and reinstalled. Windows, applications, disks, EFI files and the saved hardware/graphics configuration are retained. This imports an existing **WinBoat storage folder**, rather than converting a VMware/VirtualBox appliance or installing Windows into an arbitrary disk image.

## Before removing WinBoat

Open **Home → Reinstall recovery → Update recovery details** and check that recovery details are available. **Show VM folder** reveals their location. Keep the **entire VM folder**, including hidden files, `.winboat-recovery`, disk images, firmware/EFI files, hardware identity and any snapshot backing files. Do not delete the VM storage, its Docker volume or run Docker volume pruning as part of uninstalling the application.

Recovery details are saved beside the VM automatically when an existing configured VM is opened, installation completes, application preferences change, and normal configuration changes succeed. Unconfirmed configuration trials are excluded; their settings are recorded after confirmation. The recovery folder contains private copies of the OEM assets, sharing helpers, application profiles and configuration, including existing Windows credentials. Treat it as sensitive. It is **not a disk backup or snapshot**.

For VMs created before this feature, run this version and verify the recovery details **before** deleting `~/.winboat`. If only a disk image survives and its settings were already lost, this feature cannot recover the missing credentials/configuration automatically.

## After reinstalling

1. On the welcome screen, use **Use an existing Windows VM → Choose VM folder**.
2. Choose the retained VM storage folder. Alternatively, select an old WinBoat configuration folder containing `docker-compose.yml` when that folder and its referenced files still exist.
3. Review the disk names, CPU/RAM and Docker image, confirm that this is your own trusted configuration, and click **Import existing VM**.
4. WinBoat reloads into its normal interface. Press **Start** on Home when you want to start Windows.

Import validates the disk and required mount paths. It does not format, copy or resize disks, reinstall Windows/Atlas or replace drivers. A missing container is created **stopped**, with automatic image downloads/builds disabled. A matching existing WinBoat container is adopted; a container pointing to another VM is rejected. Import restores the previous local configuration if Docker validation/creation fails.

The saved Docker image must already be installed (rebuild/pull the saved image first if necessary). External shares, devices and other host files must still be available. Local Desktop is prepared for the current session; if unavailable, Browser Display is used while its saved preference is retained. Import is intended for reconnecting on the same host; moving to different hardware may require adjusting host-specific resources afterward. Docker named-volume imports are not supported by this folder-based importer.

A moved VM folder rebases bind mounts located inside the original storage folder. It does not rewrite QEMU arguments, disk backing chains or external host paths. Do not move a VM with external snapshot backing paths without checking those dependencies separately.
