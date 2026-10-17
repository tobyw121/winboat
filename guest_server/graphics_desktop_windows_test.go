//go:build windows

package main

import (
	"golang.org/x/sys/windows"
	"os"
	"testing"
	"unsafe"
)

func TestNativeDisplayDeviceLayout(t *testing.T) {
	var device nativeDisplayDevice
	if unsafe.Sizeof(device) != 840 || unsafe.Offsetof(device.Flags) != 324 || unsafe.Offsetof(device.ID) != 328 {
		t.Fatal("DISPLAY_DEVICEW layout mismatch")
	}
}
func TestReadOnlyConsoleDisplayProbe(t *testing.T) {
	var session uint32
	if err := windows.ProcessIdToSessionId(uint32(os.Getpid()), &session); err != nil {
		t.Fatal(err)
	}
	if session == 0 || session != windows.WTSGetActiveConsoleSessionId() {
		t.Skip("Windows runner has no interactive console desktop")
	}
	result, err := queryConsoleDesktop()
	if err != nil {
		t.Fatal(err)
	}
	if result.SessionID != session {
		t.Fatal("queried a different session")
	}
}
