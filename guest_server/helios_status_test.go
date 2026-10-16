package main

import (
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestHeliosStatus(t *testing.T) {
	root := t.TempDir()
	t.Setenv("ProgramData", root)
	write := func(relative, value string) {
		target := filepath.Join(root, relative)
		if err := os.MkdirAll(filepath.Dir(target), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(target, []byte(value), 0600); err != nil {
			t.Fatal(err)
		}
	}
	status := func() map[string]interface{} {
		recorder := httptest.NewRecorder()
		getHeliosStatus(recorder, httptest.NewRequest("GET", "/graphics/helios", nil))
		var response map[string]interface{}
		if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
			t.Fatal(err)
		}
		return response
	}
	if got := status()["status"]; got != "failed" {
		t.Fatalf("missing receipt: %v", got)
	}
	write("WinBoat/Helios/helios-build.json", `{"revision":"pinned"}`)
	if got := status()["status"]; got != "waiting" {
		t.Fatalf("missing status: %v", got)
	}
	write("Helios/provisioning-status.json", "\xef\xbb\xbf"+`{"status":"driver-restart-required"}`)
	if got := status()["status"]; got != "driver-restart-required" {
		t.Fatalf("PowerShell BOM: %v", got)
	}
	write("Helios/provisioning-status.json", `{"status":"failed","message":"Secure Boot is enabled"}`)
	if got := status()["message"]; got != "Secure Boot is enabled" {
		t.Fatalf("lost installer failure: %v", got)
	}
	write("Helios/manifest.json", `{"source":{"helios":"pinned"}}`)
	write("Helios/install-state.json", `{}`)
	write("Helios/provisioning-status.json", `{"status":"finished"}`)
	if got := status(); got["status"] != "finished" || got["revision"] != "pinned" {
		t.Fatal(got)
	}
	// A manual update must supersede the old OEM receipt, even when it remains.
	write("Helios/manifest.json", "\xef\xbb\xbf"+`{"source":{"helios":"manual"}}`)
	if got := status()["revision"]; got != "manual" {
		t.Fatalf("manual GUI installation: %v", got)
	}
	write("Helios/provisioning-status.json", "broken JSON")
	if got := status()["status"]; got != "failed" {
		t.Fatalf("corrupt progress accepted: %v", got)
	}
}
