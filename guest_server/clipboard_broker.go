package main

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

const clipboardLimit = 256 * 1024

type clipboardPolicy struct {
	ToGuest bool `json:"toGuest"`
	ToHost  bool `json:"toHost"`
}
type clipboardMessage struct {
	Kind   string `json:"kind"`
	Text   string `json:"text"`
	Origin string `json:"origin,omitempty"`
}
type clipboardWorker interface {
	Send(clipboardMessage) error
	Close()
}
type clipboardSnapshot struct {
	State    string `json:"state"`
	Revision uint64 `json:"revision"`
	Text     string `json:"text"`
	Origin   string `json:"origin,omitempty"`
}
type clipboardBroker struct {
	mu       sync.Mutex
	key      string
	policy   clipboardPolicy
	worker   clipboardWorker
	last     time.Time
	snapshot clipboardSnapshot
	launch   func(clipboardPolicy, func(clipboardMessage)) (clipboardWorker, error)
}

func validClipboard(text string) bool {
	return len(text) <= clipboardLimit && utf8.ValidString(text) && !strings.ContainsRune(text, 0)
}
func (b *clipboardBroker) closeLocked() {
	if b.worker != nil {
		b.worker.Close()
	}
	b.worker = nil
	b.key = ""
	b.snapshot = clipboardSnapshot{State: "disconnected"}
}
func (b *clipboardBroker) observe(key string, message clipboardMessage) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.key != key {
		return
	}
	switch message.Kind {
	case "ready":
		b.snapshot.State = "active"
	case "locked", "closed", "denied":
		b.snapshot = clipboardSnapshot{State: message.Kind, Revision: b.snapshot.Revision + 1}
	case "text":
		if b.snapshot.State != "active" || !b.policy.ToHost || !validClipboard(message.Text) {
			return
		}
		b.snapshot.Revision++
		b.snapshot.Text = message.Text
		b.snapshot.Origin = message.Origin
	}
}
func (b *clipboardBroker) handler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	// The desktop uses Node's HTTP client. Browser-origin requests are never paired.
	if r.Header.Get("Origin") != "" {
		http.Error(w, `{"error":"Desktop client required"}`, 403)
		return
	}
	b.mu.Lock()
	if b.key != "" && time.Since(b.last) > 30*time.Second {
		b.closeLocked()
	}
	if r.Method == "POST" && r.Header.Get("X-WinBoat-Clipboard") == "connect" {
		if b.key != "" {
			b.mu.Unlock()
			http.Error(w, `{"error":"Clipboard session already exists"}`, 409)
			return
		}
		var policy clipboardPolicy
		decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024))
		decoder.DisallowUnknownFields()
		if decoder.Decode(&policy) != nil || (!policy.ToGuest && !policy.ToHost) {
			b.mu.Unlock()
			http.Error(w, `{"error":"Choose at least one direction"}`, 400)
			return
		}
		var random [32]byte
		if _, err := rand.Read(random[:]); err != nil {
			b.mu.Unlock()
			http.Error(w, `{"error":"Pairing unavailable"}`, 503)
			return
		}
		key := hex.EncodeToString(random[:])
		b.key = key
		b.last = time.Now()
		b.policy = policy
		b.snapshot = clipboardSnapshot{State: "consent-pending"}
		b.mu.Unlock()
		worker, err := b.launch(policy, func(message clipboardMessage) { b.observe(key, message) })
		b.mu.Lock()
		if err != nil || b.key != key {
			if worker != nil {
				worker.Close()
			}
			if b.key == key {
				b.closeLocked()
			}
			b.mu.Unlock()
			http.Error(w, `{"error":"Signed-in Windows session unavailable"}`, 503)
			return
		}
		b.worker = worker
		b.mu.Unlock()
		json.NewEncoder(w).Encode(map[string]string{"token": key, "state": "consent-pending"})
		return
	}
	key := r.Header.Get("X-WinBoat-Clipboard-Token")
	if b.key == "" || len(key) != 64 || subtle.ConstantTimeCompare([]byte(key), []byte(b.key)) != 1 {
		b.mu.Unlock()
		http.Error(w, `{"error":"Clipboard session required"}`, 403)
		return
	}
	b.last = time.Now()
	if r.Method == "DELETE" {
		b.closeLocked()
		b.mu.Unlock()
		json.NewEncoder(w).Encode(map[string]string{"state": "disconnected"})
		return
	}
	if r.Method == "GET" {
		value := b.snapshot
		b.mu.Unlock()
		json.NewEncoder(w).Encode(value)
		return
	}
	if r.Method != "POST" {
		b.mu.Unlock()
		http.Error(w, `{"error":"Unsupported operation"}`, 405)
		return
	}
	var value clipboardMessage
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, clipboardLimit*6+1024))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&value) != nil || !validClipboard(value.Text) || len(value.Origin) > 64 || strings.ContainsAny(value.Origin, "\r\n") {
		b.mu.Unlock()
		http.Error(w, `{"error":"Invalid plain text"}`, 400)
		return
	}
	if b.snapshot.State != "active" || b.worker == nil || (value.Kind == "write" && !b.policy.ToGuest) || (value.Kind == "read" && !b.policy.ToHost) || (value.Kind != "write" && value.Kind != "read") {
		b.mu.Unlock()
		http.Error(w, `{"error":"Clipboard direction or desktop unavailable"}`, 409)
		return
	}
	err := b.worker.Send(value)
	b.mu.Unlock()
	if err != nil {
		http.Error(w, `{"error":"Clipboard worker unavailable"}`, 503)
		return
	}
	io.WriteString(w, `{"state":"requested"}`)
}
func (b *clipboardBroker) run(done <-chan struct{}) {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-done:
			b.mu.Lock()
			b.closeLocked()
			b.mu.Unlock()
			return
		case <-ticker.C:
			b.mu.Lock()
			if b.key != "" && time.Since(b.last) > 30*time.Second {
				b.closeLocked()
			}
			b.mu.Unlock()
		}
	}
}
