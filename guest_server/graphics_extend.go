package main

import "fmt"

// DEVMODEW: the display union is explicit; never pass printer layout to user32.
type displayMode struct {
	DeviceName                                                                                     [32]uint16
	SpecVersion, DriverVersion, Size, DriverExtra                                                  uint16
	Fields                                                                                         uint32
	X, Y                                                                                           int32
	Orientation, FixedOutput                                                                       uint32
	Color, Duplex, YResolution, TTOption, Collate                                                  int16
	FormName                                                                                       [32]uint16
	LogPixels                                                                                      uint16
	BitsPerPel, Width, Height, DisplayFlags, Frequency                                             uint32
	ICMMethod, ICMIntent, MediaType, DitherType, Reserved1, Reserved2, PanningWidth, PanningHeight uint32
}

func extendedHeliosMode(helios, basic displayMode) (displayMode, error) {
	x := int64(basic.X) + int64(basic.Width)
	if helios.Width == 0 || helios.Height == 0 || basic.Width == 0 || basic.Height == 0 || x > 2147483647 {
		return displayMode{}, fmt.Errorf("invalid-extended-display-geometry")
	}
	helios.X, helios.Y = int32(x), basic.Y
	helios.Fields |= 0x20 | 0x80000 | 0x100000 // POSITION | PELSWIDTH | PELSHEIGHT
	return helios, nil
}
func sameDisplayMode(a, b displayMode) bool {
	return a.X == b.X && a.Y == b.Y && a.Width == b.Width && a.Height == b.Height &&
		a.BitsPerPel == b.BitsPerPel && a.Frequency == b.Frequency && a.Orientation == b.Orientation
}
func extendedDesktop(d desktopSnapshot) bool {
	return d.Topology == "extend" && d.Basic.State == "active" && d.Helios.State == "active"
}
