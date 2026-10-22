/** Also advertised by guest_server/graphics_monitor.go. */
export const GUEST_GRAPHICS_PROTOCOL = 'helios-watchdog-v21';
export const GUEST_RUNTIME_PROTOCOL = 'vcredist-v1';
export function guestNeedsUpdate(guest: {version:string;graphics_protocol?:string;runtime_protocol?:string}, appVersion:string): boolean {
    return guest.version !== appVersion || guest.graphics_protocol !== GUEST_GRAPHICS_PROTOCOL || guest.runtime_protocol !== GUEST_RUNTIME_PROTOCOL;
}
