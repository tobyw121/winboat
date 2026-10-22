package main

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"
)

type apiGrant struct {
	Identity string
	Expires  time.Time
	Scopes   map[string]bool
}
type apiPairRequest struct {
	Code   string   `json:"code"`
	Scopes []string `json:"scopes"`
}
type apiSessions struct {
	mu       sync.Mutex
	pairing  sync.Mutex
	grants   map[string]apiGrant
	lastPair time.Time
	enabled  func() bool
	identity func() string
	consent  func(context.Context, apiPairRequest) error
}

func apiScope(r *http.Request) string {
	if r.Method == "GET" {
		return "read"
	}
	switch {
	case strings.HasPrefix(r.URL.Path, "/graphics/"):
		return "graphics"
	case r.URL.Path == "/integration/power":
		return "power"
	case r.URL.Path == "/integration/application":
		return "application"
	case r.URL.Path == "/integration/clipboard":
		return "clipboard"
	default:
		return "maintenance"
	}
}
func (s *apiSessions) middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/integration/session" {
			s.handler(w, r)
			return
		}
		if !s.enabled() || r.URL.Path == "/health" || r.URL.Path == "/version" {
			next.ServeHTTP(w, r)
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		if r.Header.Get("Origin") != "" {
			http.Error(w, "Desktop session required", 403)
			return
		}
		token := r.Header.Get("X-WinBoat-Session")
		s.mu.Lock()
		grant, ok := s.grants[token]
		s.mu.Unlock()
		if !ok || len(token) != 64 || time.Now().After(grant.Expires) || grant.Identity == "" || grant.Identity != s.identity() {
			http.Error(w, "Pair a current Windows API session", 401)
			return
		}
		if !grant.Scopes[apiScope(r)] {
			http.Error(w, "Session scope denied", 403)
			return
		}
		if r.Method != "GET" {
			log.Printf("API scoped action scope=%s method=%s path=%q", apiScope(r), r.Method, r.URL.Path)
		}
		next.ServeHTTP(w, r)
	})
}
func (s *apiSessions) handler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	if r.Header.Get("Origin") != "" {
		http.Error(w, "Desktop client required", 403)
		return
	}
	if r.Method == "GET" {
		json.NewEncoder(w).Encode(map[string]interface{}{"required": s.enabled(), "ttlSeconds": 600})
		return
	}
	if r.Method == "DELETE" {
		token := r.Header.Get("X-WinBoat-Session")
		s.mu.Lock()
		for key := range s.grants {
			if len(token) == 64 && subtle.ConstantTimeCompare([]byte(key), []byte(token)) == 1 {
				delete(s.grants, key)
			}
		}
		s.mu.Unlock()
		w.WriteHeader(204)
		return
	}
	if r.Method != "POST" || r.Header.Get("X-WinBoat-Pair") != "windows-consent" {
		http.Error(w, "Explicit pairing required", 400)
		return
	}
	var request apiPairRequest
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&request) != nil || len(request.Code) != 6 || strings.Trim(request.Code, "0123456789") != "" || len(request.Scopes) == 0 || len(request.Scopes) > 6 {
		http.Error(w, "Invalid pairing request", 400)
		return
	}
	scopes := map[string]bool{}
	for _, scope := range request.Scopes {
		switch scope {
		case "read", "graphics", "power", "application", "clipboard", "maintenance":
			scopes[scope] = true
		default:
			http.Error(w, "Unknown scope", 400)
			return
		}
	}
	if !s.pairing.TryLock() {
		http.Error(w, "Pairing pending", 409)
		return
	}
	defer s.pairing.Unlock()
	if time.Since(s.lastPair) < 15*time.Second {
		http.Error(w, "Pairing cooldown", 429)
		return
	}
	s.lastPair = time.Now()
	identity := s.identity()
	if identity == "" {
		http.Error(w, "Sign in to Windows", 503)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 90*time.Second)
	defer cancel()
	if s.consent(ctx, request) != nil || s.identity() != identity {
		http.Error(w, "Pairing denied or console changed", 403)
		return
	}
	var data [32]byte
	if _, err := rand.Read(data[:]); err != nil {
		http.Error(w, "Pairing unavailable", 503)
		return
	}
	key := hex.EncodeToString(data[:])
	expires := time.Now().Add(10 * time.Minute)
	s.mu.Lock()
	if s.grants == nil {
		s.grants = map[string]apiGrant{}
	}
	for token, grant := range s.grants {
		if time.Now().After(grant.Expires) || grant.Identity != identity {
			delete(s.grants, token)
		}
	}
	if len(s.grants) >= 16 {
		s.mu.Unlock()
		http.Error(w, "Session limit", 429)
		return
	}
	s.grants[key] = apiGrant{Identity: identity, Expires: expires, Scopes: scopes}
	s.mu.Unlock()
	json.NewEncoder(w).Encode(map[string]interface{}{"token": key, "expiresAtUtc": expires.UTC(), "scopes": request.Scopes})
}
