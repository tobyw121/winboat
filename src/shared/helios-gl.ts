export type HeliosGLAPI = 'gl' | 'gles';

/** NVIDIA may expose external EGL image samplers only in its GLES context.
 * Probe a second process before opening a viewer, keeping the same GPU. */
export async function selectHeliosGLAPI(probe: (api: HeliosGLAPI) => Promise<string>): Promise<HeliosGLAPI> {
    let desktop: string;
    try { desktop = await probe('gl'); }
    catch (desktopError) {
        try { await probe('gles'); return 'gles'; }
        catch { throw desktopError; }
    }
    const renderer = (text: string) => /renderer:\s*(.+?); backend:/.exec(text)?.[1];
    const gpu = renderer(desktop);
    if (!gpu || !/^NVIDIA\b/i.test(gpu) || desktop.includes('external-sampler=yes')) return 'gl';
    try {
        const embedded = await probe('gles');
        if (renderer(embedded) === gpu && embedded.includes('Presentation API: gles; external-sampler=yes')) return 'gles';
    } catch { /* Preserve working desktop GL when the optional GLES probe fails. */ }
    return 'gl';
}
