package main

import (
	"context"
	"errors"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestAtlasRecoveryGuards(t *testing.T) {
	for _, tc := range []struct {
		name, header, body string
		err                error
		code               int
	}{
		{"no consent header", "", "", nil, 400},
		{"queued", "restart-oobe", `{"status":"queued"}`, nil, 202},
		{"blocked", "restart-oobe", `{"status":"blocked"}`, nil, 409},
		{"failed", "restart-oobe", `{"status":"failed"}`, nil, 500},
		{"unexpected state", "restart-oobe", `{"status":"finished"}`, nil, 503},
		{"unstructured output", "restart-oobe", "private process error", nil, 503},
		{"process failed", "restart-oobe", "", errors.New("private exception"), 503},
		{"oversized output", "restart-oobe", strings.Repeat("x", 65537), nil, 503},
	} {
		t.Run(tc.name, func(t *testing.T) {
			calls := 0
			handler := atlasRecoveryHandler("restart-oobe", func(ctx context.Context) ([]byte, error) {
				calls++
				if _, ok := ctx.Deadline(); !ok {
					t.Fatal("unbounded recovery request")
				}
				return []byte(tc.body), tc.err
			})
			request := httptest.NewRequest("POST", "/provisioning/atlas/recovery", nil)
			request.Header.Set("X-WinBoat-Recovery", tc.header)
			response := httptest.NewRecorder()
			handler(response, request)
			if response.Code != tc.code {
				t.Fatalf("got %d: %s", response.Code, response.Body)
			}
			if tc.header == "" && calls != 0 {
				t.Fatal("recovery ran without explicit header")
			}
			if strings.Contains(response.Body.String(), "private") {
				t.Fatal("private error leaked")
			}
			if response.Header().Get("Cache-Control") != "no-store" {
				t.Fatal("recovery result must not be cached")
			}
		})
	}
}

func TestAtlasRecoveryRejectsConcurrentRequest(t *testing.T) {
	started, release, done := make(chan struct{}), make(chan struct{}), make(chan struct{})
	handler := atlasRecoveryHandler("restart-oobe", func(context.Context) ([]byte, error) {
		close(started)
		<-release
		return []byte(`{"status":"queued"}`), nil
	})
	request := func() *httptest.ResponseRecorder {
		r := httptest.NewRequest("POST", "/provisioning/atlas/recovery", nil)
		r.Header.Set("X-WinBoat-Recovery", "restart-oobe")
		w := httptest.NewRecorder()
		handler(w, r)
		return w
	}
	go func() { defer close(done); request() }()
	<-started
	second := request()
	close(release)
	<-done
	if second.Code != 409 {
		t.Fatal("second recovery request was not rejected")
	}
}

func TestAtlasUIUsesSeparateOperation(t *testing.T) {
	calls := 0
	handler := atlasRecoveryHandler("launch-ame-ui", func(context.Context) ([]byte, error) {
		calls++
		return []byte(`{"status":"launched","sessionId":1}`), nil
	})
	for _, operation := range []string{"restart-oobe", "launch-ame-ui"} {
		r := httptest.NewRequest("POST", "/provisioning/atlas/launch-ui", nil)
		r.Header.Set("X-WinBoat-Recovery", operation)
		w := httptest.NewRecorder()
		handler(w, r)
		if operation == "restart-oobe" && (w.Code != 400 || calls != 0) {
			t.Fatal("wrong action accepted")
		}
		if operation == "launch-ame-ui" && (w.Code != 202 || calls != 1) {
			t.Fatal("UI launch refused")
		}
	}
}
