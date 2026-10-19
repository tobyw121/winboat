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
var restartVerificationAt time.Time

func collectDisplayAdapters(ctx context.Context, viewerUnavailable bool) ([]byte, error) {
	executable, err := os.Executable()
	if err != nil {
		return nil, err
	}
	// Service startup can race the installer continuation. Retry verification
	// while its receipt remains pending, without relaunching setup or restarting
	// Windows. Only the serialized monitor owns this cooldown.
	now := time.Now()
	if !now.Before(restartVerificationAt) && heliosRestartPending(filepath.Dir(executable), os.Getenv("ProgramData")) {
		restartVerificationAt = now.Add(30 * time.Second)
		verifyCtx, verifyCancel := context.WithTimeout(ctx, 8*time.Second)
		verifyScript := filepath.Join(filepath.Dir(executable), "scripts", "Start-HeliosProvisioning.ps1")
		if _, verifyErr := exec.CommandContext(verifyCtx, "powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", verifyScript, "-VerifyRestart").Output(); verifyErr != nil {
			log.Printf("Helios restart verification: %v", verifyErr)
		}
		verifyCancel()
	}
	rescue := graphicsRescueActive()
	enabled := !rescue && extendedDesktopEnabled(filepath.Dir(executable), os.Getenv("ProgramData"))
	desktopCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
	desktop, probeErr := collectConsoleDesktop(desktopCtx)
	cancel()
	// Native observation only: viewer failures never enable/restart VGA.
	pnp, err := collectNativeDisplayAdapters(ctx)
	if err != nil {
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
	if rescue {
		pnp.Policy = &topologyStatus{Goal: "vga-rescue", State: "held", VGAProtection: "no-automatic-vga-or-primary-changes"}
	}
	data, err := json.Marshal(pnp)
	if err != nil {
		return nil, err
	}
	return mergeDesktopStatus(data, desktop, probeErr)
}
func ensureSelectedHelios() {
	if graphicsRescueActive() {
		return
	}
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

func collectHeliosJournals(ctx context.Context) ([]byte, error) {
	return collectGraphicsScript(ctx, "Get-HeliosJournalReport.ps1")
}
func collectGraphicsRuntime(ctx context.Context) ([]byte, error) {
	return collectGraphicsScript(ctx, "Get-GraphicsRuntimeDiagnostics.ps1")
}
func collectGraphicsScript(ctx context.Context, name string) ([]byte, error) {
	executable, err := os.Executable()
	if err != nil {
		return nil, err
	}
	script := filepath.Join(filepath.Dir(executable), "scripts", name)
	return exec.CommandContext(ctx, "powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script).Output()
}
