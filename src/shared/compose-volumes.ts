/** Compose accepts both short mounts and structured mounts for arbitrary paths. */
export type ComposeVolume = string | {
    type: 'bind' | 'volume' | 'tmpfs';
    source?: string;
    target: string;
    read_only?: boolean;
    bind?: { create_host_path?: boolean; [key: string]: unknown };
    [key: string]: unknown;
};
function parts(volume: string): string[] {
    const fields = volume.split(':');
    if (fields.length > 1 && /^(?:ro|rw|z|Z|cached|delegated|consistent|r?shared|r?slave|r?private)(?:,.*)?$/.test(fields.at(-1)!)) fields.pop();
    return fields;
}
export function volumeTarget(volume: ComposeVolume): string {
    return typeof volume === 'string' ? parts(volume).at(-1)! : volume.target;
}
export function volumeSource(volume: ComposeVolume): string | undefined {
    if (typeof volume !== 'string') return volume.source;
    const fields = parts(volume);return fields.length > 1 ? fields.slice(0, -1).join(':') : undefined;
}
export function volumeReadOnly(volume: ComposeVolume): boolean {
    return typeof volume === 'string' ? volume.split(':').at(-1)!.split(',').includes('ro') : volume.read_only === true;
}
