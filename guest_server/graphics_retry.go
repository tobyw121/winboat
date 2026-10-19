package main

import "time"

// Pending installation checks must not hash the runtime via PowerShell every
// thirty seconds indefinitely. A changed receipt immediately starts a new run.
type graphicsRetry struct {
	identity string
	next     time.Time
	attempts uint
}

func (g *graphicsRetry) ready(now time.Time, identity string) bool {
	if identity != g.identity {
		*g = graphicsRetry{identity: identity}
	}
	if now.Before(g.next) {
		return false
	}
	delay := 30 * time.Second * time.Duration(1<<min(g.attempts, 4))
	if g.attempts < 4 {
		g.attempts++
	}
	g.next = now.Add(delay)
	return true
}
