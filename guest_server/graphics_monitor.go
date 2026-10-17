package main

import (
	"context"
	"encoding/json"
	"net/http"
	"sync"
	"time"
)

const graphicsProtocol = "helios-watchdog-v1"

type displayAdapter struct {
	State       string `json:"state"`
	InstanceID  string `json:"instanceId"`
	ProblemCode int    `json:"problemCode"`
	Service     string `json:"service"`
}
type displayAdapters struct {
	SampleAgeMS  int64          `json:"sampleAgeMs"`
	Helios       displayAdapter `json:"helios"`
	Basic        displayAdapter `json:"basic"`
	Recovery     string         `json:"recovery"`
	UpdatedAtUTC string         `json:"updatedAtUtc"`
	Error        string         `json:"error,omitempty"`
}
type graphicsMonitor struct {
	mu         sync.RWMutex
	snapshot   displayAdapters
	lastSample time.Time
}

func newGraphicsMonitor() *graphicsMonitor {
	return &graphicsMonitor{snapshot: displayAdapters{Helios: displayAdapter{State: "unknown"}, Basic: displayAdapter{State: "unknown"}, Recovery: "none"}}
}
func (m *graphicsMonitor) update(data []byte, err error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var next displayAdapters
	valid := func(state string) bool {
		switch state {
		case "running", "disabled", "failed", "missing", "unknown":
			return true
		}
		return false
	}
	if err != nil || len(data) > 65536 || json.Unmarshal(data, &next) != nil || !valid(next.Helios.State) || !valid(next.Basic.State) {
		// A WMI/query failure is not evidence of a crashed graphics adapter.
		m.lastSample = time.Time{}
		m.snapshot = displayAdapters{Helios: displayAdapter{State: "unknown"}, Basic: displayAdapter{State: "unknown"}, Recovery: "none", Error: "Windows adapter status unavailable"}
		return
	}
	next.UpdatedAtUTC = time.Now().UTC().Format(time.RFC3339Nano)
	m.snapshot = next
	m.lastSample = time.Now()
}
func (m *graphicsMonitor) run(ctx context.Context, collect func(context.Context) ([]byte, error)) {
	for {
		check, cancel := context.WithTimeout(ctx, 12*time.Second)
		data, err := collect(check)
		cancel()
		m.update(data, err)
		select {
		case <-ctx.Done():
			return
		case <-time.After(5 * time.Second):
		}
	}
}
func (m *graphicsMonitor) status(w http.ResponseWriter, r *http.Request) {
	m.mu.RLock()
	snapshot := m.snapshot
	snapshot.SampleAgeMS = -1
	if !m.lastSample.IsZero() {
		snapshot.SampleAgeMS = time.Since(m.lastSample).Milliseconds()
	}
	m.mu.RUnlock()
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	json.NewEncoder(w).Encode(snapshot)
}
