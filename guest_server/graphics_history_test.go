package main

import (
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"testing"
)

func TestGraphicsHistoryRetainsTransitionsAndQueryFailures(t *testing.T) {
	m := newGraphicsMonitor()
	for i := 0; i < 80; i++ {
		m.update([]byte(fmt.Sprintf(`{"helios":{"state":"running"},"basic":{"state":"running"},"desktop":{"topology":"extend","sessionId":%d},"policy":{"state":"extended"}}`, i)), nil)
	}
	m.update([]byte(`broken`), nil)
	w := httptest.NewRecorder()
	m.historyStatus(w, httptest.NewRequest("GET", "/graphics/history", nil))
	var report struct {
		Events []graphicsHistoryEvent `json:"events"`
		Age    int64                  `json:"sampleAgeMs"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &report); err != nil {
		t.Fatal(err)
	}
	if len(report.Events) != 64 || report.Events[0].SessionID != 17 || report.Events[62].SessionID != 79 ||
		report.Events[63].Helios != "unknown" || report.Age != -1 || len(w.Body.Bytes()) > 65536 {
		t.Fatal(report)
	}
	if w.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("history cached")
	}
}
