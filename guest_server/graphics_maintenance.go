package main

import (
	"context"
	"encoding/json"
	"net/http"
	"time"
)

// Only fixed maintenance operations. No paths, commands, uploads or installation.
func graphicsMaintenanceHandler(run func(context.Context, string) ([]byte, error)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		action := r.Header.Get("X-WinBoat-Maintenance")
		switch action {
		case "check-update", "prepare-rollback", "capture-enable", "capture-disable":
		default:
			http.Error(w, `{"error":"Fixed maintenance operation required"}`, 400)
			return
		}
		if !graphicsRescueMutex.TryLock() {
			http.Error(w, `{"error":"Graphics maintenance active"}`, 409)
			return
		}
		defer graphicsRescueMutex.Unlock()
		ctx, cancel := context.WithTimeout(r.Context(), 55*time.Second)
		defer cancel()
		data, err := run(ctx, action)
		var result map[string]interface{}
		if err != nil || len(data) > 65536 || json.Unmarshal(data, &result) != nil || result == nil {
			http.Error(w, `{"error":"Maintenance unavailable; inspect local transaction and rescue status"}`, 503)
			return
		}
		json.NewEncoder(w).Encode(result)
	}
}
