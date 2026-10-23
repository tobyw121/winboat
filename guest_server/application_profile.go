package main

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"sync"
	"time"
)

var applicationProfileMutex sync.Mutex

type applicationProfile struct {
	Schema       int      `json:"schema"`
	Exe          string   `json:"exe"`
	Resolution   string   `json:"resolution"`
	Transport    string   `json:"transport"`
	API          string   `json:"api"`
	Args         []string `json:"args"`
	Recipe       string   `json:"recipe,omitempty"`
	RebindRecipe bool     `json:"rebindRecipe,omitempty"`
}

func validApplicationProfile(p applicationProfile) bool {
	if p.Schema != 1 || len(p.Exe) > 1024 || !strings.HasSuffix(strings.ToLower(p.Exe), ".exe") || !((len(p.Exe) > 3 && p.Exe[1] == ':' && p.Exe[2] == '\\') || strings.HasPrefix(p.Exe, `\\`)) || strings.ContainsAny(p.Exe, "\x00\r\n") || (p.API != "native" && p.API != "compatibility") || len(p.Args) > 32 {
		return false
	}
	if p.Recipe != "" && (p.API != "native" || (p.Recipe != "d3d11-fl10-v1" && p.Recipe != "d3d11-backend-caps-v1")) {
		return false
	}
	if p.RebindRecipe && p.Recipe == "" {
		return false
	}
	for _, a := range p.Args {
		if len(a) > 2048 || strings.ContainsAny(a, "\x00\r\n") {
			return false
		}
	}
	return true
}
func applicationProfileHandler(run func(context.Context, applicationProfile) error) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		if r.Method != "POST" || r.Header.Get("Origin") != "" || r.Header.Get("X-WinBoat-Application") != "confirm-in-windows" {
			http.Error(w, "Explicit desktop request required", 403)
			return
		}
		if !applicationProfileMutex.TryLock() {
			http.Error(w, "Application confirmation already pending", 409)
			return
		}
		defer applicationProfileMutex.Unlock()
		var p applicationProfile
		d := json.NewDecoder(http.MaxBytesReader(w, r.Body, 131072))
		d.DisallowUnknownFields()
		if d.Decode(&p) != nil || !validApplicationProfile(p) {
			http.Error(w, "Invalid application profile", 400)
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 90*time.Second)
		defer cancel()
		if run(ctx, p) != nil {
			http.Error(w, "Application not started. Check Windows consent, executable and installed profile support.", 409)
			return
		}
		w.WriteHeader(204)
	}
}
