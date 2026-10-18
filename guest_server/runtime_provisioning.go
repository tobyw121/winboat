package main

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

const runtimeProtocol = "vcredist-v1"

// Registration is asynchronous; downloads/installers belong to the durable
// SYSTEM task, so neither API startup nor a disconnected host owns installation.
func ensureVCRedist() {
	executable, err := os.Executable()
	if err != nil {
		log.Printf("Visual C++ task: %v", err)
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	script := filepath.Join(filepath.Dir(executable), "scripts", "Start-VCRedistProvisioning.ps1")
	output, err := exec.CommandContext(ctx, "powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, "-Register").CombinedOutput()
	if err != nil {
		log.Printf("Visual C++ task registration: %v: %s", err, output)
	}
}

func getVCRedistStatus(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	root := os.Getenv("ProgramData")
	if root == "" {
		root = `C:\ProgramData`
	}
	state, err := readHeliosJSON(filepath.Join(root, "WinBoat", "VCRedist", "status.json"))
	if os.IsNotExist(err) {
		state = map[string]interface{}{"revision": runtimeProtocol, "status": "waiting", "message": "Waiting for Visual C++ runtime provisioning"}
	} else if err != nil {
		state = map[string]interface{}{"revision": runtimeProtocol, "status": "failed", "message": "Cannot read Visual C++ runtime provisioning status"}
	}
	json.NewEncoder(w).Encode(state)
}
