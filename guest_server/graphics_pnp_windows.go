//go:build windows

package main

import (
	"context"
	"fmt"
	"strings"

	"golang.org/x/sys/windows"
)

// Read-only native polling. PowerShell is reserved for an actual recovery,
// rather than starting WMI/PowerShell for every healthy five-second sample.
func collectNativeDisplayAdapters(ctx context.Context) (displayAdapters, error) {
	result := displayAdapters{Helios: displayAdapter{State: "missing"}, Basic: displayAdapter{State: "missing"}, Recovery: "none"}
	guid := windows.GUID{Data1: 0x4d36e968, Data2: 0xe325, Data3: 0x11ce, Data4: [8]byte{0xbf, 0xc1, 0x08, 0x00, 0x2b, 0xe1, 0x03, 0x18}}
	devices, err := windows.SetupDiGetClassDevsEx(&guid, "", 0, windows.DIGCF_PRESENT, 0, "")
	if err != nil {
		return result, err
	}
	defer devices.Close()
	for index := 0; index < 128; index++ {
		if err = ctx.Err(); err != nil {
			return result, err
		}
		device, queryErr := devices.EnumDeviceInfo(index)
		if queryErr == windows.ERROR_NO_MORE_ITEMS {
			return result, nil
		}
		if queryErr != nil {
			return result, queryErr
		}
		id, queryErr := devices.DeviceInstanceID(device)
		if queryErr != nil {
			return result, queryErr
		}
		var adapter *displayAdapter
		expected := ""
		switch {
		case strings.HasPrefix(strings.ToUpper(id), `PCI\VEN_1AF4&DEV_1050`):
			adapter = &result.Helios
			expected = "helios_kmd_render"
		case strings.HasPrefix(strings.ToUpper(id), `PCI\VEN_1234&DEV_1111`):
			adapter = &result.Basic
			expected = "BasicDisplay"
		default:
			continue
		}
		if adapter.InstanceID != "" {
			return result, fmt.Errorf("ambiguous WinBoat display devices")
		}
		service, queryErr := devices.DeviceRegistryProperty(device, windows.SPDRP_SERVICE)
		if queryErr != nil {
			return result, queryErr
		}
		name, ok := service.(string)
		if !ok {
			return result, fmt.Errorf("invalid display service property")
		}
		var flags, problem uint32
		if queryErr = windows.CM_Get_DevNode_Status(&flags, &problem, device.DevInst, 0); queryErr != nil {
			return result, queryErr
		}
		state := "running"
		switch {
		case problem == 22:
			state = "disabled"
		case problem != 0:
			state = "failed"
		case !strings.EqualFold(name, expected):
			state = "missing"
		case flags&windows.DN_STARTED == 0:
			state = "unknown"
		}
		*adapter = displayAdapter{State: state, InstanceID: id, ProblemCode: int(problem), Service: name}
	}
	return result, fmt.Errorf("display enumeration limit exceeded")
}
