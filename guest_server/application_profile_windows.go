//go:build windows

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"golang.org/x/sys/windows"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"syscall"
	"time"
)

func launchApplicationProfile(ctx context.Context, p applicationProfile) error {
	var token windows.Token
	if err := windows.WTSQueryUserToken(windows.WTSGetActiveConsoleSessionId(), &token); err != nil {
		return err
	}
	defer token.Close()
	executable, err := os.Executable()
	if err != nil {
		return err
	}
	cmd := exec.CommandContext(ctx, executable, "--application-profile-agent")
	cmd.SysProcAttr = &syscall.SysProcAttr{Token: syscall.Token(token), HideWindow: true}
	data, _ := json.Marshal(p)
	cmd.Stdin = bytes.NewReader(data)
	return cmd.Run()
}
func runApplicationProfileAgent() {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	cleanup, err := attachConsoleDesktop()
	if err != nil {
		os.Exit(1)
	}
	defer cleanup()
	var p applicationProfile
	if json.NewDecoder(os.Stdin).Decode(&p) != nil || !validApplicationProfile(p) || !clipboardDesktopUnlocked() {
		os.Exit(1)
	}
	exe, err := os.Executable()
	if err != nil {
		os.Exit(1)
	}
	script := filepath.Join(filepath.Dir(exe), "scripts", "Start-HeliosApplication.ps1")
	args := ""
	for _, a := range p.Args {
		if args != "" {
			args += " "
		}
		args += syscall.EscapeArg(a)
	}
	mode := "driver-default"
	if p.API == "compatibility" {
		mode = "d3d11-fl10"
	}
	data, _ := json.Marshal(map[string]string{"executable": p.Exe, "mode": mode, "arguments": args, "script": script})
	// All executable paths and arguments arrive as JSON data, never PowerShell source.
	const code = `[Console]::InputEncoding=New-Object Text.UTF8Encoding($false);$d=[Console]::In.ReadToEnd()|ConvertFrom-Json;Add-Type -AssemblyName System.Windows.Forms;if([Windows.Forms.MessageBox]::Show(('Start '+$d.executable+[Environment]::NewLine+$d.arguments),'WinBoat application profile','YesNo','Question','Button2') -ne 'Yes'){exit 1};. $d.script -LibraryOnly;$info=New-HeliosApplicationStartInfo $d.executable $d.mode $d.arguments;[void][Diagnostics.Process]::Start($info)`
	ctx, cancel := context.WithTimeout(context.Background(), 85*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, filepath.Join(os.Getenv("SystemRoot"), "System32", "WindowsPowerShell", "v1.0", "powershell.exe"), "-NoProfile", "-NonInteractive", "-Command", code)
	cmd.Stdin = bytes.NewReader(data)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	if cmd.Run() != nil {
		os.Exit(1)
	}
}
