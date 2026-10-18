package main

import (
	"context"
	"errors"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestGraphicsRescueFixedOperations(t *testing.T) {
	calls := 0
	result := `{"status":"disabled"}`
	var runErr error
	handler := graphicsRescueHandler(func(_ context.Context, action string) ([]byte, error) {
		calls++
		if action != "helios-disable" && action != "helios-enable" {
			t.Fatal(action)
		}
		return []byte(result), runErr
	})
	request := func(action string) int {
		r := httptest.NewRequest("POST", "/graphics/rescue", nil)
		r.Header.Set("X-WinBoat-Recovery", action)
		w := httptest.NewRecorder()
		handler(w, r)
		return w.Code
	}
	if request("") != 400 || request("arbitrary-command") != 400 || calls != 0 {
		t.Fatal("Unmarked operation executed")
	}
	if request("helios-disable") != 200 {
		t.Fatal("Disable failed")
	}
	result = `{"status":"enabled"}`
	if request("helios-enable") != 200 {
		t.Fatal("Enable failed")
	}
	for status, code := range map[string]int{"blocked": 409, "restart-required": 202, "failed": 500, "invented": 503} {
		result = `{"status":"` + status + `"}`
		if request("helios-disable") != code {
			t.Fatal(status)
		}
	}
	result = strings.Repeat("x", 8193)
	if request("helios-disable") != 503 {
		t.Fatal("Oversized result accepted")
	}
	runErr = errors.New("fixture")
	if request("helios-disable") != 503 {
		t.Fatal("Failed execution accepted")
	}
}
