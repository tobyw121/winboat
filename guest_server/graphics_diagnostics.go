package main

import (
	"context"
	"encoding/json"
	"net/http"
	"sync"
	"time"
)

var graphicsDiagnosticMutex sync.Mutex

func (m *graphicsMonitor) diagnostics(collect func(context.Context) ([]byte, error)) http.HandlerFunc {
	var cacheMu sync.Mutex
	var cached []byte
	var collected time.Time
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		if !graphicsDiagnosticMutex.TryLock() {
			http.Error(w, `{"error":"Graphics diagnostics already active"}`, http.StatusConflict)
			return
		}
		defer graphicsDiagnosticMutex.Unlock()
		ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
		defer cancel()
		cacheMu.Lock()
		defer cacheMu.Unlock()
		data := cached
		var err error
		refresh := data == nil || time.Since(collected) >= 5*time.Second
		if refresh {
			data, err = collect(ctx)
		}
		var driver map[string]interface{}
		if err != nil || len(data) > 65536 || json.Unmarshal(data, &driver) != nil || driver == nil {
			http.Error(w, `{"error":"Helios driver diagnostics unavailable"}`, http.StatusServiceUnavailable)
			return
		}
		if refresh {
			cached = append([]byte(nil), data...)
			collected = time.Now()
		}
		m.mu.RLock()
		status := m.snapshot
		status.SampleAgeMS = -1
		if !m.lastSample.IsZero() {
			status.SampleAgeMS = time.Since(m.lastSample).Milliseconds()
		}
		m.mu.RUnlock()
		json.NewEncoder(w).Encode(map[string]interface{}{"adapters": status, "driver": driver, "collectorAgeMs": time.Since(collected).Milliseconds()})
	}
}
