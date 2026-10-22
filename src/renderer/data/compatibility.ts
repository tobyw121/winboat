/** User reports are advisory, not certification or automatic settings changes. */
export const compatibility=[
 {application:'FurMark 2 — OpenGL',status:'User-observed on .291 / RTX 2070',note:'OpenGL rendering was reported working. Re-run the installed OpenGL acceptance probe after a stack change.'},
 {application:'FurMark 2 — Vulkan',status:'Unresolved compatibility report',note:'Enumeration and the Vulkan presentation probe can pass while the workload crashes. Capture the application log and feature/device-creation failures.'},
 {application:'Icarus',status:'Unresolved compatibility report',note:'Reported loading-screen crash. Capture the actual game executable, D3D feature request and crash module; no verified universal workaround.'},
 {application:'GPU-Z',status:'Hardware telemetry limitation',note:'A virtual adapter does not expose all physical NVIDIA sensors or PCI capabilities. Empty telemetry is not proof that rendering is unavailable.'},
];
