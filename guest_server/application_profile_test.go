package main

import (
	"context"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestApplicationProfileConsentBoundary(t *testing.T) {
	calls := 0
	handler := applicationProfileHandler(func(context.Context, applicationProfile) error { calls++; return nil })
	body := `{"schema":1,"exe":"C:\\Games\\app.exe","api":"native","args":["--windowed"]}`
	for _, row := range []struct {
		origin, header string
		status         int
	}{{"", "confirm-in-windows", 204}, {"http://browser", "confirm-in-windows", 403}, {"", "", 403}} {
		request := httptest.NewRequest("POST", "/integration/application", strings.NewReader(body))
		request.Header.Set("Origin", row.origin)
		request.Header.Set("X-WinBoat-Application", row.header)
		out := httptest.NewRecorder()
		handler(out, request)
		if out.Code != row.status {
			t.Fatal(out.Code, out.Body.String())
		}
	}
	if calls != 1 {
		t.Fatal(calls)
	}
	if validApplicationProfile(applicationProfile{Schema: 1, Exe: "cmd.exe", API: "native"}) {
		t.Fatal("relative executable accepted")
	}
	if validApplicationProfile(applicationProfile{Schema: 1, Exe: `C:\app.exe`, API: "native", Args: []string{"a\nb"}}) {
		t.Fatal("newline accepted")
	}
}

func TestApplicationRecipeValidation(t *testing.T) {
	p := applicationProfile{Schema: 1, Exe: `C:\game.exe`, API: "native", Recipe: "d3d11-fl10-v1"}
	if !validApplicationProfile(p) {
		t.Fatal("versioned recipe rejected")
	}
	p.RebindRecipe = true
	if !validApplicationProfile(p) {
		t.Fatal("explicit rebind rejected")
	}
	p.API = "compatibility"
	if validApplicationProfile(p) {
		t.Fatal("stacked overrides accepted")
	}
	p.API = "native"
	p.Recipe = "unknown"
	if validApplicationProfile(p) {
		t.Fatal("unknown recipe accepted")
	}
	p.Recipe = ""
	if validApplicationProfile(p) {
		t.Fatal("rebind without recipe accepted")
	}
}
