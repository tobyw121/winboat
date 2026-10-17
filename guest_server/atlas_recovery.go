package main

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// One fixed operation, guarded again inside Windows. No command/path arguments.
func atlasRecoveryHandler(operation string, recoverOOBE func(context.Context) ([]byte, error)) http.HandlerFunc {
	var active sync.Mutex
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		fail := func(code int, message string) {
			w.WriteHeader(code)
			json.NewEncoder(w).Encode(map[string]string{"error": message})
		}
		if r.Header.Get("X-WinBoat-Recovery") != operation {
			fail(http.StatusBadRequest, "Explicit OOBE recovery header required")
			return
		}
		if !active.TryLock() {
			fail(http.StatusConflict, "Recovery request already active")
			return
		}
		defer active.Unlock()
		ctx, cancel := context.WithTimeout(r.Context(), 90*time.Second)
		defer cancel()
		data, err := recoverOOBE(ctx)
		var result struct {
			Status string `json:"status"`
		}
		if err != nil || len(data) > 65536 || json.Unmarshal(data, &result) != nil {
			fail(http.StatusServiceUnavailable, "Cannot run the fixed AME recovery operation")
			return
		}
		switch result.Status {
		case "queued", "launched":
			w.WriteHeader(http.StatusAccepted)
		case "blocked":
			w.WriteHeader(http.StatusConflict)
		case "failed":
			w.WriteHeader(http.StatusInternalServerError)
		default:
			fail(http.StatusServiceUnavailable, "Unexpected AME recovery result")
			return
		}
		w.Write(data)
	}
}

func getAtlasRecoveryStatus(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	root := os.Getenv("ProgramData")
	if root == "" {
		root = `C:\ProgramData`
	}
	state, err := readHeliosJSON(filepath.Join(root, "WinBoat", "Atlas", "recovery.json"))
	if os.IsNotExist(err) {
		state = map[string]interface{}{"status": "not-requested"}
	} else if err != nil {
		w.WriteHeader(http.StatusServiceUnavailable)
		state = map[string]interface{}{"status": "failed", "message": "Cannot read OOBE recovery status"}
	}
	json.NewEncoder(w).Encode(state)
}
