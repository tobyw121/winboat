package main

import (
	"context"
	"errors"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestGraphicsMonitor(t *testing.T) {
	m := newGraphicsMonitor()
	read := func() string {
		w := httptest.NewRecorder()
		m.status(w, httptest.NewRequest("GET", "/graphics/adapters", nil))
		return w.Body.String()
	}
	if !strings.Contains(read(), `"state":"unknown"`) || !strings.Contains(read(), `"sampleAgeMs":-1`) {
		t.Fatal(read())
	}
	m.update([]byte(`{"helios":{"state":"running"},"basic":{"state":"disabled"},"recovery":"none"}`), nil)
	if !strings.Contains(read(), `"state":"running"`) || !strings.Contains(read(), `"state":"disabled"`) {
		t.Fatal(read())
	}
	if _, err := time.Parse(time.RFC3339Nano, m.snapshot.UpdatedAtUTC); err != nil {
		t.Fatal(err)
	}
	for _, data := range []string{`{}`, `{"helios":{"state":"bogus"}}`, `not json`, strings.Repeat("x", 65537)} {
		m.update([]byte(data), nil)
		if !strings.Contains(read(), `"state":"unknown"`) || strings.Contains(read(), `"state":"failed"`) {
			t.Fatal(read())
		}
	}
	m.update(nil, errors.New("WMI unavailable"))
	if !strings.Contains(read(), "Windows adapter status unavailable") {
		t.Fatal(read())
	}
}
func TestGraphicsMonitorStopsWithoutOverlapping(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	calls := 0
	m := newGraphicsMonitor()
	m.run(ctx, func(context.Context, bool) ([]byte, error) { calls++; cancel(); return nil, errors.New("offline") })
	if calls != 1 {
		t.Fatal(calls)
	}
}

func TestViewerRecoveryHint(t *testing.T) {
	m := newGraphicsMonitor()
	request := func(header string) int {
		r := httptest.NewRequest("POST", "/graphics/adapters/recovery", nil)
		r.Header.Set("X-WinBoat-Recovery", header)
		w := httptest.NewRecorder()
		m.viewerRecovery(w, r)
		return w.Code
	}
	if request("") != 400 || !m.viewerUnavailableUntil.IsZero() {
		t.Fatal("Unmarked request changed recovery")
	}
	if request("arbitrary-command") != 400 {
		t.Fatal("Unknown command accepted")
	}
	if request("display-fallback") != 202 || !time.Now().Before(m.viewerUnavailableUntil) {
		t.Fatal("Viewer failure was not queued")
	}
	ctx, cancel := context.WithCancel(context.Background())
	m.run(ctx, func(_ context.Context, unavailable bool) ([]byte, error) {
		defer cancel()
		if !unavailable {
			t.Error("Healthy PnP state suppressed the viewer failure hint")
		}
		return []byte(`{"helios":{"state":"running"},"basic":{"state":"disabled"}}`), nil
	})
	if request("display-ready") != 202 || !m.viewerUnavailableUntil.IsZero() {
		t.Fatal("Recovered Helios did not clear its hint")
	}
}
func TestNativePollingOnlySpawnsRecoveryWhenNeeded(t *testing.T) {
	pnp := displayAdapters{Helios: displayAdapter{State: "running", InstanceID: "helios"}, Basic: displayAdapter{State: "running"}}
	if needsVGARecovery(pnp, true, true) {
		t.Fatal("Healthy VGA spawned PowerShell")
	}
	pnp.Basic.State = "disabled"
	if needsVGARecovery(pnp, false, false) {
		t.Fatal("Intentional VGA disable changed")
	}
	if !needsVGARecovery(pnp, false, true) {
		t.Fatal("Viewer failure did not restore VGA")
	}
	pnp.Helios = displayAdapter{State: "unknown"}
	if needsVGARecovery(pnp, false, false) {
		t.Fatal("Unknown state triggered repair")
	}
	if !needsVGARecovery(pnp, true, false) {
		t.Fatal("Selected mirror lost VGA recovery")
	}
}
