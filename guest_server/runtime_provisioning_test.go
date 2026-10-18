package main

import (
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestVCRedistStatus(t *testing.T) {
	root := t.TempDir()
	t.Setenv("ProgramData", root)
	path := filepath.Join(root, "WinBoat", "VCRedist", "status.json")
	for _, test := range []struct{ data, status string }{
		{"", "waiting"},
		{`{"status":"finished","revision":"vcredist-v1","rebootRequired":true}`, "finished"},
		{`{"status":"waiting","message":"Waiting for AME/Atlas"}`, "waiting"},
		{"not-json", "failed"},
	} {
		if test.data != "" {
			if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(path, []byte(test.data), 0600); err != nil {
				t.Fatal(err)
			}
		}
		response := httptest.NewRecorder()
		getVCRedistStatus(response, httptest.NewRequest("GET", "/provisioning/vcredist", nil))
		var result map[string]interface{}
		if err := json.Unmarshal(response.Body.Bytes(), &result); err != nil {
			t.Fatal(err)
		}
		if result["status"] != test.status || response.Header().Get("Cache-Control") != "no-store" {
			t.Fatalf("unexpected runtime state: %s", response.Body.String())
		}
		if test.status == "finished" && result["rebootRequired"] != true {
			t.Fatal("installer reboot result was lost")
		}
	}
}
