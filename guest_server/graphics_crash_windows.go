//go:build windows

package main

import (
	"golang.org/x/sys/windows"
	"time"
	"unsafe"
)

// Read existing Windows event metadata natively. No polling PowerShell processes.
// Only a short burst of DWM crashes in our own UMD/ICD authorizes isolation.
var eventAPI = windows.NewLazySystemDLL("wevtapi.dll")
var eventQuery = eventAPI.NewProc("EvtQuery")
var eventNext = eventAPI.NewProc("EvtNext")
var eventClose = eventAPI.NewProc("EvtClose")
var crashChecked time.Time
var crashCount int

func recentHeliosDwmCrashes(now time.Time) int {
	if !crashChecked.IsZero() && now.Sub(crashChecked) < 30*time.Second {
		return crashCount
	}
	crashChecked = now
	crashCount = 0
	channel, _ := windows.UTF16PtrFromString("Application")
	query, _ := windows.UTF16PtrFromString(`*[System[(EventID=1000) and TimeCreated[timediff(@SystemTime) <= 120000]]] and *[EventData[Data[@Name='AppName']='dwm.exe' and (Data[@Name='ModuleName']='vulkan_virtio.dll' or Data[@Name='ModuleName']='helios_umd.dll' or Data[@Name='ModuleName']='helios_umd12.dll')]]`)
	handle, _, _ := eventQuery.Call(0, uintptr(unsafe.Pointer(channel)), uintptr(unsafe.Pointer(query)), 0x201)
	if handle == 0 {
		return 0
	}
	defer eventClose.Call(handle)
	for crashCount < 3 {
		var event uintptr
		var returned uint32
		ok, _, _ := eventNext.Call(handle, 1, uintptr(unsafe.Pointer(&event)), 0, 0, uintptr(unsafe.Pointer(&returned)))
		if ok == 0 || returned != 1 {
			break
		}
		eventClose.Call(event)
		crashCount++
	}
	return crashCount
}
