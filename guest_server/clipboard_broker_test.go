package main

import (
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

type fakeClipboard struct {
	rows   []clipboardMessage
	closed bool
}

func (f *fakeClipboard) Send(m clipboardMessage) error { f.rows = append(f.rows, m); return nil }
func (f *fakeClipboard) Close()                        { f.closed = true }
func TestClipboardConsentDirectionsExpiryAndNoSecretLeak(t *testing.T) {
	f := &fakeClipboard{}
	var emit func(clipboardMessage)
	b := clipboardBroker{launch: func(p clipboardPolicy, cb func(clipboardMessage)) (clipboardWorker, error) { emit = cb; return f, nil }}
	call := func(method, body, token string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, "/integration/clipboard", strings.NewReader(body))
		if token == "connect" {
			r.Header.Set("X-WinBoat-Clipboard", token)
		} else {
			r.Header.Set("X-WinBoat-Clipboard-Token", token)
		}
		w := httptest.NewRecorder()
		b.handler(w, r)
		return w
	}
	w := call("POST", `{"toHost":true}`, "connect")
	var result map[string]string
	json.Unmarshal(w.Body.Bytes(), &result)
	key := result["token"]
	if len(key) != 64 {
		t.Fatal(w.Body.String())
	}
	if call("GET", "", "wrong").Code != 403 {
		t.Fatal("Unauthenticated clipboard")
	}
	if call("POST", `{"kind":"read"}`, key).Code != 409 {
		t.Fatal("Read before consent")
	}
	emit(clipboardMessage{Kind: "ready"})
	emit(clipboardMessage{Kind: "text", Text: "private-text"})
	if !strings.Contains(call("GET", "", key).Body.String(), "private-text") {
		t.Fatal("Missing event")
	}
	if call("POST", `{"kind":"write","text":"no"}`, key).Code != 409 {
		t.Fatal("Wrong direction allowed")
	}
	emit(clipboardMessage{Kind: "locked"})
	if strings.Contains(call("GET", "", key).Body.String(), "private-text") {
		t.Fatal("Lock retained clipboard")
	}
	b.last = time.Now().Add(-time.Minute)
	if call("GET", "", key).Code != 403 || !f.closed {
		t.Fatal("Expired session survived")
	}
}
func TestClipboardInputBoundsAndBrowserOrigins(t *testing.T) {
	if validClipboard("bad\x00text") || validClipboard(strings.Repeat("x", clipboardLimit+1)) {
		t.Fatal("Invalid text accepted")
	}
	b := clipboardBroker{}
	r := httptest.NewRequest("POST", "/", strings.NewReader(`{}`))
	r.Header.Set("Origin", "https://example.com")
	w := httptest.NewRecorder()
	b.handler(w, r)
	if w.Code != 403 {
		t.Fatal("Browser origin paired")
	}
}

func TestImagesRequireSeparateConsentAndAreOneShot(t *testing.T) {
	f := &fakeClipboard{}
	var emit func(clipboardMessage)
	b := clipboardBroker{launch: func(p clipboardPolicy, cb func(clipboardMessage)) (clipboardWorker, error) { emit = cb; return f, nil }}
	call := func(body, token string) *httptest.ResponseRecorder {
		r := httptest.NewRequest("POST", "/integration/clipboard", strings.NewReader(body))
		if token == "connect" {
			r.Header.Set("X-WinBoat-Clipboard", token)
		} else {
			r.Header.Set("X-WinBoat-Clipboard-Token", token)
		}
		w := httptest.NewRecorder()
		b.handler(w, r)
		return w
	}
	w := call(`{"toHost":true,"toGuest":true}`, "connect")
	var result map[string]string
	json.Unmarshal(w.Body.Bytes(), &result)
	key := result["token"]
	emit(clipboardMessage{Kind: "ready"})
	if call(`{"kind":"image-read"}`, key).Code != 409 {
		t.Fatal("image consent bypass")
	}
	b.policy.Images = true
	if call(`{"kind":"image-read"}`, key).Code != 200 {
		t.Fatal("consented image request rejected")
	}
	if call(`{"kind":"image-write","png":"bad"}`, key).Code != 400 {
		t.Fatal("invalid image accepted")
	}
	emit(clipboardMessage{Kind: "locked"})
	if b.snapshot.PNG != "" {
		t.Fatal("locked image retained")
	}
}
