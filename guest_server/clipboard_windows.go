//go:build windows

package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"golang.org/x/sys/windows"
	"os"
	"os/exec"
	"runtime"
	"sync"
	"syscall"
	"unsafe"
)

type nativeClipboardWorker struct {
	cmd   *exec.Cmd
	input *json.Encoder
	mu    sync.Mutex
}

func (w *nativeClipboardWorker) Send(m clipboardMessage) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.input.Encode(m)
}
func (w *nativeClipboardWorker) Close() {
	if w.cmd.Process != nil {
		w.cmd.Process.Kill()
	}
}
func launchClipboardWorker(policy clipboardPolicy, emit func(clipboardMessage)) (clipboardWorker, error) {
	session := windows.WTSGetActiveConsoleSessionId()
	if session == 0 || session == 0xffffffff {
		return nil, fmt.Errorf("no console")
	}
	var token windows.Token
	if err := windows.WTSQueryUserToken(session, &token); err != nil {
		return nil, err
	}
	defer token.Close()
	exe, err := os.Executable()
	if err != nil {
		return nil, err
	}
	args := []string{"--clipboard-agent"}
	if policy.ToGuest {
		args = append(args, "--clipboard-write")
	}
	if policy.ToHost {
		args = append(args, "--clipboard-read")
	}
	cmd := exec.Command(exe, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Token: syscall.Token(token), HideWindow: true}
	in, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		in.Close()
		return nil, err
	}
	cmd.Stderr = nil
	if err = cmd.Start(); err != nil {
		in.Close()
		out.Close()
		return nil, err
	}
	worker := &nativeClipboardWorker{cmd: cmd, input: json.NewEncoder(in)}
	go func() {
		defer emit(clipboardMessage{Kind: "closed"})
		defer in.Close()
		defer out.Close()
		defer cmd.Wait()
		defer worker.Close()
		scanner := bufio.NewScanner(out)
		scanner.Buffer(make([]byte, 4096), clipboardLimit*6+1024)
		for scanner.Scan() {
			var value clipboardMessage
			if json.Unmarshal(scanner.Bytes(), &value) == nil {
				emit(value)
			}
		}
	}()
	return worker, nil
}

var clipUser32 = windows.NewLazySystemDLL("user32.dll")
var clipKernel = windows.NewLazySystemDLL("kernel32.dll")
var clipOpen = clipUser32.NewProc("OpenClipboard")
var clipClose = clipUser32.NewProc("CloseClipboard")
var clipGlobalLock = clipKernel.NewProc("GlobalLock")
var clipGlobalUnlock = clipKernel.NewProc("GlobalUnlock")

