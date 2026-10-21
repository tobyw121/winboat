package main

import (
	"context"
	"encoding/json"
	"net/http"
	"sync"
	"time"
)

var vmPowerMutex sync.Mutex

func vmPowerHandler(run func(context.Context, bool) error) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		action := r.Header.Get("X-WinBoat-Power")
		if r.Method != "POST" || r.Header.Get("Origin") != "" || (action != "shutdown" && action != "reboot") {
			http.Error(w, `{"error":"Choose shutdown or reboot"}`, 400)
			return
		}
		if !vmPowerMutex.TryLock() {
			http.Error(w, `{"error":"Power request active"}`, 409)
			return
		}
		defer vmPowerMutex.Unlock()
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		defer cancel()
		if run(ctx, action == "reboot") != nil {
			http.Error(w, `{"error":"Windows did not accept the power request"}`, 503)
			return
		}
		json.NewEncoder(w).Encode(map[string]string{"state": "requested", "action": action, "scope": "No forced application termination; observe shutdown completion separately"})
	}
}
