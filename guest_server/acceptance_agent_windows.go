//go:build windows

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"golang.org/x/sys/windows"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sync"
	"syscall"
	"time"
)

var acceptanceRun sync.Mutex

func startAcceptance(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Header.Get("Origin") != "" || r.Header.Get("X-WinBoat-Validation") != "acceptance" {
		http.Error(w, "Explicit local test request required", 403)
		return
	}
	if !acceptanceRun.TryLock() {
		http.Error(w, "Graphics tests already requested", 409)
		return
	}
	var token windows.Token
	if err := windows.WTSQueryUserToken(windows.WTSGetActiveConsoleSessionId(), &token); err != nil {
		acceptanceRun.Unlock()
		http.Error(w, "Sign in to Windows first", 409)
		return
	}
	defer token.Close()
	exe, err := os.Executable()
	if err != nil {
		acceptanceRun.Unlock()
		http.Error(w, "Service path unavailable", 503)
		return
	}
	cmd := exec.Command(exe, "--graphics-acceptance-agent")
	cmd.SysProcAttr = &syscall.SysProcAttr{Token: syscall.Token(token), HideWindow: true}
	if cmd.Start() != nil {
		acceptanceRun.Unlock()
		http.Error(w, "Interactive test helper unavailable", 503)
		return
	}
	go func() { defer acceptanceRun.Unlock(); cmd.Wait() }()
	w.WriteHeader(202)
	json.NewEncoder(w).Encode(map[string]string{"status": "requested", "scope": "Confirm Windows elevation; read the fresh acceptance report after completion"})
}
func runAcceptanceAgent() {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	cleanup, err := attachConsoleDesktop()
	if err != nil {
		os.Exit(1)
	}
	defer cleanup()
	if !clipboardDesktopUnlocked() {
		os.Exit(1)
	}
	exe, err := os.Executable()
	if err != nil {
		os.Exit(1)
	}
	script := filepath.Join(filepath.Dir(exe), "scripts", "Test-HeliosAcceptance.ps1")
	data, _ := json.Marshal(map[string]string{"script": script})
	// Fixed signed-in-session entry point; elevation is always an interactive UAC request.
	const code = `[Console]::InputEncoding=New-Object Text.UTF8Encoding($false);$d=[Console]::In.ReadToEnd()|ConvertFrom-Json;$validationArguments='-NoProfile -ExecutionPolicy Bypass -File "'+$d.script+'" -Label workbench';$p=Start-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs -ArgumentList $validationArguments -PassThru -Wait;exit $p.ExitCode`
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, filepath.Join(os.Getenv("SystemRoot"), "System32", "WindowsPowerShell", "v1.0", "powershell.exe"), "-NoProfile", "-Command", code)
	cmd.Stdin = bytes.NewReader(data)
	if cmd.Run() != nil {
		os.Exit(1)
	}
}
