package main

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
)

// Fixed read-only files: API callers cannot launch tests or choose executables.
func graphicsValidationStatus(root string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		result := map[string]interface{}{"scope": "Saved interactive observations; not a live rendering guarantee"}
		for _, name := range []string{"acceptance", "transaction", "last-good"} {
			path := filepath.Join(root, "WinBoat", "GraphicsValidation", name+".json")
			info, err := os.Lstat(path)
			if os.IsNotExist(err) {
				result[name] = map[string]interface{}{"status": "not-recorded"}
				continue
			}
			if err != nil || !info.Mode().IsRegular() {
				result[name] = map[string]interface{}{"error": "Validation file unavailable"}
				continue
			}
			data, err := readHeliosJSON(path)
			if err != nil || data == nil {
				result[name] = map[string]interface{}{"error": "Validation file invalid"}
				continue
			}
			result[name] = data
		}
		json.NewEncoder(w).Encode(result)
	}
}
