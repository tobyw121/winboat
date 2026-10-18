package main

import (
	"fmt"
	"os"
	"path/filepath"
	"time"
)

func mirrorEnabled(install, programData string) bool {
	if programData == "" {
		return false
	}
	if _, err := os.Stat(filepath.Join(install, "helios-enabled")); err != nil {
		return false
	}
	if _, err := os.Stat(filepath.Join(programData, "Helios", "install-state.json")); err != nil {
		return false
	}
	state, err := readHeliosJSON(filepath.Join(programData, "Helios", "provisioning-status.json"))
	return err == nil && state["status"] == "finished"
}

func heliosRestartPending(install, programData string) bool {
	if programData == "" {
		return false
	}
	if _, err := os.Stat(filepath.Join(install, "helios-enabled")); err != nil {
		return false
	}
	state, err := readHeliosJSON(filepath.Join(programData, "Helios", "provisioning-status.json"))
	return err == nil && state["status"] == "driver-restart-required"
}

// One serial monitor owns this controller. No HTTP handler changes displays.
// During a viewer failure, periodically retry cloning even if an old failure
// hint is renewed: an inactive Helios cannot produce the frame clearing it.
type topologyController struct {
	retryAt        time.Time
	probationUntil time.Time
	attempts       uint
	lastError      string
	basicRetryAt   time.Time
	viewerBadSeen  bool
	driverFailed   bool
}
type topologyStatus struct {
	Goal         string `json:"goal"`
	State        string `json:"state"`
	Error        string `json:"error,omitempty"`
	RetryAfterMS int64  `json:"retryAfterMs,omitempty"`
}

func (c *topologyController) backoff(now time.Time) {
	delay := 30 * time.Second
	for i := uint(0); i < c.attempts && delay < 5*time.Minute; i++ {
		delay *= 2
	}
	if delay > 5*time.Minute {
		delay = 5 * time.Minute
	}
	if c.attempts < 4 {
		c.attempts++
	}
	c.retryAt = now.Add(delay)
	c.probationUntil = time.Time{}
}
func basicDesktop(d desktopSnapshot) bool {
	return d.Topology == "basic" && d.Basic.State == "active" && d.Helios.State != "active"
}
func clonedDesktop(d desktopSnapshot) bool {
	return d.Topology == "clone" && d.Basic.State == "active" && d.Helios.State == "active"
}
func (c *topologyController) reconcile(now time.Time, enabled bool, pnp displayAdapters, d desktopSnapshot, probeErr error, viewerBad bool,
	apply func(string) (desktopSnapshot, error)) (desktopSnapshot, topologyStatus) {
	result := topologyStatus{Goal: "mirror-helios-preferred", State: "waiting"}
	finish := func(state string) (desktopSnapshot, topologyStatus) {
		result.State = state
		result.Error = c.lastError
		if c.retryAt.After(now) {
			result.RetryAfterMS = c.retryAt.Sub(now).Milliseconds()
		}
		return d, result
	}
	if !enabled {
		result.Goal = "installation-vga"
		return finish("installation")
	}
	if probeErr != nil {
		return finish("console-unavailable")
	}
	if !d.Managed {
		return finish("unmanaged-displays")
	}
	if pnp.Basic.State != "running" {
		return finish("waiting-for-vga")
	}
	fallback := func(reason string) (desktopSnapshot, topologyStatus) {
		if !basicDesktop(d) {
			if now.Before(c.basicRetryAt) {
				return finish("fallback-failed")
			}
			next, err := apply("basic")
			d = next
			if err != nil || !basicDesktop(d) {
				c.lastError = "basic-desktop-not-confirmed"
				if err != nil {
					c.lastError = err.Error()
				}
				c.backoff(now)
				c.basicRetryAt = now.Add(30 * time.Second)
				return finish("fallback-failed")
			}
			c.basicRetryAt = time.Time{}
		}
		return finish(reason)
	}
	// Unknown WMI status is not a driver failure and cannot initiate a layout
	// change. An explicit viewer failure is independent evidence for fallback.
	if pnp.Helios.State == "unknown" && !viewerBad {
		return finish("waiting-for-helios-status")
	}
	if !viewerBad {
		c.viewerBadSeen = false
	}
	if pnp.Helios.State != "running" {
		if !c.driverFailed {
			c.backoff(now)
		}
		c.driverFailed = true
		return fallback("vga-fallback")
	}
	c.driverFailed = false
	if viewerBad && !c.viewerBadSeen {
		c.viewerBadSeen = true
		c.backoff(now)
		return fallback("vga-fallback")
	}
	// Successful imports may clear the hint during probation. Do not renew the
	// fallback cooldown on every polling tick or Helios could never return.
	if clonedDesktop(d) && !viewerBad {
		c.retryAt = time.Time{}
		c.probationUntil = time.Time{}
		c.attempts = 0
		c.lastError = ""
		return finish("mirrored")
	}
	if viewerBad && clonedDesktop(d) {
		if now.Before(c.probationUntil) {
			return finish("helios-probation")
		}
		c.backoff(now)
		return fallback("vga-fallback")
	}
	if now.Before(c.retryAt) {
		// No repeated SetDisplayConfig calls while the fallback is already active.
		return fallback("vga-fallback")
	}
	next, err := apply("clone")
	d = next
	if err != nil || !clonedDesktop(d) {
		c.lastError = "clone-not-confirmed"
		if err != nil {
			c.lastError = err.Error()
		}
		c.backoff(now)
		return fallback("clone-unavailable")
	}
	c.lastError = ""
	c.retryAt = time.Time{}
	c.probationUntil = now.Add(12 * time.Second)
	return finish("helios-probation")
}

