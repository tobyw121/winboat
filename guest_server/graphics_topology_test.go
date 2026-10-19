package main

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func topologyFixture(mode string) desktopSnapshot {
	d := desktopSnapshot{SessionID: 1, Managed: true, CloneAvailable: true, Topology: mode, Helios: desktopOutput{State: "active"}, Basic: desktopOutput{State: "active", Primary: true}}
	if mode == "basic" {
		d.Helios.State = "inactive"
	}
	if mode == "helios" {
		d.Basic.State = "inactive"
	}
	return d
}
func TestExtendedDesktopDoesNotCycleVGA(t *testing.T) {
	pnp := displayAdapters{Helios: displayAdapter{State: "running"}, Basic: displayAdapter{State: "running"}}
	now := time.Unix(1000, 0)
	for _, mode := range []string{"basic", "clone"} {
		c := topologyController{}
		calls := 0
		d, s := c.reconcile(now, true, pnp, topologyFixture(mode), nil, false, func(action string) (desktopSnapshot, error) {
			calls++
			if action != "extend" {
				t.Fatal("VGA/global change", action)
			}
			return topologyFixture("extend"), nil
		})
		if !extendedDesktop(d) || s.State != "extended" || calls != 1 {
			t.Fatal(d, s, calls)
		}
		// A viewer failure does not replace the extended desktop with VGA/clone.
		for i := 0; i < 20; i++ {
			d, s = c.reconcile(now, true, pnp, d, nil, true, func(string) (desktopSnapshot, error) { t.Fatal("mode cycling"); return d, nil })
		}
		if s.State != "extended-viewer-unavailable" {
			t.Fatal(s)
		}
		pnp.Helios.State = "failed"
		_, s = c.reconcile(now, true, pnp, d, nil, true, func(string) (desktopSnapshot, error) { t.Fatal("VGA recovery"); return d, nil })
		if s.State != "helios-failed" {
			t.Fatal(s)
		}
		pnp.Helios.State = "running"
	}
}
func TestExtensionFailureIsHeldAndPrimaryIsPreserved(t *testing.T) {
	pnp := displayAdapters{Helios: displayAdapter{State: "running"}, Basic: displayAdapter{State: "running"}}
	for _, fail := range []bool{false, true} {
		c := topologyController{}
		calls := 0
		apply := func(string) (desktopSnapshot, error) {
			calls++
			if fail {
				return topologyFixture("basic"), errors.New("extension-error")
			}
			d := topologyFixture("extend")
			d.Basic.Primary = false
			return d, nil
		}
		for i := 0; i < 100; i++ {
			c.reconcile(time.Unix(int64(i), 0), true, pnp, topologyFixture("basic"), nil, false, apply)
		}
		if calls != 1 {
			t.Fatal("automatic extension repeated", calls)
		}
		next := topologyFixture("basic")
		next.SessionID = 2
		c.reconcile(time.Now(), true, pnp, next, nil, false, apply)
		if calls != 2 {
			t.Fatal("new console session not handled")
		}
	}
}
func TestExtensionRefusesUnknownOrUnavailableVGA(t *testing.T) {
	pnp := displayAdapters{Helios: displayAdapter{State: "running"}, Basic: displayAdapter{State: "running"}}
	for _, mode := range []string{"basic", "helios"} {
		for _, state := range []string{"disabled", "missing", "failed", "unknown"} {
			pnp.Basic.State = state
			c := topologyController{}
			_, s := c.reconcile(time.Now(), true, pnp, topologyFixture(mode), nil, true, func(string) (desktopSnapshot, error) { t.Fatal("VGA changed"); return desktopSnapshot{}, nil })
			if s.State != "vga-unavailable" {
				t.Fatal(s)
			}
		}
	}
	pnp.Basic.State = "running"
	for _, enabled := range []bool{false, true} {
		c := topologyController{}
		_, s := c.reconcile(time.Now(), enabled, pnp, topologyFixture("basic"), errors.New("session unavailable"), false, func(string) (desktopSnapshot, error) {
			t.Fatal("unknown session changed")
			return desktopSnapshot{}, nil
		})
		if enabled && s.State != "console-unavailable" {
			t.Fatal(s)
		}
	}
}

func TestManagedCCDTargets(t *testing.T) {
	basic := ccdRoute{Path: ccdPath{Source: ccdSource{Adapter: ccdLUID{Low: 1}}, Target: ccdTarget{Adapter: ccdLUID{Low: 1}, Available: 1}, Flags: 1}, TargetRole: "basic", SourceRole: "basic"}
	helios := ccdRoute{Path: ccdPath{Source: ccdSource{Adapter: ccdLUID{Low: 2}}, Target: ccdTarget{Adapter: ccdLUID{Low: 2}, Available: 1}}, TargetRole: "helios", SourceRole: "helios"}
	if managed, clone := managedRoutes([]ccdRoute{basic, helios, basic}); !managed || !clone {
		t.Fatal("duplicate source/target routes counted as extra monitors")
	}
	foreign := helios
	foreign.Path.Target.ID = 9
	foreign.TargetRole = "other"
	if managed, _ := managedRoutes([]ccdRoute{basic, helios, foreign}); managed {
		t.Fatal("unrelated monitor accepted")
	}
	if managed, clone := managedRoutes([]ccdRoute{basic}); !managed || clone {
		t.Fatal("VGA-only recovery incorrectly needs Helios")
	}
	cross := basic
	cross.SourceRole = "helios"
	if _, err := basicRoute([]ccdRoute{cross}); err == nil {
		t.Fatal("VGA fallback depended on a Helios source")
	}
	path, err := basicRoute([]ccdRoute{cross, basic})
	if err != nil || path.Source.Adapter.Low != 1 || path.Source.Mode != 0xffffffff || path.Target.Mode != 0xffffffff || path.Flags != 1 || path.Target.Rotation != 1 {
		t.Fatal(path, err)
	}
}

