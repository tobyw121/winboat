//go:build windows

package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
)

func runGraphicsMaintenance(ctx context.Context, action string) ([]byte, error) {
	choices := map[string][2]string{"check-update": {"Manage-HeliosTransaction.ps1", "Check"}, "prepare-rollback": {"Manage-HeliosTransaction.ps1", "Rollback"}, "capture-enable": {"Manage-HeliosCrashCapture.ps1", "Enable"}, "capture-disable": {"Manage-HeliosCrashCapture.ps1", "Disable"}}
	choice, ok := choices[action]
	if !ok {
		return nil, fmt.Errorf("unknown operation")
	}
	executable, err := os.Executable()
	if err != nil {
		return nil, err
	}
	script := filepath.Join(filepath.Dir(executable), "scripts", choice[0])
	args := []string{"-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, "-Action", choice[1]}
	if choice[0] == "Manage-HeliosTransaction.ps1" {
		args = append(args, "-Quiet")
	}
	return exec.CommandContext(ctx, "powershell.exe", args...).Output()
}
