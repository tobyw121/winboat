package main

import "time"

// Opt-in containment only; never re-enable a GPU or change VGA/primary modes.
// Unknown samples reset the count. A suspend gap cannot count as consecutive.
type graphicsBreaker struct {
	consecutive int
	last        time.Time
	session     uint32
	attempted   bool
}

func (b *graphicsBreaker) observe(now time.Time, enabled bool, p displayAdapters, d desktopSnapshot, probeErr error) bool {
	safe := enabled && probeErr == nil && d.SessionID != 0 && d.Managed &&
		p.Basic.State == "running" && d.Basic.State == "active" && d.Basic.Primary
	failed := p.Helios.State == "failed"
	if !safe || !failed || b.session != d.SessionID || now.Sub(b.last) > 30*time.Second {
		b.consecutive = 0
	}
	b.session = d.SessionID
	if !safe || !failed || b.attempted {
		return false
	}
	if !b.last.IsZero() && now.Sub(b.last) < 5*time.Second {
		return false
	}
	b.last = now
	b.consecutive++
	if b.consecutive < 3 {
		return false
	}
	b.attempted = true
	return true
}

// Event-log failure or unknown desktop state never authorizes a mutation.
func (b *graphicsBreaker) crashBurst(enabled bool, count int, p displayAdapters, d desktopSnapshot, probeErr error) bool {
	if b.attempted || !enabled || count < 3 || probeErr != nil || d.SessionID == 0 || !d.Managed ||
		p.Helios.State != "running" || p.Basic.State != "running" || d.Basic.State != "active" || !d.Basic.Primary {
		return false
	}
	b.attempted = true
	return true
}
