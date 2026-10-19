package main

import (
	"testing"
	"time"
)

func TestGraphicsRetryBackoffAndReceiptChange(t *testing.T) {
	var retry graphicsRetry
	now := time.Unix(0, 0)
	for _, delay := range []time.Duration{30, 60, 120, 240, 480, 480} {
		if !retry.ready(now, "receipt-a") || retry.ready(now.Add(time.Second), "receipt-a") {
			t.Fatal("duplicate or missing attempt")
		}
		if retry.ready(now.Add(delay*time.Second-time.Nanosecond), "receipt-a") {
			t.Fatal("early retry")
		}
		now = now.Add(delay * time.Second)
	}
	if !retry.ready(now.Add(-time.Second), "receipt-b") {
		t.Fatal("changed receipt was held by old cooldown")
	}
}
