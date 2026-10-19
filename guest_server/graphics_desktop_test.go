package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestLoadedAdapterWithoutWindowsDesktop(t *testing.T) {
	input := []byte(`{"helios":{"state":"running","service":"helios_kmd_render"},"basic":{"state":"running"}}`)
	desktop := desktopSnapshot{SessionID: 1, Helios: desktopOutput{State: "inactive"}, Basic: desktopOutput{State: "active", Primary: true}}
	if !desktopRequiresFallback(desktop, nil) || desktopRequiresFallback(desktop, errors.New("session unavailable")) {
		t.Fatal("inactive desktop fallback did not distinguish a failed session query")
	}
	active := desktop
	active.Helios.State = "active"
	if desktopRequiresFallback(active, nil) {
		t.Fatal("healthy desktop triggered recovery")
	}
	data, err := mergeDesktopStatus(input, desktop, nil)
	if err != nil {
		t.Fatal(err)
	}
	var status displayAdapters
	if err = json.Unmarshal(data, &status); err != nil {
		t.Fatal(err)
	}
	if status.Helios.State != "running" || status.Helios.DesktopState != "inactive" || status.Basic.DesktopState != "active" || !status.Desktop.Basic.Primary {
		t.Fatal(string(data))
	}
	data, err = mergeDesktopStatus(input, desktop, errors.New("private session failure"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `"desktopState":"unknown"`) || strings.Contains(string(data), "private session failure") || strings.Contains(string(data), `"desktop":`) {
		t.Fatal(string(data))
	}
	if _, err = mergeDesktopStatus([]byte("broken"), desktop, nil); err == nil {
		t.Fatal("invalid PnP data accepted")
	}
}

func TestHeliosDriverDiagnostics(t *testing.T) {
	for _, data := range []string{`{"driverRegistry":{"DspH":0}}`, `not json`, `[]`, `null`, strings.Repeat("x", 65537)} {
		m := newGraphicsMonitor()
		w := httptest.NewRecorder()
		m.diagnostics(func(ctx context.Context) ([]byte, error) {
			if _, ok := ctx.Deadline(); !ok {
				t.Fatal("no deadline")
			}
			return []byte(data), nil
		})(w, httptest.NewRequest("GET", "/graphics/diagnostics", nil))
		if strings.HasPrefix(data, `{"driverRegistry"`) {
			if w.Code != 200 || !strings.Contains(w.Body.String(), `"DspH":0`) || !strings.Contains(w.Body.String(), `"sampleAgeMs":-1`) {
				t.Fatal(w.Body.String())
			}
		} else if w.Code != 503 {
			t.Fatal(w.Code, w.Body.String())
		}
	}
}

func TestDiagnosticsConcurrencyIsBounded(t *testing.T) {
	m := newGraphicsMonitor()
	started := make(chan struct{})
	release := make(chan struct{})
	done := make(chan struct{})
	first := httptest.NewRecorder()
	go func() {
		defer close(done)
		m.diagnostics(func(context.Context) ([]byte, error) { close(started); <-release; return []byte(`{}`), nil })(first, httptest.NewRequest("GET", "/graphics/diagnostics", nil))
	}()
	<-started
	second := httptest.NewRecorder()
	m.diagnostics(func(context.Context) ([]byte, error) {
		t.Error("concurrent PowerShell collector started")
		return nil, nil
	})(second, httptest.NewRequest("GET", "/graphics/diagnostics/runtime", nil))
	close(release)
	<-done
	if first.Code != 200 || second.Code != 409 {
		t.Fatal(first.Code, second.Code)
	}
}
