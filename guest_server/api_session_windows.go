//go:build windows

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
	"os"
	"os/exec"
	"runtime"
	"syscall"
	"unsafe"
)

func apiSessionRequired() bool {
	key, err := registry.OpenKey(registry.LOCAL_MACHINE, `SOFTWARE\WinBoat\API`, registry.QUERY_VALUE)
	if err == registry.ErrNotExist {
		return false
	}
	if err != nil {
		return true
	}
	defer key.Close()
	value, _, err := key.GetIntegerValue("RequireSession")
	return err != registry.ErrNotExist && (err != nil || value == 1)
}
func apiConsoleIdentity() string {
	var token windows.Token
	session := windows.WTSGetActiveConsoleSessionId()
	if windows.WTSQueryUserToken(session, &token) != nil {
		return ""
	}
	defer token.Close()
	var info struct {
		TokenID          windows.LUID
		AuthenticationID windows.LUID
		Expiration       int64
		TokenType        uint32
		Impersonation    uint32
		DynamicCharged   uint32
		DynamicAvailable uint32
		GroupCount       uint32
		PrivilegeCount   uint32
		Modified         windows.LUID
	}
	var returned uint32
	if windows.GetTokenInformation(token, windows.TokenStatistics, (*byte)(unsafe.Pointer(&info)), uint32(unsafe.Sizeof(info)), &returned) != nil {
		return ""
	}
	return fmt.Sprintf("%d:%d:%d", session, info.AuthenticationID.HighPart, info.AuthenticationID.LowPart)
}
func apiSessionConsent(ctx context.Context, request apiPairRequest) error {
	var token windows.Token
	if err := windows.WTSQueryUserToken(windows.WTSGetActiveConsoleSessionId(), &token); err != nil {
		return err
	}
	defer token.Close()
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	cmd := exec.CommandContext(ctx, exe, "--api-session-agent")
	cmd.SysProcAttr = &syscall.SysProcAttr{Token: syscall.Token(token), HideWindow: true}
	data, _ := json.Marshal(request)
	cmd.Stdin = bytes.NewReader(data)
	return cmd.Run()
}
func runAPISessionAgent() {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	cleanup, err := attachConsoleDesktop()
	if err != nil {
		os.Exit(1)
	}
	defer cleanup()
	var request apiPairRequest
	if json.NewDecoder(os.Stdin).Decode(&request) != nil || !clipboardDesktopUnlocked() {
		os.Exit(1)
	}
	text, _ := windows.UTF16PtrFromString("Pair WinBoat API session?\n\nCompare this code with your Linux window: " + request.Code + "\n\nPermissions: " + fmt.Sprint(request.Scopes) + "\nExpires in 10 minutes or on sign-out. Do not accept an unexpected request.")
	title, _ := windows.UTF16PtrFromString("WinBoat API pairing")
	answer, _, _ := clipUser32.NewProc("MessageBoxW").Call(0, uintptr(unsafe.Pointer(text)), uintptr(unsafe.Pointer(title)), 0x00010000|0x00000100|0x00000004|0x00000020)
	if answer != 6 || !clipboardDesktopUnlocked() {
		os.Exit(1)
	}
}
