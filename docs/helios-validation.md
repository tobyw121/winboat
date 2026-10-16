# Validation record

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
