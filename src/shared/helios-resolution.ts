/** These startup extents fit Helios's base EDID and the viewer's buffer limits. */
export const HELIOS_RESOLUTIONS = [
    [1024, 768], [1280, 720], [1280, 800], [1366, 768], [1440, 900],
    [1600, 900], [1920, 1080], [1920, 1200], [2560, 1440], [2560, 1600], [3840, 2160],
].map(([width, height]) => ({width, height, key:`${width}x${height}`, label:`${width} × ${height}`}));
export const DEFAULT_HELIOS_RESOLUTION = '1280x800';

export function heliosResolution(service: {environment?:Record<string,string>}): string {
    const width = service.environment?.HELIOS_DISPLAY_WIDTH;
    const height = service.environment?.HELIOS_DISPLAY_HEIGHT;
    if (width === undefined && height === undefined) return DEFAULT_HELIOS_RESOLUTION;
    const key = `${width}x${height}`;
    if (!HELIOS_RESOLUTIONS.some(mode => mode.key === key)) throw new Error('Invalid saved Helios resolution.');
    return key;
}

export function configureHeliosResolution<T extends {environment:Record<string,string>}>(service:T, key:string):T {
    const mode = HELIOS_RESOLUTIONS.find(mode => mode.key === key);
    if (!mode) throw new Error('Choose a supported Helios resolution.');
    if (service.environment.HELIOS !== '1') throw new Error('Helios must be enabled before choosing its resolution.');
    return {...service, environment:{...service.environment,
        HELIOS_DISPLAY_WIDTH:String(mode.width), HELIOS_DISPLAY_HEIGHT:String(mode.height)}};
}
