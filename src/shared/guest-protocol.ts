/** Also advertised by guest_server/graphics_monitor.go. */
export const GUEST_GRAPHICS_PROTOCOL = 'helios-watchdog-v3';
export function guestNeedsUpdate(guest: {version:string;graphics_protocol?:string}, appVersion:string): boolean {
    return guest.version !== appVersion || guest.graphics_protocol !== GUEST_GRAPHICS_PROTOCOL;
}
