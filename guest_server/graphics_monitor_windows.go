//go:build windows

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

var displayTopology topologyController // collectDisplayAdapters is serialized by the monitor

func collectDisplayAdapters(ctx context.Context, viewerUnavailable bool) ([]byte, error) {
	executable, err := os.Executable()
	if err != nil {
		return nil, err
	}
	script := filepath.Join(filepath.Dir(executable), "scripts", "Get-DisplayAdapters.ps1")
	enabled := mirrorEnabled(filepath.Dir(executable), os.Getenv("ProgramData"))
	desktopCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
	desktop, probeErr := collectConsoleDesktop(desktopCtx)
	cancel()
	args := []string{"-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, "-Recover"}
	if viewerUnavailable || desktopRequiresFallback(desktop, probeErr) {
		args = append(args, "-ViewerUnavailable")
	}
	if enabled {
		args = append(args, "-MirrorDesired")
	}
	data, err := exec.CommandContext(ctx, "powershell.exe", args...).Output()
	if err != nil {
		return nil, err
	}
	var pnp displayAdapters
	if err = json.Unmarshal(data, &pnp); err != nil {
		return nil, err
	}
	desktop, policy := displayTopology.reconcile(time.Now(), enabled, pnp, desktop, probeErr, viewerUnavailable, func(action string) (desktopSnapshot, error) {
		applyCtx, cancel := context.WithTimeout(ctx, 7*time.Second)
		defer cancel()
		next, err := collectConsoleDesktopAction(applyCtx, action)
		if err == nil && next.ChangeError != "" {
			err = fmt.Errorf("%s", next.ChangeError)
		}
		return next, err
	})
	pnp.Policy = &policy
	data, err = json.Marshal(pnp)
	if err != nil {
		return nil, err
	}
	return mergeDesktopStatus(data, desktop, probeErr)
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

func collectHeliosDiagnostics(ctx context.Context) ([]byte, error) {
	executable, err := os.Executable()
	if err != nil {
		return nil, err
	}
	script := filepath.Join(filepath.Dir(executable), "scripts", "Get-HeliosDiagnostics.ps1")
	return exec.CommandContext(ctx, "powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script).Output()
}