// Windows CCD structures. Keep their ABI independent of Go's pointer width.
type ccdLUID struct {
	Low  uint32
	High int32
}
type ccdSource struct {
	Adapter          ccdLUID
	ID, Mode, Status uint32
}
type ccdTarget struct {
	Adapter                                                           ccdLUID
	ID, Mode, Technology, Rotation, Scaling                           uint32
	RefreshNumerator, RefreshDenominator, Scanline, Available, Status uint32
}
type ccdPath struct {
	Source ccdSource
	Target ccdTarget
	Flags  uint32
}
type ccdMode struct {
	Kind, ID uint32
	Adapter  ccdLUID
	Data     [6]uint64
}
type ccdAdapterName struct {
	Kind, Size uint32
	Adapter    ccdLUID
	ID         uint32
	Path       [128]uint16
}
type ccdSourceName struct {
	Kind, Size uint32
	Adapter    ccdLUID
	ID         uint32
	Name       [32]uint16
}
type ccdRoute struct {
	Path                   ccdPath
	TargetRole, SourceRole string
}

func sameDesktopSources(a, b ccdPath, modes []ccdMode) bool {
	if a.Source.Adapter == b.Source.Adapter && a.Source.ID == b.Source.ID {
		return true
	}
	geometry := func(path ccdPath) ([4]uint32, bool) {
		index := path.Source.Mode
		if path.Flags&8 != 0 {
			index >>= 16
			if index == 0xffff {
				return [4]uint32{}, false
			}
		}
		if uint64(index) >= uint64(len(modes)) {
			return [4]uint32{}, false
		}
		mode := modes[index]
		if mode.Kind != 1 || mode.Adapter != path.Source.Adapter || mode.ID != path.Source.ID {
			return [4]uint32{}, false
		}
		// DISPLAYCONFIG_SOURCE_MODE: width, height, pixelFormat, position.x/y.
		value := [4]uint32{uint32(mode.Data[0]), uint32(mode.Data[0] >> 32), uint32(mode.Data[1] >> 32), uint32(mode.Data[2])}
		return value, value[0] > 0 && value[1] > 0
	}
	one, ok := geometry(a)
	two, otherOK := geometry(b)
	return ok && otherOK && one == two
}

// Refuse global topology changes when another GPU/output is involved. Clone
// may span the two virtual adapters; Basic-only must not depend on Helios's
// source, because that source can be stopped or crashed.
func managedRoutes(routes []ccdRoute) (managed, cloneAvailable bool) {
	targets := map[struct {
		Adapter ccdLUID
		ID      uint32
	}]string{}
	for _, route := range routes {
		if route.Path.Target.Available == 0 && route.Path.Flags&1 == 0 {
			continue
		}
		if route.TargetRole != "basic" && route.TargetRole != "helios" {
			return false, false
		}
		if route.SourceRole != "basic" && route.SourceRole != "helios" {
			return false, false
		}
		targets[struct {
			Adapter ccdLUID
			ID      uint32
		}{route.Path.Target.Adapter, route.Path.Target.ID}] = route.TargetRole
	}
	basic, helios := 0, 0
	for _, role := range targets {
		if role == "basic" {
			basic++
		} else {
			helios++
		}
	}
	return basic == 1 && helios <= 1, basic == 1 && helios == 1
}
func basicRoute(routes []ccdRoute) (ccdPath, error) {
	var chosen *ccdPath
	for _, route := range routes {
		if route.TargetRole != "basic" || route.SourceRole != "basic" || route.Path.Target.Available == 0 {
			continue
		}
		if chosen == nil || route.Path.Flags&1 != 0 {
			copy := route.Path
			chosen = &copy
		}
	}
	if chosen == nil {
		return ccdPath{}, fmt.Errorf("basic-display-target-unavailable")
	}
	chosen.Source.Mode = 0xffffffff
	chosen.Target.Mode = 0xffffffff
	if chosen.Target.Rotation < 1 || chosen.Target.Rotation > 4 {
		chosen.Target.Rotation = 1
	}
	if chosen.Target.Scaling < 1 || (chosen.Target.Scaling > 5 && chosen.Target.Scaling != 128) {
		chosen.Target.Scaling = 1
	}
	chosen.Flags = 1 // legacy mode indices, not packed virtual-mode indices
	return *chosen, nil
}
