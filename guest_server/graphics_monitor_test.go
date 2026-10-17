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
	m.run(ctx, func(context.Context) ([]byte, error) { calls++; cancel(); return nil, errors.New("offline") })
	if calls != 1 {
		t.Fatal(calls)
	}
}
