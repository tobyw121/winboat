//go:build windows

package main

import (
	"context"
	"golang.org/x/sys/windows"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
)

func requestWindowsPower(ctx context.Context, reboot bool) error {
	action := "/s"
	if reboot {
		action = "/r"
	}
	return exec.CommandContext(ctx, filepath.Join(os.Getenv("SystemRoot"), "System32", "shutdown.exe"), action, "/t", "0").Run()
}
func openGuestExchange(ctx context.Context) error {
	session := windows.WTSGetActiveConsoleSessionId()
	var token windows.Token
	if err := windows.WTSQueryUserToken(session, &token); err != nil {
		return err
	}
	defer token.Close()
	cmd := exec.CommandContext(ctx, filepath.Join(os.Getenv("SystemRoot"), "explorer.exe"), `\\host.lan\WinBoatExchange`)
	cmd.SysProcAttr = &syscall.SysProcAttr{Token: syscall.Token(token), HideWindow: true}
	return cmd.Run()
}
