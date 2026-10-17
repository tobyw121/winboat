package main

import (
	"context"
	"encoding/json"
	"net/http"
	"time"
)

func (m *graphicsMonitor) diagnostics(collect func(context.Context) ([]byte, error)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
		defer cancel()
		data, err := collect(ctx)
		var driver map[string]interface{}
		if err != nil || len(data) > 65536 || json.Unmarshal(data, &driver) != nil || driver == nil {
			http.Error(w, `{"error":"Helios driver diagnostics unavailable"}`, http.StatusServiceUnavailable)
			return
		}
		m.mu.RLock()
		status := m.snapshot
		status.SampleAgeMS = -1
		if !m.lastSample.IsZero() {
			status.SampleAgeMS = time.Since(m.lastSample).Milliseconds()
		}
		m.mu.RUnlock()
		json.NewEncoder(w).Encode(map[string]interface{}{"adapters": status, "driver": driver})
	}
}
