//go:build windows

package main

import (
	"context"
	"testing"
)

func TestNativeDisplayEnumerationIsReadOnly(t *testing.T) {
	state, err := collectNativeDisplayAdapters(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	for _, adapter := range []displayAdapter{state.Helios, state.Basic} {
		if adapter.State == "" {
			t.Fatal("Missing native status")
		}
		if adapter.State == "running" && (adapter.InstanceID == "" || adapter.Service == "") {
			t.Fatal("Invented running adapter")
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err = collectNativeDisplayAdapters(ctx); err == nil {
		t.Fatal("Cancelled collection succeeded")
	}
}
