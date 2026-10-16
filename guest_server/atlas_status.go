package main

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
)

// Local provisioning owns all changes. The guest API only exposes status.
func getAtlasStatus(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	root := os.Getenv("ProgramData")
	if root == "" {
		root = `C:\ProgramData`
	}
	state, err := readHeliosJSON(filepath.Join(root, "WinBoat", "Atlas", "status.json"))
	if os.IsNotExist(err) {
		state = map[string]interface{}{"status": "waiting", "release": "0.5.0-hotfix", "message": "Waiting for Atlas provisioning in the Windows console"}
	} else if err != nil {
		state = map[string]interface{}{"status": "failed", "release": "0.5.0-hotfix", "message": "Cannot read Atlas provisioning status"}
	}
	json.NewEncoder(w).Encode(state)
}
