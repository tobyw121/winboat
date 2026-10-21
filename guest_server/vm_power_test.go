package main

import (
	"context"
	"net/http/httptest"
	"testing"
)

func TestPowerRequests(t *testing.T) {
	calls := 0
	handler := vmPowerHandler(func(ctx context.Context, reboot bool) error {
		calls++
		if !reboot {
			t.Error("wrong action")
		}
		return nil
	})
	for _, row := range []struct {
		method, action, origin string
		status                 int
	}{{"POST", "reboot", "", 200}, {"GET", "reboot", "", 400}, {"POST", "reboot", "http://untrusted", 400}, {"POST", "force", "", 400}} {
		r := httptest.NewRequest(row.method, "/integration/power", nil)
		r.Header.Set("X-WinBoat-Power", row.action)
		r.Header.Set("Origin", row.origin)
		w := httptest.NewRecorder()
		handler(w, r)
		if w.Code != row.status {
			t.Fatal(w.Code)
		}
	}
	if calls != 1 {
		t.Fatal(calls)
	}
}
