package main

import (
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestValidationStatusMissingInvalidAndRecorded(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, "WinBoat", "GraphicsValidation")
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	for _, content := range []string{`{"status":"awaiting-acceptance"}`, `{bad`, strings.Repeat("x", 65537)} {
		if err := os.WriteFile(filepath.Join(dir, "transaction.json"), []byte(content), 0600); err != nil {
			t.Fatal(err)
		}
		w := httptest.NewRecorder()
		graphicsValidationStatus(root)(w, httptest.NewRequest("GET", "/graphics/validation", nil))
		body := w.Body.String()
		if !strings.Contains(body, "not-recorded") || strings.Contains(body, root) {
			t.Fatal(body)
		}
		if strings.HasPrefix(content, `{"status"`) {
			if !strings.Contains(body, "awaiting-acceptance") {
				t.Fatal(body)
			}
		} else if !strings.Contains(body, "Validation file invalid") {
			t.Fatal(body)
		}
	}
}
