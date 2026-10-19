package main

import (
	"encoding/json"
	"net/http"
	"time"
)

type graphicsHistoryEvent struct {
	AtUTC             string `json:"atUtc"`
	Helios            string `json:"helios"`
	VGA               string `json:"vga"`
	Topology          string `json:"topology"`
	Policy            string `json:"policy"`
	Error             string `json:"error,omitempty"`
	SessionID         uint32 `json:"sessionId"`
	ViewerUnavailable bool   `json:"viewerUnavailable"`
}

// Called with m.mu held. Fixed fields only; no process command lines/log text.
func (m *graphicsMonitor) recordHistory(now time.Time) {
	s := m.snapshot
	event := graphicsHistoryEvent{AtUTC: now.UTC().Format(time.RFC3339Nano), Helios: s.Helios.State, VGA: s.Basic.State,
		ViewerUnavailable: now.Before(m.viewerUnavailableUntil), Error: s.DesktopError}
	if s.Desktop != nil {
		event.Topology = s.Desktop.Topology
		event.SessionID = s.Desktop.SessionID
	}
	if s.Policy != nil {
		event.Policy = s.Policy.State
		if s.Policy.Error != "" {
			event.Error = s.Policy.Error
		}
	}
	if s.Error != "" {
		event.Error = s.Error
	}
	for _, field := range []*string{&event.Topology, &event.Policy, &event.Error} {
		if len(*field) > 128 {
			*field = (*field)[:128]
		}
	}
	if len(m.history) == 64 {
		copy(m.history, m.history[1:])
		m.history = m.history[:63]
	}
	m.history = append(m.history, event)
}
func (m *graphicsMonitor) historyStatus(w http.ResponseWriter, r *http.Request) {
	m.mu.RLock()
	events := append([]graphicsHistoryEvent{}, m.history...)
	age := int64(-1)
	if !m.lastSample.IsZero() {
		age = time.Since(m.lastSample).Milliseconds()
	}
	m.mu.RUnlock()
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	json.NewEncoder(w).Encode(map[string]interface{}{"events": events, "sampleAgeMs": age, "capacity": 64,
		"scope": "Service-memory observations; resets on service restart, not proof of rendered frames"})
}
