//go:build windows

package main

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"golang.org/x/sys/windows"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

var displayTopology topologyController // collectDisplayAdapters is serialized by the monitor
var restartVerification graphicsRetry
var containment graphicsBreaker

func collectDisplayAdapters(ctx context.Context, viewerUnavailable bool) ([]byte, error) {
	executable, err := os.Executable()
	if err != nil {
		return nil, err
	}
	// Service startup can race the installer continuation. Retry verification
	// while its receipt remains pending, without relaunching setup or restarting
	// Windows. Only the serialized monitor owns this cooldown.
	now := time.Now()
	statusPath := filepath.Join(os.Getenv("ProgramData"), "Helios", "provisioning-status.json")
	if info, statErr := os.Stat(statusPath); statErr == nil &&
		heliosRestartPending(filepath.Dir(executable), os.Getenv("ProgramData")) &&
		restartVerification.ready(now, fmt.Sprintf("%d:%d", info.ModTime().UnixNano(), info.Size())) {
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
	if containment.observe(time.Now(), !rescue && graphicsContainmentEnabled(), pnp, desktop, probeErr) {
		// The fixed rescue script rechecks VGA health and takes the existing
		// provisioning mutex. No VGA enable, topology change or reboot allowed.
		if graphicsRescueMutex.TryLock() {
			script := filepath.Join(filepath.Dir(executable), "scripts", "Set-HeliosRescue.ps1")
			_, isolationErr := exec.CommandContext(ctx, "powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, "-Action", "helios-disable", "-PreserveVga").Output()
			graphicsRescueMutex.Unlock()
			pnp.Recovery = "helios-isolation-requested"
			if isolationErr != nil {
				pnp.Recovery = "helios-isolation-unavailable"
			}
		}
	}
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
func collectGraphicsLoad(ctx context.Context) ([]byte, error) {
	return collectGraphicsScript(ctx, "Get-GraphicsLoad.ps1")
}
func collectGraphicsRuntime(ctx context.Context) ([]byte, error) {
	data, err := collectGraphicsScript(ctx, "Get-GraphicsRuntimeDiagnostics.ps1")
	if err != nil {
		return nil, err
	}
	var report map[string]interface{}
	if err = json.Unmarshal(data, &report); err != nil {
		return nil, err
	}
	report["consoleLogonState"] = "unknown"
	session := windows.WTSGetActiveConsoleSessionId()
	var token windows.Token
	// Never use the SYSTEM pre-logon fallback as evidence of a user login.
	if session != 0 && session != 0xffffffff && windows.WTSQueryUserToken(session, &token) == nil {
		defer token.Close()
		var stats [56]byte
		var length uint32
		if windows.GetTokenInformation(token, windows.TokenStatistics, &stats[0], uint32(len(stats)), &length) == nil && length == 56 && session == windows.WTSGetActiveConsoleSessionId() {
			id := binary.LittleEndian.Uint64(stats[8:16])
			if id != 0 {
				report["consoleLogonId"] = fmt.Sprintf("%016x", id)
				report["consoleLogonState"] = "observed"
			}
		}
	}
	return json.Marshal(report)
}
func collectGraphicsScript(ctx context.Context, name string) ([]byte, error) {
	executable, err := os.Executable()
	if err != nil {
		return nil, err
	}
	script := filepath.Join(filepath.Dir(executable), "scripts", name)
	return exec.CommandContext(ctx, "powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script).Output()
}
