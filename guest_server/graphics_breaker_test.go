package main

import (
	"testing"
	"time"
)

func TestBreakerRequiresRepeatedConfirmedFailureAndNeverLoops(t *testing.T) {
	now := time.Now()
	p := displayAdapters{Basic: displayAdapter{State: "running"}, Helios: displayAdapter{State: "failed"}}
	d := desktopSnapshot{SessionID: 1, Managed: true, Basic: desktopOutput{State: "active", Primary: true}}
	var b graphicsBreaker
	if b.observe(now, true, p, d, nil) || b.observe(now.Add(5*time.Second), true, p, d, nil) {
		t.Fatal("premature isolation")
	}
	if !b.observe(now.Add(10*time.Second), true, p, d, nil) {
		t.Fatal("confirmed failure not contained")
	}
	if b.observe(now.Add(60*time.Second), true, p, d, nil) {
		t.Fatal("repeated mutation")
	}
	for _, state := range []string{"running", "unknown", "missing", "disabled"} {
		b = graphicsBreaker{}
		p.Helios.State = state
		for i := 0; i < 4; i++ {
			if b.observe(now.Add(time.Duration(i)*5*time.Second), true, p, d, nil) {
				t.Fatal(state)
			}
		}
	}
	p.Helios.State = "failed"
	b = graphicsBreaker{}
	b.observe(now, true, p, d, nil)
	b.observe(now.Add(5*time.Second), true, p, d, nil)
	if b.observe(now.Add(time.Minute), true, p, d, nil) {
		t.Fatal("suspend gap counted")
	}
	d.Basic.Primary = false
	for i := 0; i < 4; i++ {
		if b.observe(now.Add(time.Duration(i+20)*5*time.Second), true, p, d, nil) {
			t.Fatal("VGA not primary")
		}
	}
}
