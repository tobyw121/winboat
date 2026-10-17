//go:build windows

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

var enumDisplayDevices = windows.NewLazySystemDLL("user32.dll").NewProc("EnumDisplayDevicesW")

// CreateProcessAsUser may inherit a noninteractive window station from the
// service. Explicitly attach this read-only worker to WinSta0\Default; merely
// having the right session ID is insufficient. This does not switch the
// visible desktop, synthesize input, or change display configuration.
func attachConsoleDesktop() (func(), error) {
	user32 := windows.NewLazySystemDLL("user32.dll")
	getStation := user32.NewProc("GetProcessWindowStation")
	setStation := user32.NewProc("SetProcessWindowStation")
	closeStation := user32.NewProc("CloseWindowStation")
	getDesktop := user32.NewProc("GetThreadDesktop")
	setDesktop := user32.NewProc("SetThreadDesktop")
	closeDesktop := user32.NewProc("CloseDesktop")
	originalStation, _, _ := getStation.Call()
	originalDesktop, _, _ := getDesktop.Call(uintptr(windows.GetCurrentThreadId()))
	stationName, _ := windows.UTF16PtrFromString("WinSta0")
	station, _, err := user32.NewProc("OpenWindowStationW").Call(uintptr(unsafe.Pointer(stationName)), 0, 0x103)
	if station == 0 {
		return nil, fmt.Errorf("open console window station: %w", err)
	}
	ok, _, err := setStation.Call(station)
	if ok == 0 {
		closeStation.Call(station)
		return nil, fmt.Errorf("attach console window station: %w", err)
	}
	restoreStation := func() { setStation.Call(originalStation); closeStation.Call(station) }
	desktopName, _ := windows.UTF16PtrFromString("Default")
	desktop, _, err := user32.NewProc("OpenDesktopW").Call(uintptr(unsafe.Pointer(desktopName)), 0, 0, 0x81)
	if desktop == 0 {
		restoreStation()
		return nil, fmt.Errorf("open console desktop: %w", err)
	}
	ok, _, err = setDesktop.Call(desktop)
	if ok == 0 {
		closeDesktop.Call(desktop)
		restoreStation()
		return nil, fmt.Errorf("attach console desktop: %w", err)
	}
	return func() { setDesktop.Call(originalDesktop); closeDesktop.Call(desktop); restoreStation() }, nil
}

type nativeDisplayDevice struct {
	Size        uint32
	Name        [32]uint16
	Description [128]uint16
	Flags       uint32
	ID          [128]uint16
	Key         [128]uint16
}

// Run inside the actual console user's session. Session 0 (the API service)
// cannot describe the user's display topology. Never fall back to its view,
// and never query an unrelated RDP user's displays.
func collectConsoleDesktop(ctx context.Context) (desktopSnapshot, error) {
	var result desktopSnapshot
	session := windows.WTSGetActiveConsoleSessionId()
	if session == 0xffffffff || session == 0 {
		return result, desktopProbeError("no-interactive-console-session")
	}
	var token windows.Token
	if err := windows.WTSQueryUserToken(session, &token); err != nil {
		return result, desktopProbeError("console-user-token-unavailable")
	}
	defer token.Close()
	executable, err := os.Executable()
	if err != nil {
		return result, err
	}
	cmd := exec.CommandContext(ctx, executable, "--display-session-probe")
	cmd.SysProcAttr = &syscall.SysProcAttr{Token: syscall.Token(token), HideWindow: true}
	data, err := cmd.Output()
	if err != nil {
		return result, desktopProbeError("console-display-probe-failed")
	}
	if len(data) > 16384 {
		return result, desktopProbeError("console-display-probe-too-large")
	}
	if err = json.Unmarshal(data, &result); err != nil {
		return result, desktopProbeError("console-display-probe-invalid")
	}
	if result.SessionID != session {
		return desktopSnapshot{}, desktopProbeError("console-session-changed")
	}
	return result, nil
}

func queryConsoleDesktop() (desktopSnapshot, error) {
	var session uint32
	if err := windows.ProcessIdToSessionId(uint32(os.Getpid()), &session); err != nil {
		return desktopSnapshot{}, err
	}
	result := desktopSnapshot{SessionID: session, Helios: desktopOutput{State: "inactive"}, Basic: desktopOutput{State: "inactive"}}
	if session == 0 || session != windows.WTSGetActiveConsoleSessionId() {
		return result, fmt.Errorf("probe is outside the console session")
	}
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	restore, err := attachConsoleDesktop()
	if err != nil {
		return result, err
	}
	defer restore()
	count := 0
	for index := uint32(0); index < 64; index++ {
		device := nativeDisplayDevice{Size: uint32(unsafe.Sizeof(nativeDisplayDevice{}))}
		ok, _, _ := enumDisplayDevices.Call(0, uintptr(index), uintptr(unsafe.Pointer(&device)), 0)
		if ok == 0 {
			break
		}
		count++
		id := strings.ToUpper(windows.UTF16ToString(device.ID[:]))
		var output *desktopOutput
		if strings.HasPrefix(id, `PCI\VEN_1AF4&DEV_1050`) {
			output = &result.Helios
		}
		if strings.HasPrefix(id, `PCI\VEN_1234&DEV_1111`) {
			output = &result.Basic
		}
		if output == nil {
			continue
		}
		// DISPLAY_DEVICE_ATTACHED_TO_DESKTOP, excluding mirror drivers.
		active := device.Flags&1 != 0 && device.Flags&8 == 0
		if output.State == "active" {
			continue
		}
		output.Name = windows.UTF16ToString(device.Name[:])
		output.Primary = device.Flags&4 != 0
		if active {
			output.State = "active"
		}
	}
	if count == 0 {
		return result, fmt.Errorf("Windows returned no display devices")
	}
	return result, nil
}
func runDisplaySessionProbe() {
	result, err := queryConsoleDesktop()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if err = json.NewEncoder(os.Stdout).Encode(result); err != nil {
		os.Exit(1)
	}
}
