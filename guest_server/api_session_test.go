package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestSessionConsentScopesExpiryAndLogoff(t *testing.T) {
	identity := "console-one"
	consented := false
	s := apiSessions{enabled: func() bool { return true }, identity: func() string { return identity }, consent: func(context.Context, apiPairRequest) error { consented = true; return nil }}
	handler := s.middleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) }))
	call := func(method, path, token, body string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, path, strings.NewReader(body))
		r.Header.Set("X-WinBoat-Session", token)
		r.Header.Set("X-WinBoat-Pair", "windows-consent")
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		return w
	}
	if call("POST", "/integration/power", "", "").Code != 401 {
		t.Fatal("unauthorized mutation")
	}
	w := call("POST", "/integration/session", "", `{"code":"123456","scopes":["read"]}`)
	var response map[string]interface{}
	json.Unmarshal(w.Body.Bytes(), &response)
	key, _ := response["token"].(string)
	if len(key) != 64 || !consented {
		t.Fatal(w.Body.String())
	}
	if call("GET", "/graphics/adapters", key, "").Code != 204 || call("POST", "/integration/power", key, "").Code != 403 {
		t.Fatal("scope boundary")
	}
	identity = "console-two"
	if call("GET", "/graphics/adapters", key, "").Code != 401 {
		t.Fatal("session survived logoff")
	}
	identity = "console-one"
	s.grants[key] = apiGrant{Identity: identity, Expires: time.Now().Add(-time.Second), Scopes: map[string]bool{"read": true}}
	if call("GET", "/graphics/adapters", key, "").Code != 401 {
		t.Fatal("expired session")
	}
}
