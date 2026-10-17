package main

import (
	"errors"
	"testing"
)

func TestActiveRDP(t *testing.T) {
	for _, tt := range []struct {
		name     string
		sessions []terminalSession
		want     bool
	}{
		{"empty", nil, false},
		{"console", []terminalSession{{ID: 1, State: 0}}, false},
		{"disconnected RDP", []terminalSession{{ID: 2, State: 4}}, false},
		{"console and active RDP", []terminalSession{{ID: 1, State: 0}, {ID: 2, State: 0}}, true},
	} {
		t.Run(tt.name, func(t *testing.T) {
			got, err := hasActiveRDP(tt.sessions, func(id uint32) (uint16, error) {
				if id == 2 {
					return 2, nil
				}
				return 0, nil
			})
			if err != nil || got != tt.want {
				t.Fatalf("got %v %v", got, err)
			}
		})
	}
	_, err := hasActiveRDP([]terminalSession{{ID: 1, State: 0}}, func(uint32) (uint16, error) { return 0, errors.New("session ended") })
	if err == nil {
		t.Fatal("query failure must not be reported as disconnected")
	}
}
