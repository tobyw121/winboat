package main

import (
	"context"
	"encoding/json"
	"net/http"
	"sync"
	"time"
)

var graphicsRescueMutex sync.Mutex

func graphicsRescueHandler(run func(context.Context, string) ([]byte, error)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		action := r.Header.Get("X-WinBoat-Recovery")
		if action != "helios-disable" && action != "helios-enable" {
			http.Error(w, `{"error":"Explicit Helios rescue operation required"}`, 400)
			return
		}
		if !graphicsRescueMutex.TryLock() {
			http.Error(w, `{"error":"Graphics rescue already active"}`, 409)
			return
		}
		defer graphicsRescueMutex.Unlock()
		ctx, cancel := context.WithTimeout(r.Context(), 55*time.Second)
		defer cancel()
		data, err := run(ctx, action)
		var result struct {
			Status string `json:"status"`
		}
		if err != nil || len(data) > 8192 || json.Unmarshal(data, &result) != nil {
			http.Error(w, `{"error":"Fixed graphics rescue operation unavailable"}`, 503)
			return
		}
		code := 200
		switch result.Status {
		case "disabled", "enabled":
		case "restart-required":
			code = 202
		case "blocked":
			code = 409
		case "failed":
			code = 500
		default:
			http.Error(w, `{"error":"Unexpected rescue result"}`, 503)
			return
		}
		w.WriteHeader(code)
		w.Write(data)
	}
}
