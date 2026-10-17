//go:build windows

package main

import (
	"fmt"
	"unsafe"

	"golang.org/x/sys/windows"
)

var wtsAPI = windows.NewLazySystemDLL("wtsapi32.dll")
var enumerateSessions = wtsAPI.NewProc("WTSEnumerateSessionsW")
var querySession = wtsAPI.NewProc("WTSQuerySessionInformationW")
var freeSessionMemory = wtsAPI.NewProc("WTSFreeMemory")

type nativeSession struct {
	ID    uint32
	Name  *uint16
	State uint32
}

func activeRDPConnected() (bool, error) {
	var buffer uintptr
	var count uint32
	ok, _, err := enumerateSessions.Call(0, 0, 1, uintptr(unsafe.Pointer(&buffer)), uintptr(unsafe.Pointer(&count)))
	if ok == 0 {
		return false, fmt.Errorf("enumerate Windows sessions: %w", err)
	}
	defer freeSessionMemory.Call(buffer)
	sessions := make([]terminalSession, 0, count)
	for _, s := range unsafe.Slice((*nativeSession)(unsafe.Pointer(buffer)), int(count)) {
		sessions = append(sessions, terminalSession{ID: s.ID, State: s.State})
	}
	return hasActiveRDP(sessions, func(id uint32) (uint16, error) {
		var data uintptr
		var size uint32
		// WTSClientProtocolType = 16, returned as USHORT.
		ok, _, err := querySession.Call(0, uintptr(id), 16, uintptr(unsafe.Pointer(&data)), uintptr(unsafe.Pointer(&size)))
		if ok == 0 {
			return 0, fmt.Errorf("query Windows session protocol: %w", err)
		}
		defer freeSessionMemory.Call(data)
		if data == 0 || size < 2 {
			return 0, fmt.Errorf("invalid Windows session protocol response")
		}
		return *(*uint16)(unsafe.Pointer(data)), nil
	})
}
