# GPU audit: 22.22.291.0 versus 22.22.294.0

## Result, 19 October 2026

The user reports a stable desktop with a complete .291 installation after
DriverStore cleanup. Installing .294 brings back VGA flicker and a black Helios
output. The current .294 report and DWM log establish a failure after the UMD
creates its internal device and before any normal Present reaches it. They do
not yet identify the exact failing runtime capability check.

The leading regression candidate is the D3D11 capability contract changed in
`90bb311`. A broken installation is no longer an adequate explanation of this
clean .294 comparison. Keep .291 as the default; do not describe .294 or .295
as a verified fix for this symptom.

## Scope and actual packages

Reviewed the installer/registrations, D3D11 and D3D12 UMDs, Mesa/Venus patch,
KMD scanout, QEMU readback and guest recovery policy. Compared source between
`f0a662f` and .294's build commit `4c08daa`, and executable sections extracted
from both bundled installers, rather than relying on the version labels.

| Component | .291 versus .294 |
| --- | --- |
| KMD `helios_kmd_render.sys` executable `.text` | Identical, 377344 bytes |
| D3D12 `helios_umd12.dll` executable `.text` | Identical, 3932160 bytes |
| D3D11 `helios_umd.dll` executable `.text` | Changed, 4885504 / 4886528 bytes |
| Mesa `vulkan_virtio.dll` | Changed, including x86 |
| Driver `toolchain.json` | Identical |
| In-tree QEMU host patches | Unchanged in this source comparison |
| Package installation | Changed Vulkan adapter associations and snapshot handling |

Identical executable sections do not establish identical whole PE files or
runtime behaviour: resources, registrations, shared dependencies and inputs can
still differ. D3D12 also consumes Mesa, so its identical code does not establish
that its complete rendering path is unaffected.

SHA-256 of the identical KMD `.text`:
`d29158da99a8a21a98a47eb9ae886c77977a0ae47256229081332abc7f0f4932`.
SHA-256 of the identical D3D12 `.text`:
`c9f17e83e78da862fae5c63852dba68890fbebbf01e26aac9c3a936b81b64621`.

## What the current guest actually does

The report `graphics-20261019-125241-819532.json` identifies .294 bound through
`oem13.inf`, with D3D11/12 and x64/x86 Vulkan/OpenGL registrations pointing to
the .294 payload. Helios and BasicDisplay both run; Helios is the primary
extended display. The restart-required marker remains, so a completed cold-boot
comparison is still a separate acceptance condition.

The subsequently supplied `umd-3668.log` tail shows this sequence repeatedly:

1. The .294 UMD loads the matching .294 Mesa ICD and selects `Helios vGPU`.
2. Venus, the DXVK device, D3D11 COM device, KMD context and paging queue succeed.
3. The UMD logs `CreateDevice -> S_OK`.
4. `DestroyDevice` follows, with all PresentBoundary entry/attempt counters zero.
5. The same DWM process opens the adapter and repeats device creation.

Thus `device-ready` in the existing filtered diagnostics means **internal UMD
creation succeeded**, not that Windows accepted the complete D3D11 device or
that a desktop frame was rendered. The loop is consistent with runtime
initialization/capability rejection; the log contains neither the outer
`D3D11CreateDevice` HRESULT nor the exact rejected format/sample query. It does
not prove a new DWM process crash on every iteration.

The reported `vulkan_virtio.dll` crash events predate the current installation.
Their package versions are not recorded. Do not attribute those addresses to
.294 merely by resolving them against its DLL.

## Concrete capability inconsistency

`umd/src/forward/queries.rs`, changed by `90bb311`, now gets MSAA quality levels
from DXVK's actual `CheckMultisampleQualityLevels[1]`. Previously it returned
table-derived positive levels for selected sample counts/output formats.

However, the corresponding format/capability advertisement did not move with
that change:

- `umd/src/forward/format_caps.rs` still forces MSAA support bits based on a
  format-family table and replaces several depth-family capability words with
  WARP-derived constants. These answers are not derived from the new per-count
  backend query.
- `umd/src/caps.rs` still advertises tiled-resource tier 2 in the default
  profile. The pinned DXVK implementation at `6948271`,
  `src/d3d11/d3d11_device.cpp::CheckMultisampleQualityLevels1`, explicitly rejects
  every nonzero Flags argument, including TILED_RESOURCE, with zero levels.
- The default profile also advertises pipeline levels through 12_0. Merely
  changing MSAA answers does not revalidate that complete feature-level contract.

Windows validates these answers as a coherent contract after the UMD callback
returns. Internal creation followed by immediate destruction is compatible with
such a failure. The exact ordinary format/count rejected on this NVIDIA host
is **not yet captured**; the tiled-resource contradiction alone does not prove
which check caused this DWM loop. Do not restore invented positive quality levels
to conceal unsupported backend operations.

Other changes remain in scope: Mesa now clones/filters host device feature
chains (`44e6595`), and .294 fixes DXVK's adapter-name filter (`4c08daa`). The
current log proves that filter and initial device creation succeed. Added
shader/view error callbacks have no matching failure in the supplied tail.

## DMA-BUF and black output

QEMU reports an OPTIMAL import requiring 4587520 bytes for a 4096000-byte buffer.
The KMD counters describe a 1280x800 linear bootstrap allocation with pitch 5120,
which occupies exactly 4096000 bytes. Normal Present counters remain zero in the
reported snapshot. A rejected bootstrap import can explain unavailable output,
but this evidence does not prove whether it causes or follows the D3D failure.
Counters persist across boots and the host log lacks frame correlation.

Do not reinterpret unknown-modifier buffers as LINEAR or inflate allocation
sizes to bypass the import check. Preserve producer layout/ownership guarantees.
After device acceptance is fixed, scanout still needs its own visible-frame gate.

## Next correction and acceptance gates

Capture the outer D3D11 creation HRESULT and the format/sample/flags capability
answers during the failed creation. Existing `UmdTrace` is off in the supplied
log. The existing `FeatureLevel11=0` diagnostic profile can isolate the FL11
contract during a controlled hardware test, but is not a production fix and
changes must preserve/restore the prior registry state.

Correct format support, sample-count support and tiled-resource advertisement
together using implemented backend capabilities. Validate the resulting feature
level against the real Windows runtime; returning zero unsupported levels alone
does not satisfy a feature level whose required formats are missing. Separate
this change from Mesa feature-chain or presentation changes for causal testing.

Require all of: outer runtime device creation success; no create/destroy loop;
advancing normal Present counters in the current boot; visible stable VGA and
Helios output; cold boot and restart; then Vulkan WSI, OpenGL and native D3D11
render/readback tests. CI compilation, WARP tests and package verification do
not replace these gates on the user's NVIDIA host.

.295 adds explicit installer/DriverStore recovery to the newer source. It has
no established graphics correction for this .294 failure. Neither an additional
cleanup nor a new version number is evidence that this regression is resolved.
