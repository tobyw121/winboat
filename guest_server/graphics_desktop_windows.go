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
// service. Explicitly attach this worker to WinSta0\Default; merely having the
// right session ID is insufficient. Attaching does not switch the visible desktop.
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

func consoleSessionToken(session uint32) (windows.Token, error) {
	if session == 0 || session == 0xffffffff || session != windows.WTSGetActiveConsoleSessionId() {
		return 0, desktopProbeError("no-interactive-console-session")
	}
	var token windows.Token
	if err := windows.WTSQueryUserToken(session, &token); err == nil {
		return token, nil
	}
	// Before logon there is no user token. The SYSTEM service may launch only
	// this fixed worker in the console session to restore the sign-in display.
	// A normal user cannot acquire SYSTEM or choose another session this way.
	var current windows.Token
	if err := windows.OpenProcessToken(windows.CurrentProcess(), windows.TOKEN_QUERY|windows.TOKEN_DUPLICATE, &current); err != nil {
		return 0, desktopProbeError("console-user-token-unavailable")
	}
	defer current.Close()
	user, err := current.GetTokenUser()
	if err != nil || !user.User.Sid.IsWellKnown(windows.WinLocalSystemSid) {
		return 0, desktopProbeError("console-user-token-unavailable")
	}
	access := uint32(windows.TOKEN_QUERY | windows.TOKEN_DUPLICATE | windows.TOKEN_ASSIGN_PRIMARY | windows.TOKEN_ADJUST_SESSIONID)
	if err = windows.DuplicateTokenEx(current, access, nil, windows.SecurityImpersonation, windows.TokenPrimary, &token); err != nil {
		return 0, desktopProbeError("console-logon-token-unavailable")
	}
	if err = windows.SetTokenInformation(token, windows.TokenSessionId, (*byte)(unsafe.Pointer(&session)), 4); err != nil {
		token.Close()
		return 0, desktopProbeError("console-logon-session-unavailable")
	}
	return token, nil
}

// Run inside the actual console user's session. Session 0 (the API service)
// cannot describe the user's display topology. Never fall back to its view,
// and never query an unrelated RDP user's displays.
func collectConsoleDesktop(ctx context.Context) (desktopSnapshot, error) {
	return collectConsoleDesktopAction(ctx, "probe")
}
func collectConsoleDesktopAction(ctx context.Context, action string) (desktopSnapshot, error) {
	var result desktopSnapshot
	arguments := map[string]string{"probe": "--display-session-probe", "extend": "--display-session-extend", "clone": "--display-session-clone", "basic": "--display-session-basic"}
	argument, ok := arguments[action]
	if !ok {
		return result, desktopProbeError("unknown-display-operation")
	}
	session := windows.WTSGetActiveConsoleSessionId()
	if session == 0xffffffff || session == 0 {
		return result, desktopProbeError("no-interactive-console-session")
	}
	token, err := consoleSessionToken(session)
	if err != nil {
		return result, err
	}
	defer token.Close()
	executable, err := os.Executable()
	if err != nil {
		return result, err
	}
	cmd := exec.CommandContext(ctx, executable, argument)
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
	if result.SessionID != session || session != windows.WTSGetActiveConsoleSessionId() {
		return desktopSnapshot{}, desktopProbeError("console-session-changed")
	}
	return result, nil
}

func queryConsoleDesktop() (desktopSnapshot, error) {
	return consoleDesktopOperation("probe")
}
func consoleDesktopOperation(action string) (desktopSnapshot, error) {
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
	result, err = readConsoleDesktop(session)
	if err != nil {
		return result, err
	}
	if action == "probe" {
		return result, nil
	}
	if action != "clone" && action != "basic" && action != "extend" {
		return result, fmt.Errorf("unknown-display-operation")
	}
	changeErr := applyCCD(action)
	after, readErr := readConsoleDesktop(session)
	if readErr != nil {
		return desktopSnapshot{SessionID: session, Managed: result.Managed, ChangeError: "display-change-could-not-be-verified", Helios: desktopOutput{State: "unknown"}, Basic: desktopOutput{State: "unknown"}}, nil
	}
	if changeErr != nil {
		after.ChangeError = changeErr.Error()
	} else if (action == "extend" && (!extendedDesktop(after) || after.Basic.Primary != result.Basic.Primary)) || (action == "clone" && !clonedDesktop(after)) || (action == "basic" && !basicDesktop(after)) {
		after.ChangeError = "display-change-not-confirmed"
	}
	return after, nil
}
func displayRole(id string) string {
	id = strings.ToUpper(id)
	// EnumDisplayDevices uses PCI\VEN_; CCD adapter paths use PCI#VEN_.
	if strings.Contains(id, `PCI\VEN_1AF4&DEV_1050`) || strings.Contains(id, `PCI#VEN_1AF4&DEV_1050`) {
		return "helios"
	}
	if strings.Contains(id, `PCI\VEN_1234&DEV_1111`) || strings.Contains(id, `PCI#VEN_1234&DEV_1111`) {
		return "basic"
	}
	return ""
}
func readConsoleDesktop(session uint32) (desktopSnapshot, error) {
	result := desktopSnapshot{SessionID: session, Helios: desktopOutput{State: "inactive"}, Basic: desktopOutput{State: "inactive"}}
	count := 0
	for index := uint32(0); index < 64; index++ {
		device := nativeDisplayDevice{Size: uint32(unsafe.Sizeof(nativeDisplayDevice{}))}
		ok, _, _ := enumDisplayDevices.Call(0, uintptr(index), uintptr(unsafe.Pointer(&device)), 0)
		if ok == 0 {
			break
		}
		count++
		role := displayRole(windows.UTF16ToString(device.ID[:]))
		var output *desktopOutput
		if role == "helios" {
			output = &result.Helios
		}
		if role == "basic" {
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
	if err := augmentCCD(&result); err != nil {
		return result, err
	}
	if count == 0 && !result.Managed {
		return result, fmt.Errorf("Windows returned no managed display targets")
	}
	return result, nil
}
func runDisplaySessionProbe(action string) {
	result, err := consoleDesktopOperation(action)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if err = json.NewEncoder(os.Stdout).Encode(result); err != nil {
		os.Exit(1)
	}
}
