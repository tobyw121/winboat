//go:build windows

package main

import (
	"fmt"
	"golang.org/x/sys/windows"
	"runtime"
	"unsafe"
)

var displayUser32 = windows.NewLazySystemDLL("user32.dll")
var displayBufferSizes = displayUser32.NewProc("GetDisplayConfigBufferSizes")
var queryDisplayConfig = displayUser32.NewProc("QueryDisplayConfig")
var displayDeviceInfo = displayUser32.NewProc("DisplayConfigGetDeviceInfo")
var setDisplayConfig = displayUser32.NewProc("SetDisplayConfig")

func readCCD(flags uint32) ([]ccdPath, []ccdMode, error) {
	for attempt := 0; attempt < 3; attempt++ {
		var paths, modes uint32
		code, _, _ := displayBufferSizes.Call(uintptr(flags), uintptr(unsafe.Pointer(&paths)), uintptr(unsafe.Pointer(&modes)))
		if uint32(code) != 0 {
			return nil, nil, fmt.Errorf("display-buffer-sizes-%d", uint32(code))
		}
		if paths > 128 || modes > 512 {
			return nil, nil, fmt.Errorf("display-topology-too-large")
		}
		if paths == 0 {
			return nil, nil, nil
		}
		pathData := make([]ccdPath, paths)
		modeData := make([]ccdMode, modes)
		var pathPtr, modePtr unsafe.Pointer
		if paths > 0 {
			pathPtr = unsafe.Pointer(&pathData[0])
		}
		if modes > 0 {
			modePtr = unsafe.Pointer(&modeData[0])
		}
		code, _, _ = queryDisplayConfig.Call(uintptr(flags), uintptr(unsafe.Pointer(&paths)), uintptr(pathPtr), uintptr(unsafe.Pointer(&modes)), uintptr(modePtr), 0)
		runtime.KeepAlive(pathData)
		runtime.KeepAlive(modeData)
		if uint32(code) == 122 {
			continue
		} // ERROR_INSUFFICIENT_BUFFER: topology changed
		if uint32(code) != 0 {
			return nil, nil, fmt.Errorf("query-display-config-%d", uint32(code))
		}
		if int(paths) > len(pathData) || int(modes) > len(modeData) {
			return nil, nil, fmt.Errorf("display-path-count-invalid")
		}
		return pathData[:paths], modeData[:modes], nil
	}
	return nil, nil, fmt.Errorf("display-topology-changing")
}
func ccdAdapterRole(id ccdLUID) string {
	info := ccdAdapterName{Kind: 4, Adapter: id}
	info.Size = uint32(unsafe.Sizeof(info))
	code, _, _ := displayDeviceInfo.Call(uintptr(unsafe.Pointer(&info)))
	if uint32(code) != 0 {
		return ""
	}
	return displayRole(windows.UTF16ToString(info.Path[:]))
}
func ccdRoutes(paths []ccdPath) []ccdRoute {
	roles := map[ccdLUID]string{}
	role := func(id ccdLUID) string {
		if value, ok := roles[id]; ok {
			return value
		}
		value := ccdAdapterRole(id)
		roles[id] = value
		return value
	}
	routes := make([]ccdRoute, 0, len(paths))
	for _, path := range paths {
		routes = append(routes, ccdRoute{Path: path, TargetRole: role(path.Target.Adapter), SourceRole: role(path.Source.Adapter)})
	}
	return routes
}
func augmentCCD(result *desktopSnapshot) error {
	all, modes, err := readCCD(0x11)
	if err != nil {
		return err
	} // QDC_ALL_PATHS | QDC_VIRTUAL_MODE_AWARE
	routes := ccdRoutes(all)
	result.Managed, result.CloneAvailable = managedRoutes(routes)
	// CCD targets, not GDI adapter flags, are authoritative for clone slaves.
	result.Helios.State = "inactive"
	result.Basic.State = "inactive"
	var basic, helios *ccdPath
	for _, route := range routes {
		if route.Path.Flags&1 == 0 {
			continue
		}
		var output *desktopOutput
		if route.TargetRole == "helios" {
			output = &result.Helios
			path := route.Path
			helios = &path
		}
		if route.TargetRole == "basic" {
			output = &result.Basic
			path := route.Path
			basic = &path
		}
		if output == nil {
			continue
		}
		output.State = "active"
		name := ccdSourceName{Kind: 1, Adapter: route.Path.Source.Adapter, ID: route.Path.Source.ID}
		name.Size = uint32(unsafe.Sizeof(name))
		code, _, _ := displayDeviceInfo.Call(uintptr(unsafe.Pointer(&name)))
		if uint32(code) == 0 {
			output.Name = windows.UTF16ToString(name.Name[:])
		}
	}
	result.Topology = "none"
	switch {
	case result.Basic.State == "active" && result.Helios.State == "active":
		result.Topology = "extend"
		if basic != nil && helios != nil && sameDesktopSources(*basic, *helios, modes) {
			result.Topology = "clone"
		}
	case result.Basic.State == "active":
		result.Topology = "basic"
	case result.Helios.State == "active":
		result.Topology = "helios"
	}
	return nil
}
func applyCCD(action string) error {
	paths, _, err := readCCD(0x11)
	if err != nil {
		return err
	}
	routes := ccdRoutes(paths)
	managed, cloneAvailable := managedRoutes(routes)
	if !managed {
		return fmt.Errorf("unmanaged-display-targets")
	}
	if action == "clone" {
		if !cloneAvailable {
			return fmt.Errorf("clone-display-target-unavailable")
		}
		// Let Windows negotiate a mutually supported clone mode. Do not fabricate
		// cross-adapter capabilities or enable unsupported driver registry knobs.
		code, _, _ := setDisplayConfig.Call(0, 0, 0, 0, 0x80|0x2) // SDC_APPLY | SDC_TOPOLOGY_CLONE
		if uint32(code) != 0 {
			return fmt.Errorf("clone-set-display-config-%d", uint32(code))
		}
		return nil
	}
	if action != "basic" {
		return fmt.Errorf("unknown-display-operation")
	}
	path, err := basicRoute(routes)
	if err != nil {
		return err
	}
	// A single supplied VGA path makes it the usable desktop, including the
	// primary origin. The Helios PnP driver remains installed and enabled.
	flags := uintptr(0x20 | 0x400)                                                           // SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_ALLOW_CHANGES
	code, _, _ := setDisplayConfig.Call(1, uintptr(unsafe.Pointer(&path)), 0, 0, flags|0x40) // SDC_VALIDATE
	if uint32(code) != 0 {
		return fmt.Errorf("basic-validate-display-config-%d", uint32(code))
	}
	code, _, _ = setDisplayConfig.Call(1, uintptr(unsafe.Pointer(&path)), 0, 0, flags|0x80|0x200) // APPLY | SAVE_TO_DATABASE
	if uint32(code) != 0 {
		return fmt.Errorf("basic-set-display-config-%d", uint32(code))
	}
	return nil
}