func TestActualCloneGeometry(t *testing.T) {
	a := ccdPath{Source: ccdSource{Adapter: ccdLUID{Low: 1}, ID: 0, Mode: 0}, Flags: 1}
	b := ccdPath{Source: ccdSource{Adapter: ccdLUID{Low: 2}, ID: 0, Mode: 1}, Flags: 1}
	modes := []ccdMode{
		{Kind: 1, ID: 0, Adapter: a.Source.Adapter, Data: [6]uint64{uint64(800)<<32 | 1280, 4, 0}},
		{Kind: 1, ID: 0, Adapter: b.Source.Adapter, Data: [6]uint64{uint64(800)<<32 | 1280, 4, 0}},
	}
	if !sameDesktopSources(a, b, modes) {
		t.Fatal("same desktop rectangle was not recognized")
	}
	modes[1].Data[1] = uint64(1280)<<32 | 4
	if sameDesktopSources(a, b, modes) {
		t.Fatal("extended desktop was mistaken for mirroring")
	}
	modes[1].Data[1] = 4
	a.Flags = 9
	b.Flags = 9
	a.Source.Mode = 0x0000ffff
	b.Source.Mode = 0x0001ffff
	if !sameDesktopSources(a, b, modes) {
		t.Fatal("virtual-aware packed source mode indices were not decoded")
	}
	b.Source.Mode = 0xffff0000
	if sameDesktopSources(a, b, modes) {
		t.Fatal("invalid virtual source mode was accepted")
	}
	b.Source = a.Source
	if !sameDesktopSources(a, b, nil) {
		t.Fatal("shared Windows source must be a clone")
	}
}

func TestExtensionOnlyAfterSelectedInstallation(t *testing.T) {
	root := t.TempDir()
	install := filepath.Join(root, "WinBoat")
	data := filepath.Join(root, "ProgramData")
	os.MkdirAll(install, 0700)
	os.MkdirAll(filepath.Join(data, "Helios"), 0700)
	if extendedDesktopEnabled(install, data) {
		t.Fatal("unselected installation changed displays")
	}
	os.WriteFile(filepath.Join(install, "helios-enabled"), nil, 0600)
	os.WriteFile(filepath.Join(data, "Helios", "install-state.json"), []byte(`{}`), 0600)
	state := filepath.Join(data, "Helios", "provisioning-status.json")
	for _, status := range []string{`{"status":"waiting"}`, `{"status":"driver-restart-required"}`, `{"status":"failed"}`, `broken`} {
		os.WriteFile(state, []byte(status), 0600)
		if heliosRestartPending(install, data) != (status == `{"status":"driver-restart-required"}`) {
			t.Fatal("restart verification must only inspect a selected pending restart", status)
		}
		if extendedDesktopEnabled(install, data) {
			t.Fatal("installation/OOBE was interrupted", status)
		}
	}
	os.WriteFile(state, []byte(`{"status":"finished"}`), 0600)
	if !extendedDesktopEnabled(install, data) {
		t.Fatal("selected installed Helios was ignored")
	}
	if heliosRestartPending(install, data) {
		t.Fatal("finished driver kept rechecking restart completion")
	}
	// An already extended desktop must survive provisioning and cold boot.
	for _, boot := range []int64{1000, 2000} {
		controller := topologyController{}
		pnp := displayAdapters{Helios: displayAdapter{State: "running"}, Basic: displayAdapter{State: "running"}}
		desktop, policy := controller.reconcile(time.Unix(boot, 0), extendedDesktopEnabled(install, data), pnp, topologyFixture("extend"), nil, false,
			func(string) (desktopSnapshot, error) {
				t.Fatal("extended desktop changed")
				return desktopSnapshot{}, nil
			})
		if !extendedDesktop(desktop) || policy.Goal != "extend-preserve-vga" {
			t.Fatal(desktop, policy)
		}
	}
	os.Remove(filepath.Join(install, "helios-enabled"))
	receiptDir := filepath.Join(data, "WinBoat", "Helios")
	os.MkdirAll(receiptDir, 0700)
	receipt := filepath.Join(receiptDir, "helios-build.json")
	os.WriteFile(receipt, []byte(`{"revision":"fecffde64fd32399a877b452332681ef0db7993e"}`), 0600)
	if !extendedDesktopEnabled(install, data) {
		t.Fatal("guest update erased the selected Helios policy")
	}
	os.WriteFile(state, []byte(`{"status":"driver-restart-required"}`), 0600)
	if !heliosRestartPending(install, data) {
		t.Fatal("lost OEM marker suppressed restart verification")
	}
	os.WriteFile(state, []byte(`{"status":"finished"}`), 0600)
	os.WriteFile(receipt, []byte(`{"revision":"unrelated"}`), 0600)
	if heliosSelected(install, data) {
		t.Fatal("unrelated receipt selected Helios")
	}
	os.Remove(receipt)
	if extendedDesktopEnabled(install, data) {
		t.Fatal("unselected machine was modified")
	}
	if heliosRestartPending(install, data) {
		t.Fatal("unselected machine requested restart verification")
	}
}
