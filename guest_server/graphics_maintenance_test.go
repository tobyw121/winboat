package main

import (
	"context"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestMaintenanceFixedActions(t *testing.T) {
	calls := 0
	handler := graphicsMaintenanceHandler(func(_ context.Context, action string) ([]byte, error) {
		calls++
		return []byte(`{"status":"rollback-staged"}`), nil
	})
	for _, action := range []string{"install", "cmd.exe", "", "prepare-rollback", "check-update", "capture-enable", "capture-disable"} {
		r := httptest.NewRequest("POST", "/graphics/maintenance", strings.NewReader(`{"path":"C:\\other.exe"}`))
		r.Header.Set("X-WinBoat-Maintenance", action)
		w := httptest.NewRecorder()
		handler(w, r)
		want := 400
		if action == "prepare-rollback" || action == "check-update" || strings.HasPrefix(action, "capture-") {
			want = 200
		}
		if w.Code != want {
			t.Fatalf("%s: %d", action, w.Code)
		}
	}
	if calls != 4 {
		t.Fatal(calls)
	}
	graphicsRescueMutex.Lock()
	defer graphicsRescueMutex.Unlock()
	r := httptest.NewRequest("POST", "/graphics/maintenance", nil)
	r.Header.Set("X-WinBoat-Maintenance", "check-update")
	w := httptest.NewRecorder()
	handler(w, r)
	if w.Code != 409 || calls != 4 {
		t.Fatal("overlapping maintenance")
	}
}
