package main

import (
	"fmt"
	"os"
	"path/filepath"
	"time"
)

func extendedDesktopEnabled(install, programData string) bool {
	if programData == "" {
		return false
	}
	if !heliosSelected(install, programData) {
		return false
	}
	if _, err := os.Stat(filepath.Join(programData, "Helios", "install-state.json")); err != nil {
		return false
	}
	state, err := readHeliosJSON(filepath.Join(programData, "Helios", "provisioning-status.json"))
	return err == nil && state["status"] == "finished"
}

func heliosSelected(install, programData string) bool {
	if _, err := os.Stat(filepath.Join(install, "helios-enabled")); err == nil {
		return true
	}
	if programData == "" {
		return false
	}
	// This receipt is only staged by an explicitly selected WinBoat installer.
	// Legacy guest updates removed the OEM marker from Program Files.
	receipt, err := readHeliosJSON(filepath.Join(programData, "WinBoat", "Helios", "helios-build.json"))
	if err != nil {
		return false
	}
	revision, ok := receipt["revision"].(string)
	return ok && revision == "fecffde64fd32399a877b452332681ef0db7993e"
}

func heliosRestartPending(install, programData string) bool {
	if programData == "" {
		return false
	}
	if !heliosSelected(install, programData) {
		return false
	}
	state, err := readHeliosJSON(filepath.Join(programData, "Helios", "provisioning-status.json"))
	return err == nil && state["status"] == "driver-restart-required"
}

// The serial monitor makes at most one automatic Helios-only change per
// console session. A viewer/driver failure must never trigger VGA mode cycling.
type topologyController struct {
	sessionID uint32
	attempted bool
	lastError string
}
type topologyStatus struct {
	Goal          string `json:"goal"`
	State         string `json:"state"`
	Error         string `json:"error,omitempty"`
	RetryAfterMS  int64  `json:"retryAfterMs,omitempty"`
	VGAProtection string `json:"vgaProtection"`
}

func basicDesktop(d desktopSnapshot) bool {
	return d.Topology == "basic" && d.Basic.State == "active" && d.Helios.State != "active"
}
func clonedDesktop(d desktopSnapshot) bool {
	return d.Topology == "clone" && d.Basic.State == "active" && d.Helios.State == "active"
}
func (c *topologyController) reconcile(_ time.Time, enabled bool, pnp displayAdapters, d desktopSnapshot, probeErr error, viewerBad bool,
	apply func(string) (desktopSnapshot, error)) (desktopSnapshot, topologyStatus) {
	result := topologyStatus{Goal: "extend-preserve-vga", VGAProtection: "no-automatic-vga-or-primary-changes"}
	finish := func(state string) (desktopSnapshot, topologyStatus) {
		result.State, result.Error = state, c.lastError
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
	if c.sessionID != d.SessionID {
		c.sessionID = d.SessionID
		c.attempted = false
		c.lastError = ""
	}
	if pnp.Basic.State != "running" || d.Basic.State != "active" {
		return finish("vga-unavailable")
	}
	if pnp.Helios.State != "running" {
		return finish("helios-" + pnp.Helios.State)
	}
	if extendedDesktop(d) {
		c.attempted = true
		c.lastError = ""
		if viewerBad {
			return finish("extended-viewer-unavailable")
		}
		return finish("extended")
	}
	if !d.Basic.Primary {
		return finish("primary-layout-held")
	}
	if c.attempted {
		return finish("extension-held")
	}
	c.attempted = true
	before := d.Basic
	next, err := apply("extend")
	d = next
	if err != nil || !extendedDesktop(d) || d.Basic.Primary != before.Primary {
		c.lastError = "extended-desktop-not-confirmed"
		if err != nil {
			c.lastError = err.Error()
		}
		return finish("extension-failed")
	}
	return finish("extended")
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
