import { volumeTarget, type ComposeVolume } from './compose-volumes.ts';
export const HELIOS_DISPLAY_CAPABILITY = 'org.winboat.helios.display';
export const HELIOS_DISPLAY_VERSION = 'dbus-v9';
export const HELIOS_DISPLAY_MOUNT = '/run/helios-display';

export function heliosDisplayDirectory(uid: number, runtime?: string): string {
    if (!Number.isSafeInteger(uid) || uid < 0) throw new Error('Invalid display user ID.');
    if (runtime && (!/^\/[A-Za-z0-9_./-]+$/.test(runtime) || runtime.split('/').includes('..'))) {
        throw new Error('Unsupported XDG_RUNTIME_DIR for the local display.');
    }
    const directory = runtime ? `${runtime.replace(/\/$/, '')}/winboat-helios` : `/tmp/winboat-helios-${uid}`;
    if (directory.length > 85) throw new Error('Local display socket path is too long.');
    return directory;
}

export function heliosDisplayAddress(directory: string): string {
    return `unix:path=${encodeURIComponent(`${directory}/bus`)}`;
}

export function heliosDisplayBusConfig(directory: string, uid: number): string {
    if (!Number.isSafeInteger(uid) || uid < 0) throw new Error('Invalid display user ID.');
    const address = heliosDisplayAddress(directory);
    return `<busconfig><type>session</type><listen>${address}</listen><auth>EXTERNAL</auth>
<policy context="default"><allow user="${uid}"/><allow user="root"/>
<deny own="*"/><deny send_destination="*"/><deny receive_sender="*"/></policy>
<policy user="${uid}"><allow send_destination="*"/><allow receive_sender="*"/></policy>
<policy user="root"><allow own="org.qemu"/><allow send_destination="*"/><allow receive_sender="*"/></policy>
</busconfig>`;
}

export function configureHeliosDisplay<T extends { environment: Record<string, string>; volumes: ComposeVolume[] }>(
    service: T, enabled: boolean, directory?: string,
): T {
    // Settings pass a Vue-reactive service; clone its plain Compose data,
    // including nested proxies, before changing mounts or environment values.
    const next = JSON.parse(JSON.stringify(service)) as T;
    next.volumes = next.volumes.filter(volume => volumeTarget(volume) !== HELIOS_DISPLAY_MOUNT);
    delete next.environment.HELIOS_DISPLAY;
    if (!enabled) delete next.environment.HELIOS_AUDIO_DBUS;
    if (enabled) {
        if (next.environment.HELIOS !== '1') throw new Error('Local display requires Helios.');
        if (!directory || !/^\/[A-Za-z0-9_./-]+$/.test(directory) || directory.split('/').includes('..')) {
            throw new Error('Invalid local display directory.');
        }
        next.volumes.push(`${directory}:${HELIOS_DISPLAY_MOUNT}:ro`);
        next.environment.HELIOS_DISPLAY = 'dbus';
    }
    return next;
}

export async function preferHeliosDisplay<T extends { environment: Record<string, string>; volumes: ComposeVolume[]; restart: string }>(
    service: T, preferred: boolean | undefined, directory: () => string, prepare: (candidate: T) => Promise<void>,
): Promise<T> {
    if (service.environment.HELIOS !== '1' || preferred === false) return service;
    const candidate = configureHeliosDisplay(service, true, directory());
    candidate.restart = 'no';
    await prepare(candidate);
    return candidate;
}

/** Resolve a saved preference without overwriting it when the runtime is absent. */
export async function resolveHeliosDisplay<T extends { environment: Record<string, string>; volumes: ComposeVolume[]; restart: string }>(
    service: T, preferred: boolean, directory: () => string, prepare: (candidate: T) => Promise<void>,
): Promise<{ service: T; unavailableReason: string }> {
    if (!preferred || service.environment.HELIOS !== '1') {
        return { service: configureHeliosDisplay(service, false), unavailableReason: '' };
    }
    try {
        return { service: await preferHeliosDisplay(service, true, directory, prepare), unavailableReason: '' };
    } catch (error) {
        const fallback = configureHeliosDisplay(service, false);
        fallback.restart = 'no';
        return { service: fallback, unavailableReason: error instanceof Error ? error.message : String(error) };
    }
}
