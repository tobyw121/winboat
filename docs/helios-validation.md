# Validation record

## Helios .296 diagnostics and QEMU render-node selection, 19 October 2026 (UTC)

- Full Windows build, test signing and self-contained assembly passed in
  [39275019139](https://github.com/tobyw121/winboat/actions/runs/39275019139),
  source commit `a4b32c4a6292db048566a437abafa0fc6e43ad6a`.
  Imported artifact `12200075969`; archive SHA-256:
  `3a58961b7c23f5d5f5057decddd18f4527794366f7d29ac48a8a16cbf2936419`.
  Installer SHA-256:
  `0b01e0b6fa294610bae3950b1006168d9f224025a99333a45e130a317fea44d7`.
  Receipt provenance, the source-lock digest, complete 74-entry payload,
  all 40 manifest file hashes/sizes, and x86/x64 probe PE machines were checked.
  The complete candidate is stored separately in `resources/helios-22.22.296.0/`;
  `.291` remains the unchanged application/OEM default and `.294` stays separate.
- [Game compatibility CI 39275019149](https://github.com/tobyw121/winboat/actions/runs/39275019149)
  passed on the effective Windows source commit `a4b32c4a6292db048566a437abafa0fc6e43ad6a`.
  This includes the production bounded Rust journal, C++ shader helper/exception
  guard, x86/x64 WARP controls, and the real PowerShell child-process runner on
  PowerShell 7 and Windows PowerShell 5.1. The later workflow-trigger update
  passed again in [39276977581](https://github.com/tobyw121/winboat/actions/runs/39276977581).
- [QEMU CI 39275019101](https://github.com/tobyw121/winboat/actions/runs/39275019101)
  passed capture, viewer, patched display callbacks and a full production host
  build. The log contains compilation of `ui_vulkan-readback.c.o`; the compiled
  patch manifest matches the tracked manifest and the runtime label is
  `glvnd-v5`. CI image ID:
  `sha256:9ed84b3eb8b2b4ab1373f662c63e0fed40d3bb8d942da853bba2c3213cd8a2a5`.
  This image was built for CI validation; it was not published as a registry tag.
- The readback selection test exercises the actual production helper against
  reordered GPUs, an unmatched render node, ambiguous identity and absent DRM
  identity. Software EGL callback regressions also pass. These checks do not
  import an NVIDIA DMA-BUF or demonstrate a visible Helios desktop.
- Local source integrity covers 619 files, metadata synchronization passes,
  and all 59 host tests passed with the candidate present. Guest application
  diagnostics, profile restoration and child-only execution tests also passed locally.
- No real Windows/Helios GPU is attached here. Stable VGA/Helios output, DWM
  survival, outer D3D11 acceptance on the user's hardware, cold boot and game/API
  rendering remain acceptance gates. `.296` is a diagnostic build, not a
  confirmed flicker fix. The QEMU selection correction also requires a rebuilt
  host; installing the Windows EXE alone does not update that host.

## WinBoat driver 22.22.291.0: live display modes, 18 October 2026 (UTC)

- Full native Windows build, test signing and self-contained assembly passed in
  [run 39151081085](https://github.com/tobyw121/winboat/actions/runs/39151081085),
  build commit `4e2ee56a8088391838a3f1e1a8ce408faef64576`.
  The AMD64 KMD, x64/x86 Direct3D UMDs, both Mesa runtimes, CLVK, loaders and
  compatibility shims were built successfully.
- Imported artifact `12145987201`, verified archive SHA-256
  `abf543fb266d591cf77ec0228b464ad4f5ad273050bb6a9de3b62db8777e983f`.
  Complete installer SHA-256:
  `c9aeaf9732990c3bda84c7b01e1690d35e1ea1b74f3908c9abe2a56cfc30e722`.
  Decoded and checked the 68-entry payload and manifest version 22.22.291.0.
  The CI receipt matches the effective source-lock hash
  `e2720ad79bd5055ca7bc76bb3e2ddfc83f1958a9309499d36abd71e2e0d87101`.
- 223 kernel leaf-logic tests passed. Four additional tests execute the exact
  production CommitVidPn handler using synthetic OS callbacks: all eleven modes
  in both directions, all-source commits, invalid pins, failed callbacks,
  preservation of the prior mode, reference release, empty and powered-off paths.
  These fixtures do not validate the native ABI or visible GPU scanout.
- [Mode CI 39151081033](https://github.com/tobyw121/winboat/actions/runs/39151081033)
  passed, including x86/x64 compilation of the actual-driver acceptance probe.
  Both downloaded archives matched GitHub artifact digests and PE machines.
  The probe enumerates modes and optionally performs temporary live switches
  with original-mode restoration; it has not run on an active Helios GPU here.
- Source integrity checked for all 612 embedded files. Source-preparation,
  receipt-export, corruption-rejection and skeleton-rejection checks passed.
  The renderer type check, application build, 57 host tests and packaging test
  passed. Viewer 13, dbus-v8 and glvnd-v4 are unchanged.
- Visible live resizing, clone-topology limits and recovery under real Windows
  with the user's NVIDIA GPU remain hardware acceptance gates. Existing VMs
  need the new Windows installer and its requested reboot before live switches.
  Usage and acceptance commands: [live display modes](helios-display-modes.md).

## WinBoat driver 22.22.290.0 and game compatibility, 18 October 2026 (UTC)

- Full Windows build, test signing and self-contained assembly passed in
  [run 39143985874](https://github.com/tobyw121/winboat/actions/runs/39143985874),
  build commit `3ffa64e29e9dc002fc6918803f30783e498cf367`. It builds the AMD64
  KMD, x64/x86 D3D11/D3D12 UMDs, both Mesa runtimes, CLVK, loaders and shims.
- Imported artifact `12143715751`; verified archive SHA-256
  `e8a973cf57cb3928b1b1bc520d36e66efcf7521e253ef0d3da2dc3c6ce049156`.
  Complete installer SHA-256:
  `f7eb6d02a7b86203ce7013237cfad7abae72de59b773d892f9fc2a840c4bcd33`.
  The authenticated container checksum, decoded manifest version 22.22.290.0,
  effective source-lock hash and CI provenance were checked before adoption.
  The payload contains 68 entries. The compatibility identity `fecffde6`
  remains distinct from the WinBoat build commit and effective source hashes.
- The actual modified ClearView function passed two native WARP tests per
  architecture (four total): RTV/UAV full/rect clears, empty rectangles,
  typed buffers, untouched pixels and explicit refusal. Device/handle lookup
  uses fixtures; these tests do not load Helios or exercise its GPU transport.
  The pinned DXVK backend also implements the forwarded image/buffer clears.
- Windows x86/x64 acceptance probes were built in
  [run 39144437194](https://github.com/tobyw121/winboat/actions/runs/39144437194).
  Downloaded artifacts were checked against their GitHub archive digests and
  PE machines (0x8664/0x014c). They were not executed against a Helios GPU.
- Optional per-game DXVK D3D9 setup/restoration passed with actual pinned
  release DLLs under PowerShell 7 and Windows PowerShell 5.1. Foreign DLL
  protection, archive checksum rejection, Java exclusion, architecture
  selection, repeated application and interrupted-lock recovery were checked.
  No game was run. The profile is app-local D3D9 translation, not a D3D9 UMD.
- The Minecraft WGL diagnostic ran in 32- and 64-bit Windows processes and
  with both PowerShell versions. CI's Microsoft GDI OpenGL 1.1 correctly
  failed the actual OpenGL 3.3 core-context requirement. Helios/Zink execution
  and Minecraft rendering remain unverified on the user's GPU.
- Atlas preflight passed in both PowerShell versions after isolating fixture
  types/processes and compiling its native inspector before mocking SystemRoot.
  57 application tests and the packaging hook test passed after bundle import.
- Host protocol dbus-v8, runtime glvnd-v4, viewer 13 and guest graphics protocol
  helios-watchdog-v7 remain compatible. No performance gain or game acceptance
  result is claimed; the new native behavior is D3D11 UAV ClearView dispatch.


## AME OOBE client filename repair, 17 October 2026 (Berlin)

- The pinned original shim's `Main` checks `%PROGRAMDATA%\AME\OOBE\AME.Client.exe`
  and `oobe.conf` before starting AME. Its contingency restores the Microsoft
  OOBE executable and removes the AME service. The old injection only retained
  `OOBE.exe`, matching the service but failing the shim's first check.
- Injection now retains both names with identical original client contents.
  Seven real WIM/ESD/hive tests passed, including both entry points and the
  selected username/password configuration. The actual original Wizard/Atlas
  integration test also passed: the shim and both client paths inside the WIM
  match the pinned SHA-256 values. These tests do not execute Windows.
- Three Atlas and 27 Helios application tests passed. The fix applies to newly
  prepared media; an already-installed guest that took the contingency path
  is not repaired by updating only the Docker/OEM scripts.

## Windows installation display repair, 16 October 2026 (UTC)

- Runtime `glvnd-v3` adds bootstrap VGA before the Helios GPU until the host
  installer records a confirmed matching Helios installation. Marker absence,
  stale revision, symlink rejection, explicit disable and invalid configuration
  were exercised in both installed display modes through dockur's real scripts.
- The complete host smoke passed, including the renderer-server regression and
  shared-memfd QMP/TCG control. Image ID:
  `sha256:86283af800693443214a9973011dbee92b429e24929774db4b2f4240f7500c08`.
- A separate real OVMF/TCG boot with VGA first and a secondary **non-GL** VirtIO
  GPU captured console 0 at 1280x800. The capture was visually inspected as a
  readable UEFI shell, rather than QEMU's inactive-display placeholder.
  Artifact: `dist/helios-bootstrap-smoke.ppm`.
- All 27 Helios tests, Vue type checking and the renderer/main production build
  passed. Windows Setup/AME, physical GL/Venus rendering and automatic removal
  after a real Windows driver installation still require the user's VM.

## Renderer-server launcher repair, 16 October 2026 (UTC)

- Reproduced the missing PID file with the actual paired renderer library:
  the old wrapper's `VIRGL_RENDER_SERVER_PATH` is ignored, the renderer child
  fails to exec its compiled-in build path and executes inherited exit handlers.
  The probe returned `init=0 server=0 pidfile=0`, despite its parent still running.
- The corrected `RENDER_SERVER_EXEC_PATH` starts the installed server and keeps
  the parent's PID marker. `npm run test:helios:host` passed, including that real
  fork/exec regression, both display argument checks, the HTTP setup transition,
  runtime loaders and the shared-memfd QMP/TCG check.
- Repaired runtime image: capability `glvnd-v2`, ID
  `sha256:20d132e5d66384fbaa609a7f392beef360712abd727fbf0d2e49b317f85bd879`.
  Paired QEMU/renderer binaries were reused; the launcher layer was rebuilt.
- All 27 Helios tests and seven build-update tests passed. Renderer Vue type
  checking and the production renderer/main build passed. No AppImage was
  repackaged for this repair, and no Windows, physical GPU or KVM run is claimed.

Baseline builds verified in this cloud workspace on 16 October 2026:

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
- An earlier `electron-builder --linux dir` run produced `dist/linux-unpacked`,
  including the complete Windows installer. That packaged application opened the welcome screen;
  `app.isPackaged` was true and its bundled installer matched the receipt hash.
  External web-font requests hit the cloud browser's NSS/CA restrictions; no TLS
  verification was bypassed.
- The local image `winboat/helios:d82ce565ac79` built successfully. QEMU 11.1.1
  reports the Venus property. The upstream protocol round-trip test and renderer
  `venus_queue_sync` test each passed (1/1, no skips).
- The host image was rebuilt from all 611 vendored Helios root-source files;
  source hashes, dependency pins and both upstream tests passed again.
- Earlier baseline image ID:
  `sha256:5273f59ecc2fffb25dfa8027591d28d9e1efc4f456b0e2117dfa1280e21cf3e0`.
  Image size: 1,189,734,532 bytes. Rebuilds may differ as Debian build dependencies
  change; upstream source revisions and the dockur base digest are pinned.
- `npm run test:helios:host` passed: image identity, installed display/shared-memfd
  argument generation, runtime-library resolution using the installed wrapper's
  loader path, and a QEMU TCG/QMP run with 128 MiB shared memory followed by clean
  shutdown. The display-argument check uses a null character-device fixture; it
  does not emulate a real GPU.
- The root Dockerfile and `scripts/build-helios.sh` completed with `--skip-host
  --all-packages --export-host-image --installer-dir <directory with spaces>`
  after that host rebuild. The fresh container ran `npm ci`, all 13 JavaScript
  tests, Go status tests, Vue checking, guest cross-build, production build and
  native USB rebuild. The lockfile was completed with its missing optional
  Windows signing dependency; existing locked package versions were preserved.
- AppImage, DEB, RPM and tar.gz were built successfully. Each package's embedded
  `HeliosSetup.exe` matched the trusted receipt hash; its receipt also matched.
  The exported host-image archive passed gzip integrity checking. All nine
  generated package/installer/metadata/image checksums passed in `SHA256SUMS`.
- Shell syntax, invalid arguments, missing installer paths, and rejection of
  modified/missing source files were checked. The source import contains no
  nested Git submodules; its external gitlinks are recorded in `source.lock.json`.
- The built QEMU lists `dbus` among its display backends. This establishes build
  availability only; DMA-BUF export, viewer import and presentation fences have
  not been exercised by that baseline build. The current viewer test is recorded below.

The first host build lacked a test dependency and protocol pkg-config path; both
were corrected. A subsequent Docker output stage exhausted the 32 GB workspace;
a separate runtime stage fixed that, and the final image and Linux package builds
succeeded. No failed build or partial package is counted as a pass.

## Native local display milestone

Validated on 16 October 2026 (UTC), after the baseline packages above:

- The tracked QEMU patch adds an optional reverse-authentication listener with
  QEMU-created socket FDs. EXTERNAL authentication remains mandatory. It also
  sends a full software scanout when a surface changes before partial updates;
  the BIOS switches from 640x480 to 720x400 during the test.
- Current image: `winboat/helios:d82ce565ac79`, capability `dbus-v3`, ID
  `sha256:33033f39977fc6d8f5e374ff9bdc21e59969dfc9d31c29db1cc1a598129d2b7b`,
  size 1,189,753,601 bytes. Its source build passed the upstream protocol and
  renderer synchronization tests. All 611 pristine vendored sources still match
  their hashes; the QEMU divergence is confined to `helios/host/patches/`.
- All 12 Helios/display tests and 5 existing GPU tests passed. Renderer Vue type
  checking and the production renderer/main build passed.
- The viewer compiles with `-Wall -Wextra -Werror`. Its self-test and the compiled
  QEMU authorization callbacks accept matching UIDs and reject different/missing
  UIDs and weaker authentication mechanisms.
- `npm run test:helios:viewer` passed with root QEMU in its own container PID
  namespace and the viewer as desktop UID 1000. Only the test viewer container
  used the host PID namespace to model a native host process. The private bus
  denied that desktop user permission to claim `org.qemu`.
- The eight-second software display test processed 668 software frames and
  rendered 293 frames in the window; `dmabufFrames` was **0**. It captured a
  non-uniform 1024x640 frame, visually inspected as readable SeaBIOS boot output.
  The test deliberately has no boot disk, Windows, KVM or physical GPU.
- `npm run test:helios:host` checks the capability label, both display modes,
  runtime library resolution and shared-memory QMP/TCG behavior. It does not
  demonstrate DMA-BUF export/import.
- The Docker/Bash pipeline completed with `--skip-host --export-host-image`.
  It reran all 17 JavaScript tests, Go status tests, Vue type checking, the
  Windows guest-server cross-build and the production Electron build. The
  AppImage includes the native viewer and verified Windows installer.
- All seven checksums passed after export, and the host archive passed gzip
  integrity checking. Extracting the AppImage confirmed that the executable ELF
  viewer matches `BUILD-INFO.json`, and that the installer and receipt match
  their trusted hashes. The build metadata also records `dbus-v3` and the
  tracked QEMU patch hash. DEB/RPM/tar.gz packages from the earlier baseline
  were not rebuilt for this viewer milestone.
- Earlier failed authentication and frame-format experiments were corrected;
  only the successful current test is counted above.

## Previous installer authentication fix (superseded)

The reported clean-clone failure was HTTP 401 from GitHub's Actions artifact
download API. Before the full migration below, the builder accepted
`GH_TOKEN`/`GITHUB_TOKEN` through a BuildKit secret; curl receives the authorization header over stdin, and retains
its default cross-origin credential stripping. Download errors report the HTTP
status and describe both authentication and local-installer remedies.

Validated on 16 October 2026:

- Four real-curl HTTP fixture tests passed: authenticated download, credential
  stripping on storage redirects, actionable 401/404 errors, and environment
  token fallback. The full Helios suite passed all 16 tests.
- The actual pinned upstream artifact downloaded and passed all existing
  archive, executable and embedded-payload checksum/revision checks.
- A Docker build with an empty installer context downloaded the installer from
  scratch and produced the AppImage. All 21 JavaScript tests, Go status tests,
  Vue type checking, guest-server cross-build and production build passed in
  that container. All six exported artifact checksums passed.
- Shell syntax and TypeScript checking of the download helper/tests passed.
  The GitHub-authenticated user flow was checked with local test credentials;
  access to the upstream artifact still depends on the caller's GitHub account.

## Installer migration into WinBoat

On 16 October 2026 the complete verified Windows installer and its receipt were
added to Git. Its executable SHA-256 remains
`08f22b6685940834415fa3472fc7e6b864c7c46b5f972a8798377836adc0a886`.
This is the existing imported upstream binary with retained provenance, not a
claim that a new native Windows binary has already been compiled.

- All seven Windows jobs now check out WinBoat and prepare its embedded sources
  in a separate build tree. No job checks out the Helios root repository.
- The installer, packaging, Windows build-tool, metadata, compatibility-header,
  common tool and KMD-logic trees were compared across the original guest/host
  commits and match. Their IDs extend the existing shared-source lock.
- Normal packaging has no installer download path or GitHub token requirement.
  It verifies both the complete embedded container and the repository's pinned
  EXE hash. The former fetch command now verifies the included bundle locally.
- All 17 Helios tests passed, including real bundled-binary validation, deliberate
  CI-package adoption, rejection of foreign/mismatched provenance and a real Git
  checkout with Windows-style newline conversion enabled. Source attributes
  preserve both original LF and CRLF snapshot files and the source-lock digest.
- PowerShell source preparation/reuse, build-directory isolation, receipt export,
  corrupted-container rejection and skeleton rejection passed under PowerShell
  7.5 on Linux. This is script/format evidence, not a native MSVC/WDK build.
- The combined Docker/Bash build completed with `--skip-host`, using the
  repository-bundled installer without any installer-download step. All 22
  JavaScript tests, Go status tests, Vue checks, the guest-server cross-build
  and the AppImage build passed. All six exported checksums passed. Extracting
  the AppImage confirmed the bundled EXE pin and identical provenance receipt.
- The Windows workflow passed actionlint. TypeScript checking of the new import
  tools/tests and shell syntax checks passed; all 611 vendored source hashes
  still match the immutable snapshot.

Unverified: KVM execution, Windows driver loading/signature acceptance, actual
provisioning reboots, GPU rendering, NVIDIA/AMD/Intel hardware compatibility,
DirectX conformance, game compatibility, anti-cheat and gaming performance.
The default display remains noVNC. The optional local viewer is an experimental
GTK4/OpenGL client; high-refresh gaming and physical DMA-BUF import remain unverified.
