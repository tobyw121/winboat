// Windows desktop acceptance probe. Requires the installed Helios KMD.
// Enumeration is read-only. --cycle temporarily changes each selected mode,
// verifies Windows' current mode, then restores the original mode on all exits.
// A successful API result is not proof that the host viewer displayed a frame.
#include <windows.h>
#include <cstdio>
#include <cwchar>
#include <set>
#include <utility>
#include <vector>
#include <stdexcept>

struct RestoreMode {
    const wchar_t* name;
    DEVMODEW mode;
    bool armed = false;
    LONG restore() {
        if (!armed) return DISP_CHANGE_SUCCESSFUL;
        const LONG result = ChangeDisplaySettingsExW(name, &mode, nullptr, 0, nullptr);
        if (result == DISP_CHANGE_SUCCESSFUL) armed = false;
        return result;
    }
    ~RestoreMode() {
        if (armed) {
            const LONG result = restore();
            if (result != DISP_CHANGE_SUCCESSFUL)
                std::fprintf(stderr, "Original mode restore failed: %ld\n", result);
        }
    }
};

int wmain(int argc, wchar_t** argv) {
    const bool cycle = argc == 2 && std::wcscmp(argv[1], L"--cycle") == 0;
    if (argc > 1 && !cycle) {
        std::fprintf(stderr, "Usage: helios-display-modes.exe [--cycle]\n");
        return 2;
    }
    DWORD session = 0;
    if (!ProcessIdToSessionId(GetCurrentProcessId(), &session) || session == 0) {
        std::fprintf(stderr, "Run inside the logged-in Windows desktop, not session 0.\n");
        return 2;
    }
    DISPLAY_DEVICEW device = {};
    bool found = false;
    for (DWORD i = 0;; ++i) {
        device = {}; device.cb = sizeof(device);
        if (!EnumDisplayDevicesW(nullptr, i, &device, 0)) break;
        if (std::wcsstr(device.DeviceString, L"Helios") &&
            (device.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP)) { found = true; break; }
    }
    if (!found) {
        std::fprintf(stderr, "No active Helios display. Refusing Basic/WARP fallback.\n");
        return 2;
    }
    DEVMODEW original = {}; original.dmSize = sizeof(original);
    if (!EnumDisplaySettingsExW(device.DeviceName, ENUM_CURRENT_SETTINGS, &original, 0)) {
        std::fprintf(stderr, "Cannot query the original mode: %lu\n", GetLastError());
        return 2;
    }
    std::printf("Helios %ls current=%lux%lu @ %lu Hz\n", device.DeviceName,
                 original.dmPelsWidth, original.dmPelsHeight, original.dmDisplayFrequency);
    RestoreMode restore { device.DeviceName, original };
    try {
        std::vector<DEVMODEW> modes;
        std::set<std::pair<DWORD,DWORD>> sizes;
        for (DWORD index = 0;; ++index) {
            DEVMODEW mode = {}; mode.dmSize = sizeof(mode);
            if (!EnumDisplaySettingsExW(device.DeviceName, index, &mode, 0)) break;
            if (mode.dmBitsPerPel != 32 || mode.dmDisplayFrequency != 60 ||
                mode.dmDisplayOrientation != DMDO_DEFAULT || (mode.dmDisplayFlags & DM_INTERLACED)) continue;
            if (!sizes.emplace(mode.dmPelsWidth, mode.dmPelsHeight).second) continue;
            std::printf("Enumerated: %lux%lu @ 60 Hz\n", mode.dmPelsWidth, mode.dmPelsHeight);
            modes.push_back(mode);
        }
        const std::pair<DWORD,DWORD> expected[] = {
            {1024,768},{1280,720},{1280,800},{1366,768},{1440,900},{1600,900},
            {1920,1080},{1920,1200},{2560,1440},{2560,1600},{3840,2160}
        };
        for (const auto& size : expected) {
            if (!sizes.count(size)) {
                std::fprintf(stderr,"Missing advertised mode: %lux%lu\n",size.first,size.second);
                throw std::runtime_error("Helios multi-mode enumeration incomplete.");
            }
        }
        if (!cycle) {
            std::printf("All 11 presets enumerated. --cycle also exercises temporary live switches.\n");
            return 0;
        }
        // Both upward and downward transitions; never persist them in the registry.
        for (unsigned pass = 0; pass < 2; ++pass) for (size_t i=0; i<modes.size(); ++i) {
            auto mode = modes[pass ? modes.size()-1-i : i];
            // Keep the display's current desktop position, including negative coordinates.
            mode.dmPosition = original.dmPosition;
            mode.dmFields = DM_POSITION | DM_PELSWIDTH | DM_PELSHEIGHT | DM_BITSPERPEL |
                            DM_DISPLAYFREQUENCY | DM_DISPLAYORIENTATION;
            const LONG test = ChangeDisplaySettingsExW(device.DeviceName,&mode,nullptr,CDS_TEST,nullptr);
            if (test != DISP_CHANGE_SUCCESSFUL) {
                std::fprintf(stderr,"CDS_TEST %lux%lu failed: %ld (clone topology may constrain the mode)\n",
                             mode.dmPelsWidth,mode.dmPelsHeight,test);
                throw std::runtime_error("Requested live mode was refused.");
            }
            restore.armed = true;
            const LONG changed = ChangeDisplaySettingsExW(device.DeviceName,&mode,nullptr,0,nullptr);
            if (changed != DISP_CHANGE_SUCCESSFUL) {
                std::fprintf(stderr,"Mode change failed: %ld\n",changed);
                throw std::runtime_error("Live mode switch failed.");
            }
            Sleep(2500);
            DEVMODEW actual = {}; actual.dmSize=sizeof(actual);
            if (!EnumDisplaySettingsExW(device.DeviceName,ENUM_CURRENT_SETTINGS,&actual,0) ||
                actual.dmPelsWidth != mode.dmPelsWidth || actual.dmPelsHeight != mode.dmPelsHeight) {
                throw std::runtime_error("Windows current mode differs from the requested mode.");
            }
            std::printf("Switched without reboot: %lux%lu\n",actual.dmPelsWidth,actual.dmPelsHeight);
        }
        if (restore.restore() != DISP_CHANGE_SUCCESSFUL)
            throw std::runtime_error("Could not restore original display mode.");
        std::puts("All upward/downward mode switches and original-mode restoration completed.");
        return 0;
    } catch (const std::exception& e) {
        std::fprintf(stderr,"%s\n",e.what());
        return 1;
    }
}
