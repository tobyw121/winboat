package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
)

// Read-only contract: installation/reboots are owned by the local OEM task.
func getHeliosStatus(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	root := os.Getenv("ProgramData")
	if root == "" {
		root = `C:\ProgramData`
	}
	_, installedErr := os.Stat(filepath.Join(root, "Helios", "install-state.json"))
	progress := map[string]interface{}{"installed": installedErr == nil, "status": "waiting", "revision": "", "message": "Waiting for Helios provisioning"}
	// Installed source identity takes precedence over an older OEM receipt.
	// This also detects a later manual upgrade to an incompatible stack.
	receipt, err := readHeliosJSON(filepath.Join(root, "Helios", "manifest.json"))
	if err == nil {
		if source, ok := receipt["source"].(map[string]interface{}); ok {
			receipt = map[string]interface{}{"revision": source["helios"]}
		} else {
			receipt = map[string]interface{}{"revision": "invalid-manifest"}
		}
	} else if os.IsNotExist(err) {
		receipt, err = readHeliosJSON(filepath.Join(root, "WinBoat", "Helios", "helios-build.json"))
	}
	if err != nil {
		progress["status"] = "failed"
		progress["message"] = "Helios build receipt or installed manifest is missing or invalid"
		w.WriteHeader(http.StatusServiceUnavailable)
	} else {
		progress["revision"] = receipt["revision"]
		status, err := readHeliosJSON(filepath.Join(root, "Helios", "provisioning-status.json"))
		if err == nil {
			progress["status"] = status["status"]
			if status["status"] == "driver-restart-required" {
				progress["message"] = "Windows must restart to finish Helios driver provisioning"
			}
			if message, ok := status["message"]; ok {
				progress["message"] = message
			}
			if updated, ok := status["updatedAtUtc"]; ok {
				progress["updatedAtUtc"] = updated
			}
		} else if !os.IsNotExist(err) {
			progress["status"] = "failed"
			progress["message"] = "Cannot read Helios provisioning state"
		}
	}
	json.NewEncoder(w).Encode(progress)
}

func readHeliosJSON(path string) (map[string]interface{}, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	var value map[string]interface{}
	data, err := io.ReadAll(io.LimitReader(file, 65537))
	if err != nil {
		return nil, err
	}
	if len(data) > 65536 {
		return nil, io.ErrUnexpectedEOF
	}
	data = bytes.TrimPrefix(data, []byte{0xef, 0xbb, 0xbf})
	err = json.Unmarshal(data, &value)
	return value, err
}
