package main

import (
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestAtlasStatus(t *testing.T) {
	root := t.TempDir()
	t.Setenv("ProgramData", root)
	dir := filepath.Join(root, "WinBoat", "Atlas")
	if err := os.MkdirAll(dir, 0700); err != nil { t.Fatal(err) }
	for _, test := range []struct { data string; status string }{
		{"", "waiting"},
		{`{"status":"awaiting-user","release":"0.5.0-hotfix","message":"Restart required"}`, "awaiting-user"},
		{`{"status":"finished","release":"0.5.0-hotfix","message":"Applied"}`, "finished"},
		{"invalid JSON", "failed"},
	} {
		if test.data != "" {
			if err := os.WriteFile(filepath.Join(dir, "status.json"), []byte(test.data), 0600); err != nil { t.Fatal(err) }
		}
		r := httptest.NewRecorder()
		getAtlasStatus(r, httptest.NewRequest("GET", "/provisioning/atlas", nil))
		var state map[string]interface{}
		if err := json.Unmarshal(r.Body.Bytes(), &state); err != nil { t.Fatal(err) }
		if state["status"] != test.status { t.Fatalf("got %v, want %s", state, test.status) }
		if r.Header().Get("Cache-Control") != "no-store" { t.Fatal("status must not be cached") }
	}
}
