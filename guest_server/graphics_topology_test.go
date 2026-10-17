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
func TestMirrorTopologyAndRecovery(t *testing.T) {
	now := time.Unix(1000, 0)
	c := topologyController{}
	pnp := displayAdapters{Helios: displayAdapter{State: "running"}, Basic: displayAdapter{State: "running"}}
	d := topologyFixture("extend")
	actions := []string{}
	apply := func(action string) (desktopSnapshot, error) {
		actions = append(actions, action)
		if action == "clone" {
			return topologyFixture("clone"), nil
		}
		return topologyFixture("basic"), nil
	}
	step := func(offset time.Duration, bad bool) topologyStatus {
		var status topologyStatus
		d, status = c.reconcile(now.Add(offset), true, pnp, d, nil, bad, apply)
		return status
	}
	if s := step(0, false); s.State != "helios-probation" || !clonedDesktop(d) {
		t.Fatal(s, d)
	}
	if s := step(time.Second, false); s.State != "mirrored" || len(actions) != 1 {
		t.Fatal(s, actions)
	}
	// A viewer error must expose the actual VGA desktop, not merely enable PnP.
	if s := step(2*time.Second, true); s.State != "vga-fallback" || !basicDesktop(d) {
		t.Fatal(s, d)
	}
	if s := step(10*time.Second, true); s.State != "vga-fallback" || len(actions) != 2 {
		t.Fatal(s, actions)
	}
	// A renewed old failure hint must not prevent the retry restoring Helios.
	if s := step(33*time.Second, true); s.State != "helios-probation" || !clonedDesktop(d) {
		t.Fatal(s, d)
	}
	if s := step(38*time.Second, true); s.State != "helios-probation" || len(actions) != 3 {
		t.Fatal(s, actions)
	}
	if s := step(39*time.Second, false); s.State != "mirrored" {
		t.Fatal(s)
	}
	// A real PnP crash is handled immediately; recovery returns to clone.
	pnp.Helios.State = "failed"
	if s := step(40*time.Second, false); s.State != "vga-fallback" || !basicDesktop(d) {
		t.Fatal(s, d)
	}
	pnp.Helios.State = "running"
	if s := step(45*time.Second, false); s.State != "vga-fallback" {
		t.Fatal(s)
	}
	if s := step(71*time.Second, false); s.State != "helios-probation" || !clonedDesktop(d) {
		t.Fatal(s, d)
	}
}

func TestTopologyRefusalAndRetryBounds(t *testing.T) {
	now := time.Unix(1000, 0)
	c := topologyController{}
	pnp := displayAdapters{Helios: displayAdapter{State: "running"}, Basic: displayAdapter{State: "running"}}
	d := topologyFixture("extend")
	calls := []string{}
	apply := func(action string) (desktopSnapshot, error) {
		calls = append(calls, action)
		if action == "clone" {
			return d, errors.New("clone-set-display-config-50")
		}
		return topologyFixture("basic"), nil
	}
	var status topologyStatus
	d, status = c.reconcile(now, true, pnp, d, nil, false, apply)
	if status.State != "clone-unavailable" || !basicDesktop(d) || len(calls) != 2 || status.Error != "clone-set-display-config-50" {
		t.Fatal(status, d, calls)
	}
	for second := 1; second < 30; second++ {
		d, status = c.reconcile(now.Add(time.Duration(second)*time.Second), true, pnp, d, nil, false, apply)
	}
	if len(calls) != 2 {
		t.Fatal("repeated mode changes during cooldown", calls)
	}
	d, status = c.reconcile(now.Add(31*time.Second), true, pnp, d, nil, false, apply)
	if len(calls) != 3 || status.RetryAfterMS < 59000 {
		t.Fatal(status, calls)
	}
	// Even failures of VGA restoration itself must be rate-limited.
	c = topologyController{}
	d = topologyFixture("helios")
	pnp.Helios.State = "failed"
	count := 0
	fail := func(string) (desktopSnapshot, error) {
		count++
		return d, errors.New("basic-validate-display-config-87")
	}
	for second := 0; second < 30; second++ {
		_, status = c.reconcile(now.Add(time.Duration(second)*time.Second), true, pnp, d, nil, false, fail)
	}
	if count != 1 || status.State != "fallback-failed" {
		t.Fatal(status, count)
	}
}

func TestTopologySafetyAndVerification(t *testing.T) {
	pnp := displayAdapters{Helios: displayAdapter{State: "running"}, Basic: displayAdapter{State: "running"}}
	now := time.Unix(1000, 0)
	for _, tc := range []struct {
		name    string
		enabled bool
		pnp     displayAdapters
		desktop desktopSnapshot
		err     error
		want    string
	}{
		{"installation", false, pnp, topologyFixture("extend"), nil, "installation"},
		{"no-console", true, pnp, topologyFixture("extend"), errors.New("no console"), "console-unavailable"},
		{"other-monitors", true, pnp, desktopSnapshot{}, nil, "unmanaged-displays"},
		{"disabled-vga", true, displayAdapters{Helios: displayAdapter{State: "running"}, Basic: displayAdapter{State: "disabled"}}, topologyFixture("helios"), nil, "waiting-for-vga"},
		{"unknown-pnp", true, displayAdapters{Helios: displayAdapter{State: "unknown"}, Basic: displayAdapter{State: "running"}}, topologyFixture("basic"), nil, "waiting-for-helios-status"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := topologyController{}
			_, s := c.reconcile(now, tc.enabled, tc.pnp, tc.desktop, tc.err, false, func(string) (desktopSnapshot, error) {
				t.Fatal("unexpected display change")
				return desktopSnapshot{}, nil
			})
			if s.State != tc.want {
				t.Fatal(s)
			}
		})
	}
	// A successful API return alone does not prove that Windows cloned outputs.
	c := topologyController{}
	actions := []string{}
	d, s := c.reconcile(now, true, pnp, topologyFixture("extend"), nil, false, func(action string) (desktopSnapshot, error) {
		actions = append(actions, action)
		if action == "clone" {
			return topologyFixture("extend"), nil
		}
		return topologyFixture("basic"), nil
	})
	if !basicDesktop(d) || s.State != "clone-unavailable" || len(actions) != 2 {
		t.Fatal(d, s, actions)
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

func TestMirrorOnlyAfterSelectedInstallation(t *testing.T) {
	root := t.TempDir()
	install := filepath.Join(root, "WinBoat")
	data := filepath.Join(root, "ProgramData")
	os.MkdirAll(install, 0700)
	os.MkdirAll(filepath.Join(data, "Helios"), 0700)
	if mirrorEnabled(install, data) {
		t.Fatal("unselected installation changed displays")
	}
	os.WriteFile(filepath.Join(install, "helios-enabled"), nil, 0600)
	os.WriteFile(filepath.Join(data, "Helios", "install-state.json"), []byte(`{}`), 0600)
	state := filepath.Join(data, "Helios", "provisioning-status.json")
	for _, status := range []string{`{"status":"waiting"}`, `{"status":"driver-restart-required"}`, `{"status":"failed"}`, `broken`} {
		os.WriteFile(state, []byte(status), 0600)
		if mirrorEnabled(install, data) {
			t.Fatal("installation/OOBE was interrupted", status)
		}
	}
	os.WriteFile(state, []byte(`{"status":"finished"}`), 0600)
	if !mirrorEnabled(install, data) {
		t.Fatal("selected installed Helios was ignored")
	}
	os.Remove(filepath.Join(install, "helios-enabled"))
	if mirrorEnabled(install, data) {
		t.Fatal("unselected machine was modified")
	}
}
