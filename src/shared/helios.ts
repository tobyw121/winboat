import { volumeTarget, type ComposeVolume } from './compose-volumes.ts';
/** Host image and Windows bundle are one versioned graphics stack. */
export const HELIOS_REVISION = 'd82ce565ac792eb48da5e59f2a82a12ff221851d';
// Guest source compatibility identity. The embedded installer, Windows build
// tools and guest/transport trees match this commit and the host snapshot.
// The bundled EXE's actual build provenance and hash live in stack.lock.json.
export const HELIOS_GUEST_REVISION = 'fecffde64fd32399a877b452332681ef0db7993e';
export const HELIOS_IMAGE = `winboat/helios:${HELIOS_REVISION.slice(0, 12)}`;
export const HELIOS_LABEL = 'org.winboat.helios.revision';
export const HELIOS_RUNTIME_LABEL = 'org.winboat.helios.runtime';
export const HELIOS_RUNTIME_VERSION = 'glvnd-v4';
export const LEGACY_WINDOWS_IMAGE = 'ghcr.io/dockur/windows:5.07';
export type HeliosStatus = 'waiting' | 'test-signing-restart-required' | 'driver-restart-required' | 'finished' | 'failed';
export type HeliosProgress = { status: HeliosStatus; revision: string; installed: boolean; message?: string };

export function validateHeliosProgress(value: unknown): HeliosProgress {
    const progress = value as HeliosProgress;
    if (!progress || progress.revision !== HELIOS_GUEST_REVISION) throw new Error('Windows Helios driver and host image revisions do not match.');
    if (!['waiting', 'test-signing-restart-required', 'driver-restart-required', 'finished', 'failed'].includes(progress.status)) {
        throw new Error('Windows returned an invalid Helios provisioning state.');
    }
    if (progress.status === 'finished' && progress.installed !== true) throw new Error('Helios reports completion without an installed driver.');
    if (progress.status === 'failed') throw new Error(`Helios installation failed: ${progress.message || 'See the Windows Helios setup log.'}`);
    return progress;
}

/** Preserve unrelated VM arguments, volumes and device mappings. */
export function configureHelios<T extends { image: string; environment: Record<string, string>; devices: string[]; volumes?: ComposeVolume[]; gpus?: string; pull_policy?: string }>(
    service: T, enabled: boolean, renderNode?: string, nvidia = false,
): T {
    // Compose data is JSON-compatible. JSON cloning also unwraps nested Vue
    // proxies (such as the installer's ports), which structuredClone rejects.
    const next = JSON.parse(JSON.stringify(service)) as T;
    delete next.environment.VIRGL;
    next.devices = next.devices.filter(device => device !== '/dev/dri:/dev/dri');
    if (enabled) {
        if (!renderNode || !/^\/dev\/dri\/renderD\d+$/.test(renderNode)) throw new Error('Helios requires a DRM render node.');
        next.image = HELIOS_IMAGE;
        next.pull_policy = 'never'; // A locally built, pinned stack; never pull an unrelated image.
        next.environment.HELIOS = '1';
        next.environment.HELIOS_REVISION = HELIOS_REVISION;
        next.environment.RENDERNODE = renderNode;
        next.environment.GPU = 'N'; // dockur's Intel passthrough path is not Helios.
        if (!next.devices.includes('/dev/dri:/dev/dri')) next.devices.push('/dev/dri:/dev/dri');
        if (nvidia) {
            next.gpus = 'all';
            next.environment.HELIOS_GPU_VENDOR = 'nvidia';
            next.environment.NVIDIA_VISIBLE_DEVICES = 'all';
            next.environment.NVIDIA_DRIVER_CAPABILITIES = 'graphics,utility,compute,display';
        }
    } else {
        if (next.image === HELIOS_IMAGE) next.image = LEGACY_WINDOWS_IMAGE;
        if (next.environment.HELIOS === '1') {
            delete next.gpus;
            delete next.pull_policy;
            for (const key of ['RENDERNODE', 'HELIOS_GPU_VENDOR', 'NVIDIA_VISIBLE_DEVICES', 'NVIDIA_DRIVER_CAPABILITIES', 'GPU']) delete next.environment[key];
        }
        delete next.environment.HELIOS;
        delete next.environment.HELIOS_REVISION;
        delete next.environment.HELIOS_DISPLAY;
        if (next.volumes) next.volumes = next.volumes.filter(volume => volumeTarget(volume) !== '/run/helios-display');
    }
    return next;
}
