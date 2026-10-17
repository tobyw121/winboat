package main

import "encoding/json"

type desktopProbeError string

func (e desktopProbeError) Error() string { return string(e) }

// PnP health and a Windows desktop are separate facts. A render-only adapter
// can load successfully without exposing a display to the console session.
type desktopOutput struct {
	State   string `json:"state"`
	Name    string `json:"name,omitempty"`
	Primary bool   `json:"primary"`
}
type desktopSnapshot struct {
	SessionID uint32        `json:"sessionId"`
	Helios    desktopOutput `json:"helios"`
	Basic     desktopOutput `json:"basic"`
}

func desktopRequiresFallback(desktop desktopSnapshot, probeErr error) bool {
	// A loaded but unattached Helios output cannot replace a disabled VGA.
	// A failed session query is unknown, never grounds to reconfigure Windows.
	return probeErr == nil && desktop.Helios.State == "inactive"
}

func mergeDesktopStatus(data []byte, desktop desktopSnapshot, probeErr error) ([]byte, error) {
	var status displayAdapters
	if err := json.Unmarshal(data, &status); err != nil {
		return nil, err
	}
	status.Helios.DesktopState, status.Basic.DesktopState = "unknown", "unknown"
	if probeErr != nil {
		status.DesktopError = "Windows console desktop could not be queried"
		if code, ok := probeErr.(desktopProbeError); ok {
			status.DesktopError = string(code)
		}
	} else {
		status.Desktop = &desktop
		status.Helios.DesktopState = desktop.Helios.State
		status.Basic.DesktopState = desktop.Basic.State
	}
	return json.Marshal(status)
}
