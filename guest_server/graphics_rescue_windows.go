//go:build windows

package main

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"

	"golang.org/x/sys/windows/registry"
)

func graphicsRescueActive() bool {
	key, err := registry.OpenKey(registry.LOCAL_MACHINE, `SOFTWARE\WinBoat\DisplayRecovery`, registry.QUERY_VALUE)
	if err == registry.ErrNotExist {
		return false
	}
	if err != nil {
		return true
	} // Unknown state must not authorize automatic setup.
	defer key.Close()
	value, _, err := key.GetIntegerValue("HeliosDisabled")
	return err != registry.ErrNotExist && (err != nil || value != 0)
}

func runGraphicsRescue(ctx context.Context, action string) ([]byte, error) {
	executable, err := os.Executable()
	if err != nil {
		return nil, err
	}
	script := filepath.Join(filepath.Dir(executable), "scripts", "Set-HeliosRescue.ps1")
	return exec.CommandContext(ctx, "powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, "-Action", action).Output()
}
