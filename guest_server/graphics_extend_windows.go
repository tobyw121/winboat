//go:build windows

package main

import (
	"fmt"
	"runtime"
	"unsafe"

	"golang.org/x/sys/windows"
)

var enumDisplaySettings = displayUser32.NewProc("EnumDisplaySettingsExW")
var changeDisplaySettings = displayUser32.NewProc("ChangeDisplaySettingsExW")

func readDisplayMode(name *uint16, index uint32) (displayMode, error) {
	mode := displayMode{Size: uint16(unsafe.Sizeof(displayMode{}))}
	ok, _, _ := enumDisplaySettings.Call(uintptr(unsafe.Pointer(name)), uintptr(index), uintptr(unsafe.Pointer(&mode)), 0)
	if ok == 0 || mode.DriverExtra != 0 || mode.Size != uint16(unsafe.Sizeof(mode)) {
		return mode, fmt.Errorf("display-mode-unavailable-or-extra-data-required")
	}
	return mode, nil
}

// Change only the physical Helios GDI adapter. A cloned CCD target may point
// at the VGA source name, so never use that target's name as an edit destination.
func extendHeliosDesktop() error {
	var basic, helios *uint16
	for i := uint32(0); i < 64; i++ {
		device := nativeDisplayDevice{Size: uint32(unsafe.Sizeof(nativeDisplayDevice{}))}
		ok, _, _ := enumDisplayDevices.Call(0, uintptr(i), uintptr(unsafe.Pointer(&device)), 0)
		if ok == 0 {
			break
		}
		role := displayRole(windows.UTF16ToString(device.ID[:]))
		if role == "" {
			if device.Flags&1 == 0 || device.Flags&8 != 0 {
				continue
			}
			return fmt.Errorf("unmanaged-display-adapter")
		}
		name, err := windows.UTF16PtrFromString(windows.UTF16ToString(device.Name[:]))
		if err != nil {
			return fmt.Errorf("invalid-display-name")
		}
		if role == "basic" {
			if basic != nil || device.Flags&1 == 0 {
				return fmt.Errorf("active-vga-not-unique")
			}
			basic = name
		} else {
			if device.Flags&4 != 0 {
				return fmt.Errorf("helios-primary-layout-requires-manual-change")
			}
			if helios != nil {
				return fmt.Errorf("helios-not-unique")
			}
			helios = name
		}
	}
	if basic == nil || helios == nil {
		return fmt.Errorf("display-adapter-missing")
	}
	before, err := readDisplayMode(basic, 0xffffffff) // ENUM_CURRENT_SETTINGS
	if err != nil {
		return err
	}
	mode, err := readDisplayMode(helios, 0xffffffff)
	if err != nil || mode.Width == 0 || mode.Height == 0 {
		mode, err = readDisplayMode(helios, 0xfffffffe) // ENUM_REGISTRY_SETTINGS
	}
	if err != nil || mode.Width == 0 || mode.Height == 0 {
		mode, err = readDisplayMode(helios, 0)
	}
	if err != nil {
		return err
	}
	mode, err = extendedHeliosMode(mode, before)
	if err != nil {
		return err
	}
	// CDS_TEST first, then only this adapter; no SET_PRIMARY, global topology,
	// VGA mode writes, device disable/enable, or global reset calls.
	for _, flags := range []uintptr{2, 1} { // CDS_TEST; CDS_UPDATEREGISTRY
		code, _, _ := changeDisplaySettings.Call(uintptr(unsafe.Pointer(helios)), uintptr(unsafe.Pointer(&mode)), 0, flags, 0)
		runtime.KeepAlive(mode)
		if int32(code) != 0 {
			return fmt.Errorf("helios-extend-display-settings-%d", int32(code))
		}
	}
	runtime.KeepAlive(helios)
	after, err := readDisplayMode(basic, 0xffffffff)
	runtime.KeepAlive(basic)
	if err != nil || !sameDisplayMode(before, after) {
		return fmt.Errorf("vga-mode-changed-or-unverifiable")
	}
	return nil
}
