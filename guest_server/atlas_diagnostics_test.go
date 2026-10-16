package main

import (
	"context"
	"errors"
	"net/http/httptest"
	"testing"
)

func TestAtlasDiagnostics(t *testing.T) {
	for _, tc := range []struct {
		name   string
		data   []byte
		err    error
		status int
	}{
		{"valid", []byte(`{"service":[],"startup":["Worker Start"]}`), nil, 200},
		{"invalid", []byte("unstructured secret output"), nil, 503},
		{"error", nil, errors.New("private exception detail"), 503},
		{"oversized", make([]byte, 65537), nil, 503},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := httptest.NewRecorder()
			atlasDiagnosticsHandler(func(ctx context.Context) ([]byte, error) {
				if _, ok := ctx.Deadline(); !ok {
					t.Fatal("collector must have a timeout")
				}
				return tc.data, tc.err
			})(r, httptest.NewRequest("GET", "/provisioning/atlas/diagnostics", nil))
			if r.Code != tc.status {
				t.Fatalf("got %d: %s", r.Code, r.Body)
			}
			if r.Header().Get("Cache-Control") != "no-store" {
				t.Fatal("diagnostics must not be cached")
			}
			if tc.status != 200 && r.Body.String() != "{\"error\":\"Atlas diagnostic collection failed; provisioning was not changed\"}\n" {
				t.Fatal("collector output leaked")
			}
		})
	}
}
