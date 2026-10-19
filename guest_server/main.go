//go:build windows
// +build windows

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"

	"golang.org/x/sys/windows/registry"

	"github.com/gorilla/mux"
	"github.com/rs/cors"
	"github.com/shirou/gopsutil/cpu"
	"github.com/shirou/gopsutil/disk"
	"github.com/shirou/gopsutil/mem"
)

var (
	Version        = "0.0.0"
	CommitHash     = "n/a"
	BuildTimestamp = "n/a"
)

type Metrics struct {
	CPU struct {
		Usage     float64 `json:"usage"`     // Percentage, 0-100
		Frequency uint64  `json:"frequency"` // MHz
	} `json:"cpu"`
	RAM struct {
		Used       uint64  `json:"used"`       // MB
		Total      uint64  `json:"total"`      // MB
		Percentage float64 `json:"percentage"` // %
	} `json:"ram"`
	Disk struct {
		Used       uint64  `json:"used"`       // MB
		Total      uint64  `json:"total"`      // MB
		Percentage float64 `json:"percentage"` // %
	} `json:"disk"`
}

func getApps(w http.ResponseWriter, r *http.Request) {
	cmd := exec.Command("powershell", "-ExecutionPolicy", "Bypass", "-Command", "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; & '.\\scripts\\apps.ps1'")
	output, err := cmd.Output()
	if err != nil {
		http.Error(w, "Failed to execute script: "+err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	w.Write(output)
}

func getHealth(w http.ResponseWriter, r *http.Request) {
	// Simple health check
	response := map[string]string{"status": "ok"}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(response)
}

func collectAtlasDiagnostics(ctx context.Context) ([]byte, error) {
	executable, err := os.Executable()
	if err != nil {
		return nil, err
	}
	script := filepath.Join(filepath.Dir(executable), "scripts", "Get-AtlasDiagnostics.ps1")
	return exec.CommandContext(ctx, "powershell.exe", "-NoProfile", "-NonInteractive",
		"-ExecutionPolicy", "Bypass", "-File", script).Output()
}

func recoverAtlasOOBE(ctx context.Context) ([]byte, error) {
	executable, err := os.Executable()
	if err != nil {
		return nil, err
	}
	script := filepath.Join(filepath.Dir(executable), "scripts", "Repair-AtlasOOBE.ps1")
	return exec.CommandContext(ctx, "powershell.exe", "-NoProfile", "-NonInteractive",
		"-ExecutionPolicy", "Bypass", "-File", script).Output()
}

func launchAtlasUI(ctx context.Context) ([]byte, error) {
	return runAtlasUI(ctx, false)
}
func repairAtlasIPC(ctx context.Context) ([]byte, error) {
	executable, err := os.Executable()
	if err != nil {
		return nil, err
	}
	script := filepath.Join(filepath.Dir(executable), "scripts", "Repair-AtlasIPC.ps1")
	return exec.CommandContext(ctx, "powershell.exe", "-NoProfile", "-NonInteractive",
		"-ExecutionPolicy", "Bypass", "-File", script).Output()
}
func resumeAtlasHelios(ctx context.Context) ([]byte, error) {
	executable, err := os.Executable()
	if err != nil {
		return nil, err
	}
	script := filepath.Join(filepath.Dir(executable), "scripts", "Start-AtlasHelios.ps1")
	return exec.CommandContext(ctx, "powershell.exe", "-NoProfile", "-NonInteractive",
		"-ExecutionPolicy", "Bypass", "-File", script, "-Register").Output()
}
func restartAtlasUI(ctx context.Context) ([]byte, error) {
	return runAtlasUI(ctx, true)
}
func runAtlasUI(ctx context.Context, restart bool) ([]byte, error) {
	executable, err := os.Executable()
	if err != nil {
		return nil, err
	}
	script := filepath.Join(filepath.Dir(executable), "scripts", "Start-AtlasOOBEClient.ps1")
	args := []string{"-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script}
	if restart {
		args = append(args, "-RestartStalled")
	}
	return exec.CommandContext(ctx, "powershell.exe", args...).Output()
}

func getVersion(w http.ResponseWriter, r *http.Request) {
	response := map[string]string{
		"version":           Version,
		"graphics_protocol": graphicsProtocol,
		"runtime_protocol":  runtimeProtocol,
		"commit_hash":       CommitHash,
		"build_time":        BuildTimestamp,
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(response)
}

var cpuFrequencyOnce sync.Once
var cpuFrequencyMHz uint64

func getMetrics(w http.ResponseWriter, r *http.Request) {
	// CPU stats
	cpuPercent, err := cpu.Percent(time.Second/4, false)
	if err != nil {
		http.Error(w, "Failed to get CPU stats: "+err.Error(), http.StatusInternalServerError)
		return
	}
	// CPU model/frequency is static for this VM; avoid repeated WMI discovery.
	cpuFrequencyOnce.Do(func() {
		key, err := registry.OpenKey(registry.LOCAL_MACHINE, `HARDWARE\DESCRIPTION\System\CentralProcessor\0`, registry.QUERY_VALUE)
		if err == nil {
			defer key.Close()
			cpuFrequencyMHz, _, _ = key.GetIntegerValue("~MHz")
		}
	})

	// RAM stats
	memInfo, err := mem.VirtualMemory()
	if err != nil {
		http.Error(w, "Failed to get RAM stats: "+err.Error(), http.StatusInternalServerError)
		return
	}

	// Disk stats (using first disk, adjust path if needed)
	diskInfo, err := disk.Usage("C:\\")
	if err != nil {
		http.Error(w, "Failed to get disk stats: "+err.Error(), http.StatusInternalServerError)
		return
	}

	// Build metrics struct
	metrics := Metrics{}
	metrics.CPU.Usage = cpuPercent[0]             // Total CPU usage
	metrics.CPU.Frequency = cpuFrequencyMHz       // First CPU's frequency
	metrics.RAM.Used = memInfo.Used / 1024 / 1024 // Bytes to MB
	metrics.RAM.Total = memInfo.Total / 1024 / 1024
	metrics.RAM.Percentage = float64(metrics.RAM.Used) / float64(metrics.RAM.Total) * 100
	metrics.Disk.Used = diskInfo.Used / 1024 / 1024
	metrics.Disk.Total = diskInfo.Total / 1024 / 1024
	metrics.Disk.Percentage = diskInfo.UsedPercent

	// Send it
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(metrics)
}

func getRdpConnectedStatus(w http.ResponseWriter, r *http.Request) {
	connected, err := activeRDPConnected()
	if err != nil {
		http.Error(w, "Failed to query Windows sessions", http.StatusServiceUnavailable)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]bool{"rdpConnected": connected})
}

func applyUpdate(w http.ResponseWriter, r *http.Request) {
	r.ParseMultipartForm(100 << 20) // Limit upload size to 100MB
	var buf bytes.Buffer

	// Grab the file
	file, _, err := r.FormFile("updateFile")
	if err != nil {
		http.Error(w, "Failed to get update file: "+err.Error(), http.StatusBadRequest)
		return
	}

	// Copy to buffer & close the file
	io.Copy(&buf, file)
	file.Close()

	// Check zip magic bytes
	if !(buf.Bytes()[0] == 'P' && buf.Bytes()[1] == 'K' && buf.Bytes()[2] == 3 && buf.Bytes()[3] == 4) {
		http.Error(w, "Uploaded file is not a valid ZIP archive", http.StatusBadRequest)
		return
	}

	// Make temp directory
	tmpDir, err := os.MkdirTemp("", "winboat-update")
	if err != nil {
		http.Error(w, "Failed to create temp directory: "+err.Error(), http.StatusInternalServerError)
	}

	// Write to temp file
	fileName := "update.zip"
	tmpFilePath := filepath.Join(tmpDir, fileName)
	err = os.WriteFile(tmpFilePath, buf.Bytes(), 0644)

	if err != nil {
		http.Error(w, "Failed to write temp file: "+err.Error(), http.StatusInternalServerError)
		return
	}

	// Get current executable path & directory
	exePath, err := os.Executable()
	if err != nil {
		http.Error(w, "Failed to get executable path: "+err.Error(), http.StatusInternalServerError)
		return
	}
	appDir := filepath.Dir(exePath)
	origScriptPath := filepath.Join(appDir, "scripts\\update.ps1")
	scriptPath := filepath.Join(tmpDir, "update.ps1")

	// Copy the update script to the temp directory
	copyFile(origScriptPath, scriptPath)

	// Return success & the paths
	response := map[string]string{
		"status":    "updating",
		"temp_path": tmpFilePath,
		"filename":  fileName,
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(response)

	// Create & run the script
	cmd := exec.Command("cmd", "/C", "start", "/B", "powershell",
		"-ExecutionPolicy", "Bypass", "-File", scriptPath,
		"-AppPath", appDir,
		"-UpdateFilePath", tmpFilePath,
		"-ServiceName", "WinBoatGuestServer")

	cmd.Stdout = nil
	cmd.Stderr = nil
	cmd.Stdin = nil

	// The script will take care of the rest, including stopping this service
	cmd.Start()

}

func getIcon(w http.ResponseWriter, r *http.Request) {
	path := r.PostFormValue("path")
	if path == "" {
		http.Error(w, "path is required", http.StatusBadRequest)
		return
	}

	cmd := exec.Command("powershell", "-ExecutionPolicy", "Bypass", "-File", "scripts\\get-icon.ps1", "-path", path)
	output, err := cmd.Output()
	if err != nil {
		http.Error(w, "Failed to execute script: "+err.Error(), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "text/plain")
	w.WriteHeader(http.StatusOK)
	w.Write(output)
}

func main() {
	if len(os.Args) == 2 {
		actions := map[string]string{"--display-session-probe": "probe", "--display-session-extend": "extend", "--display-session-clone": "clone", "--display-session-basic": "basic"}
		if action, ok := actions[os.Args[1]]; ok {
			runDisplaySessionProbe(action)
			return
		}
	}
	r := mux.NewRouter()
	graphics := newGraphicsMonitor()
	go graphics.run(context.Background(), collectDisplayAdapters)
	go ensureSelectedHelios()
	go ensureVCRedist()
	r.HandleFunc("/graphics/adapters", graphics.status).Methods("GET")
	r.HandleFunc("/graphics/history", graphics.historyStatus).Methods("GET")
	r.HandleFunc("/graphics/diagnostics/journals", graphics.diagnostics(collectHeliosJournals)).Methods("GET")
	r.HandleFunc("/graphics/diagnostics/runtime", graphics.diagnostics(collectGraphicsRuntime)).Methods("GET")
	r.HandleFunc("/graphics/diagnostics", graphics.diagnostics(collectHeliosDiagnostics)).Methods("GET")
	r.HandleFunc("/graphics/adapters/recovery", graphics.viewerRecovery).Methods("POST")
	r.HandleFunc("/graphics/rescue", graphicsRescueHandler(runGraphicsRescue)).Methods("POST")
	r.HandleFunc("/apps", getApps).Methods("GET")
	r.HandleFunc("/health", getHealth).Methods("GET")
	r.HandleFunc("/graphics/helios", getHeliosStatus).Methods("GET")
	r.HandleFunc("/provisioning/atlas", getAtlasStatus).Methods("GET")
	r.HandleFunc("/provisioning/vcredist", getVCRedistStatus).Methods("GET")
	r.HandleFunc("/provisioning/atlas/diagnostics", atlasDiagnosticsHandler(collectAtlasDiagnostics)).Methods("GET")
	r.HandleFunc("/provisioning/atlas/recovery", getAtlasRecoveryStatus).Methods("GET")
	r.HandleFunc("/provisioning/atlas/recovery", atlasRecoveryHandler("restart-oobe", recoverAtlasOOBE)).Methods("POST")
	r.HandleFunc("/provisioning/atlas/restart-ui", atlasRecoveryHandler("restart-ame-ui", restartAtlasUI)).Methods("POST")
	r.HandleFunc("/provisioning/atlas/repair-ipc", atlasRecoveryHandler("repair-ame-ipc", repairAtlasIPC)).Methods("POST")
	r.HandleFunc("/provisioning/atlas/resume-helios", atlasRecoveryHandler("resume-helios", resumeAtlasHelios)).Methods("POST")
	r.HandleFunc("/provisioning/atlas/launch-ui", atlasRecoveryHandler("launch-ame-ui", launchAtlasUI)).Methods("POST")
	r.HandleFunc("/version", getVersion).Methods("GET")
	r.HandleFunc("/metrics", getMetrics).Methods("GET")
	r.HandleFunc("/rdp/status", getRdpConnectedStatus).Methods("GET")
	r.HandleFunc("/update", applyUpdate).Methods("POST")
	r.HandleFunc("/get-icon", getIcon).Methods("POST")
	handler := cors.Default().Handler(r)

	log.Println("Starting WinBoat Guest Server on :7148...")
	if err := http.ListenAndServe(":7148", handler); err != nil {
		log.Fatal("Server failed: ", err)
	}
}
