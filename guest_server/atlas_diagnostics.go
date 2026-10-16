package main

import (
	"context"
	"encoding/json"
	"net/http"
	"time"
)

// The collector runs one fixed, read-only script. No caller-supplied paths or commands.
func atlasDiagnosticsHandler(collect func(context.Context) ([]byte, error)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
		defer cancel()
		data, err := collect(ctx)
		if err != nil || len(data) > 65536 || !json.Valid(data) {
			w.WriteHeader(http.StatusServiceUnavailable)
			json.NewEncoder(w).Encode(map[string]string{"error": "Atlas diagnostic collection failed; provisioning was not changed"})
			return
		}
		w.Write(data)
	}
}
