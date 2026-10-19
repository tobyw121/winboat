package main

import (
	"testing"
	"time"
	"unsafe"
)

func TestHeliosExtensionPreservesVGAAndModeABI(t *testing.T) {
	if unsafe.Sizeof(displayMode{}) != 220 || unsafe.Offsetof(displayMode{}.X) != 76 || unsafe.Offsetof(displayMode{}.Width) != 172 {
		t.Fatal("DEVMODEW ABI mismatch")
	}
	basic := displayMode{X: -1920, Y: 80, Width: 1920, Height: 1080, Frequency: 60, BitsPerPel: 32}
	before := basic
	helios := displayMode{Width: 1280, Height: 800, Frequency: 75, BitsPerPel: 32}
	next, err := extendedHeliosMode(helios, basic)
	if err != nil || basic != before || next.X != 0 || next.Y != 80 || next.Width != 1280 || next.Frequency != 75 {
		t.Fatal(next, basic, err)
	}
	changed := basic
	changed.Frequency = 59
	if sameDisplayMode(basic, changed) {
		t.Fatal("VGA change missed")
	}
	basic.X, basic.Width = 2147483647, 1
	if _, err := extendedHeliosMode(helios, basic); err == nil {
		t.Fatal("position overflow accepted")
	}
}

func TestPrimaryHeliosCloneIsNotMovedAutomatically(t *testing.T) {
	c := topologyController{}
	d := topologyFixture("clone")
	d.Basic.Primary = false
	d.Helios.Primary = true
	pnp := displayAdapters{Helios: displayAdapter{State: "running"}, Basic: displayAdapter{State: "running"}}
	_, s := c.reconcile(time.Now(), true, pnp, d, nil, false, func(string) (desktopSnapshot, error) { t.Fatal("primary layout changed"); return d, nil })
	if s.State != "primary-layout-held" {
		t.Fatal(s)
	}
}
