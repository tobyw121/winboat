//go:build windows

package main

import (
	"encoding/base64"
	"fmt"
	"golang.org/x/sys/windows"
	"unsafe"
)

// Explicit bounded PNG/DIB exchange. Compressed/paletted DIB layouts are refused.
func clipboardPNGFormat() uintptr {
	name, _ := windows.UTF16PtrFromString("PNG")
	format, _, _ := clipUser32.NewProc("RegisterClipboardFormatW").Call(uintptr(unsafe.Pointer(name)))
	return format
}
func readClipboardPNG(hwnd uintptr) (string, error) {
	if !clipboardDesktopUnlocked() {
		return "", fmt.Errorf("locked")
	}
	ok, _, _ := clipOpen.Call(hwnd)
	if ok == 0 {
		return "", fmt.Errorf("busy")
	}
	defer clipClose.Call()
	format := clipboardPNGFormat()
	if format == 0 {
		return "", fmt.Errorf("format unavailable")
	}
	handle, _, _ := clipUser32.NewProc("GetClipboardData").Call(format)
	bitmap := false
	if handle == 0 {
		handle, _, _ = clipUser32.NewProc("GetClipboardData").Call(8)
		bitmap = true
	}
	if handle == 0 {
		return "", fmt.Errorf("no supported clipboard image")
	}
	size, _, _ := clipKernel.NewProc("GlobalSize").Call(handle)
	if size == 0 || size > 40+8*1024*1024*4 || (!bitmap && size > clipboardImageLimit) {
		return "", fmt.Errorf("image too large")
	}
	pointer, _, _ := clipGlobalLock.Call(handle)
	if pointer == 0 {
		return "", fmt.Errorf("unavailable")
	}
	defer clipGlobalUnlock.Call(handle)
	raw := unsafe.Slice((*byte)(unsafe.Pointer(pointer)), int(size))
	if bitmap {
		var err error
		raw, err = clipboardDIBToPNG(raw)
		if err != nil {
			return "", err
		}
	}
	encoded := base64.StdEncoding.EncodeToString(raw)
	if !validClipboardPNG(encoded) {
		return "", fmt.Errorf("invalid PNG")
	}
	return encoded, nil
}
func writeClipboardPNG(hwnd uintptr, value string) error {
	if !clipboardDesktopUnlocked() || !validClipboardPNG(value) {
		return fmt.Errorf("image or desktop unavailable")
	}
	data, _ := base64.StdEncoding.DecodeString(value)
	dib, err := clipboardPNGToDIB(data)
	if err != nil {
		return err
	}
	handle, _, _ := clipKernel.NewProc("GlobalAlloc").Call(2, uintptr(len(data)))
	if handle == 0 {
		return fmt.Errorf("allocation failed")
	}
	owned := true
	defer func() {
		if owned {
			clipKernel.NewProc("GlobalFree").Call(handle)
		}
	}()
	pointer, _, _ := clipGlobalLock.Call(handle)
	if pointer == 0 {
		return fmt.Errorf("lock failed")
	}
	copy(unsafe.Slice((*byte)(unsafe.Pointer(pointer)), len(data)), data)
	clipGlobalUnlock.Call(handle)
	ok, _, _ := clipOpen.Call(hwnd)
	if ok == 0 {
		return fmt.Errorf("busy")
	}
	defer clipClose.Call()
	format := clipboardPNGFormat()
	if format == 0 {
		return fmt.Errorf("format unavailable")
	}
	ok, _, _ = clipUser32.NewProc("EmptyClipboard").Call()
	if ok == 0 {
		return fmt.Errorf("empty failed")
	}
	ok, _, _ = clipUser32.NewProc("SetClipboardData").Call(format, handle)
	if ok == 0 {
		return fmt.Errorf("write failed")
	}
	owned = false
	// Publish a DIB representation for applications that do not understand PNG.
	bitmap, _, _ := clipKernel.NewProc("GlobalAlloc").Call(2, uintptr(len(dib)))
	if bitmap != 0 {
		p, _, _ := clipGlobalLock.Call(bitmap)
		if p != 0 {
			copy(unsafe.Slice((*byte)(unsafe.Pointer(p)), len(dib)), dib)
			clipGlobalUnlock.Call(bitmap)
			result, _, _ := clipUser32.NewProc("SetClipboardData").Call(8, bitmap)
			if result != 0 {
				return nil
			}
		}
		clipKernel.NewProc("GlobalFree").Call(bitmap)
	}
	return nil
}
