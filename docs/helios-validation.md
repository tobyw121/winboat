# Validation record

Verified in this cloud workspace on 16 October 2026 (Europe/Berlin):

- 8 Helios TypeScript tests and 5 existing GPU tests passed, with no skips.
- The Go read-only status-handler test passed, including PowerShell UTF-8 BOMs,
  missing/corrupt state, failure reporting and installed-manifest precedence.
- Renderer Vue type checking passed with `--skipLibCheck`; this checks application
  types, not all third-party declaration files. Main TypeScript and production
  Vite builds passed. The Windows guest-server cross-build passed.
- The OEM PowerShell helper and the Windows CI PowerShell blocks parsed without
  syntax errors. Native Windows installation/reboot behavior has not been run here.
- The complete upstream Windows installer was imported through the reproducible
  fetch command. Artifact, nested-archive, EXE and embedded-container checksums
  passed; all 36 manifest-listed embedded payload files were also checked during
  inspection. The PE is an x64 Windows GUI executable. It was not executed in
  Windows in this environment. Its immutable provenance is in `helios/stack.lock.json`.
- `electron-builder --linux dir` produced `dist/linux-unpacked`, including the
  complete Windows installer. The packaged application opened the welcome screen;
  `app.isPackaged` was true and its bundled installer matched the receipt hash.
  External web-font requests hit the cloud browser's NSS/CA restrictions; no TLS
  verification was bypassed.
- The local image `winboat/helios:d82ce565ac79` built successfully. QEMU 11.1.1
  reports the Venus property. The upstream protocol round-trip test and renderer
  `venus_queue_sync` test each passed (1/1, no skips).
- Final local image ID:
  `sha256:274bcf25a0ff7456e596bf0c6066ac4eed3b0dadb2a1dcb16c08f17e03bd9eb5`.
  Image size: 1,189,733,748 bytes. Rebuilds may differ as Debian build dependencies
  change; upstream source revisions and the dockur base digest are pinned.
- `npm run test:helios:host` passed: image identity, installed display/shared-memfd
  argument generation, runtime-library resolution using the installed wrapper's
  loader path, and a QEMU TCG/QMP run with 128 MiB shared memory followed by clean
  shutdown. The display-argument check uses a null character-device fixture; it
  does not emulate a real GPU.

The first host build lacked a test dependency and protocol pkg-config path; both
were corrected. A subsequent Docker output stage exhausted the 32 GB workspace;
a separate runtime stage fixed that, and the final image and Linux package builds
succeeded. No failed build or partial package is counted as a pass.

Unverified: KVM execution, Windows driver loading/signature acceptance, actual
provisioning reboots, GPU rendering, NVIDIA/AMD/Intel hardware compatibility,
DirectX conformance, game compatibility, anti-cheat and gaming performance.
The current display integration uses noVNC, not a local high-refresh SDL viewer.
