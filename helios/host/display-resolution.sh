# Sourced by display.sh before forming QEMU arguments. Only known numeric
# presets are allowed; these values are never executable shell fragments.
: "${HELIOS_DISPLAY_WIDTH:=1280}"
: "${HELIOS_DISPLAY_HEIGHT:=800}"
case "$HELIOS_DISPLAY_WIDTH:$HELIOS_DISPLAY_HEIGHT" in
    1024:768|1280:720|1280:800|1366:768|1440:900|1600:900|1920:1080|1920:1200|2560:1440|2560:1600|3840:2160) ;;
    *) echo 'Invalid Helios display resolution. Select a supported preset in WinBoat Configuration.' >&2; exit 1 ;;
esac
