//go:build windows

package main

import (
	"context"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

func collectDisplayAdapters(ctx context.Context) ([]byte, error) {
	executable, err := os.Executable()
	if err != nil {
		return nil, err
	}
	script := filepath.Join(filepath.Dir(executable), "scripts", "Get-DisplayAdapters.ps1")
	return exec.CommandContext(ctx, "powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, "-Recover").Output()
}
func ensureSelectedHelios() {
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	executable, err := os.Executable()
	if err != nil {
		log.Printf("Helios startup: %v", err)
		return
	}
	script := filepath.Join(filepath.Dir(executable), "scripts", "Start-HeliosProvisioning.ps1")
	if _, err = exec.CommandContext(ctx, "powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, "-Ensure").Output(); err != nil {
		log.Printf("Cannot ensure selected Helios startup task: %v", err)
	}
}