func clipboardDesktopUnlocked() bool {
	desktop, _, _ := clipUser32.NewProc("OpenInputDesktop").Call(0, 0, 0x0001)
	if desktop == 0 {
		return false
	}
	defer clipUser32.NewProc("CloseDesktop").Call(desktop)
	var name [256]uint16
	var needed uint32
	ok, _, _ := clipUser32.NewProc("GetUserObjectInformationW").Call(desktop, 2, uintptr(unsafe.Pointer(&name[0])), uintptr(unsafe.Sizeof(name)), uintptr(unsafe.Pointer(&needed)))
	return ok != 0 && windows.UTF16ToString(name[:]) == "Default"
}
func readClipboardText(hwnd uintptr) (string, error) {
	if !clipboardDesktopUnlocked() {
		return "", fmt.Errorf("locked desktop")
	}
	ok, _, _ := clipOpen.Call(hwnd)
	if ok == 0 {
		return "", fmt.Errorf("clipboard busy")
	}
	defer clipClose.Call()
	handle, _, _ := clipUser32.NewProc("GetClipboardData").Call(13)
	if handle == 0 {
		return "", fmt.Errorf("no text")
	}
	bytes, _, _ := clipKernel.NewProc("GlobalSize").Call(handle)
	if bytes < 2 || bytes > clipboardLimit*2 {
		return "", fmt.Errorf("text too large")
	}
	pointer, _, _ := clipGlobalLock.Call(handle)
	if pointer == 0 {
		return "", fmt.Errorf("clipboard unavailable")
	}
	defer clipGlobalUnlock.Call(handle)
	units := unsafe.Slice((*uint16)(unsafe.Pointer(pointer)), int(bytes/2))
	end := -1
	for i, value := range units {
		if value == 0 {
			end = i
			break
		}
	}
	if end < 0 {
		return "", fmt.Errorf("unterminated text")
	}
	text := windows.UTF16ToString(units[:end])
	if !validClipboard(text) {
		return "", fmt.Errorf("invalid text")
	}
	return text, nil
}
func writeClipboardText(hwnd uintptr, text string) error {
	if !validClipboard(text) || !clipboardDesktopUnlocked() {
		return fmt.Errorf("text or desktop unavailable")
	}
	units, err := windows.UTF16FromString(text)
	if err != nil {
		return err
	}
	handle, _, _ := clipKernel.NewProc("GlobalAlloc").Call(2, uintptr(len(units)*2))
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
		return fmt.Errorf("allocation unavailable")
	}
	copy(unsafe.Slice((*uint16)(unsafe.Pointer(pointer)), len(units)), units)
	clipGlobalUnlock.Call(handle)
	ok, _, _ := clipOpen.Call(hwnd)
	if ok == 0 {
		return fmt.Errorf("clipboard busy")
	}
	defer clipClose.Call()
	ok, _, _ = clipUser32.NewProc("EmptyClipboard").Call()
	if ok == 0 {
		return fmt.Errorf("clipboard unavailable")
	}
	ok, _, _ = clipUser32.NewProc("SetClipboardData").Call(13, handle)
	if ok == 0 {
		return fmt.Errorf("clipboard write failed")
	}
	owned = false
	return nil
}
func runClipboardAgent() {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	output := json.NewEncoder(os.Stdout)
	send := func(m clipboardMessage) { output.Encode(m) }
	cleanup, err := attachConsoleDesktop()
	if err != nil {
		send(clipboardMessage{Kind: "denied"})
		return
	}
	defer cleanup()
	toGuest, toHost := false, false
	for _, arg := range os.Args[2:] {
		if arg == "--clipboard-write" {
			toGuest = true
		}
		if arg == "--clipboard-read" {
			toHost = true
		}
	}
	if !clipboardDesktopUnlocked() {
		send(clipboardMessage{Kind: "denied"})
		return
	}
	directions := ""
	if toGuest {
		directions += "Linux to Windows (write clipboard).\n"
	}
	if toHost {
		directions += "Windows to Linux (read clipboard).\n"
	}
	message, _ := windows.UTF16PtrFromString("Allow this WinBoat desktop session to share plain text?\n\n" + directions + "\nStops on lock, sign-out or host disconnect. Clipboard text may contain private information.")
	title, _ := windows.UTF16PtrFromString("WinBoat text clipboard")
	answer, _, _ := clipUser32.NewProc("MessageBoxW").Call(0, uintptr(unsafe.Pointer(message)), uintptr(unsafe.Pointer(title)), 0x00010000|0x00000100|0x00000004|0x00000020)
	if answer != 6 {
		send(clipboardMessage{Kind: "denied"})
		return
	}
	var pendingMu sync.Mutex
	pending := []clipboardMessage{}
	var hwnd uintptr
	var lastSequence uintptr
	lastOrigin := ""
	active := true
	callback := syscall.NewCallback(func(window uintptr, msg uint32, wparam, lparam uintptr) uintptr {
		if msg == 0x031d || msg == 0x8001 {
			if !clipboardDesktopUnlocked() {
				active = false
				send(clipboardMessage{Kind: "locked"})
				return 0
			}
			if !active {
				return 0
			}
			if msg == 0x8001 {
				pendingMu.Lock()
				commands := pending
				pending = nil
				pendingMu.Unlock()
				for _, command := range commands {
					if command.Kind == "write" && toGuest {
						if writeClipboardText(window, command.Text) == nil {
							lastSequence, _, _ = clipUser32.NewProc("GetClipboardSequenceNumber").Call()
							lastOrigin = command.Origin
						}
					} else if command.Kind == "read" && toHost {
						if text, err := readClipboardText(window); err == nil {
							send(clipboardMessage{Kind: "text", Text: text})
						}
					}
				}
			} else if toHost {
				if text, err := readClipboardText(window); err == nil {
					sequence, _, _ := clipUser32.NewProc("GetClipboardSequenceNumber").Call()
					origin := ""
					if sequence == lastSequence {
						origin = lastOrigin
					}
					send(clipboardMessage{Kind: "text", Text: text, Origin: origin})
				}
			}
			return 0
		}
		if msg == 0x02b1 && (wparam == 7 || wparam == 6 || wparam == 2) {
			active = false
			send(clipboardMessage{Kind: "locked"})
			return 0
		}
		result, _, _ := clipUser32.NewProc("DefWindowProcW").Call(window, uintptr(msg), wparam, lparam)
		return result
	})
	type wndClass struct {
		Size, Style                        uint32
		Proc                               uintptr
		ClassExtra, WindowExtra            int32
		Instance, Icon, Cursor, Background uintptr
		Menu, Name                         *uint16
		SmallIcon                          uintptr
	}
	name, _ := windows.UTF16PtrFromString("WinBoatClipboardAgent")
	class := wndClass{Proc: callback, Name: name}
	class.Size = uint32(unsafe.Sizeof(class))
	if ok, _, _ := clipUser32.NewProc("RegisterClassExW").Call(uintptr(unsafe.Pointer(&class))); ok == 0 {
		send(clipboardMessage{Kind: "denied"})
		return
	}
	hwnd, _, _ = clipUser32.NewProc("CreateWindowExW").Call(0, uintptr(unsafe.Pointer(name)), uintptr(unsafe.Pointer(name)), 0, 0, 0, 0, 0, ^uintptr(2), 0, 0, 0)
	if hwnd == 0 {
		send(clipboardMessage{Kind: "denied"})
		return
	}
	defer clipUser32.NewProc("DestroyWindow").Call(hwnd)
	ok, _, _ := clipUser32.NewProc("AddClipboardFormatListener").Call(hwnd)
	if ok == 0 {
		send(clipboardMessage{Kind: "denied"})
		return
	}
	defer clipUser32.NewProc("RemoveClipboardFormatListener").Call(hwnd)
	windows.NewLazySystemDLL("wtsapi32.dll").NewProc("WTSRegisterSessionNotification").Call(hwnd, 0)
	defer windows.NewLazySystemDLL("wtsapi32.dll").NewProc("WTSUnRegisterSessionNotification").Call(hwnd)
	send(clipboardMessage{Kind: "ready"})
	go func() {
		scanner := bufio.NewScanner(os.Stdin)
		scanner.Buffer(make([]byte, 4096), clipboardLimit*6+1024)
		for scanner.Scan() {
			var command clipboardMessage
			if json.Unmarshal(scanner.Bytes(), &command) != nil || !validClipboard(command.Text) {
				continue
			}
			pendingMu.Lock()
			if len(pending) < 8 {
				pending = append(pending, command)
			}
			pendingMu.Unlock()
			clipUser32.NewProc("PostMessageW").Call(hwnd, 0x8001, 0, 0)
		}
		clipUser32.NewProc("PostMessageW").Call(hwnd, 0x0012, 0, 0)
	}()
	type clipWindowMessage struct {
		Window         uintptr
		ID             uint32
		Wparam, Lparam uintptr
		Time           uint32
		Point          struct{ X, Y int32 }
		Private        uint32
	}
	for {
		var m clipWindowMessage
		ok, _, _ := clipUser32.NewProc("GetMessageW").Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0)
		if int32(ok) <= 0 {
			break
		}
		clipUser32.NewProc("TranslateMessage").Call(uintptr(unsafe.Pointer(&m)))
		clipUser32.NewProc("DispatchMessageW").Call(uintptr(unsafe.Pointer(&m)))
	}
}
