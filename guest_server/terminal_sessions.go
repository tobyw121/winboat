package main

type terminalSession struct {
	ID    uint32
	State uint32
}

// WTSActive is 0; protocol 0 is console, 2 is RDP. No localized text parsing.
func hasActiveRDP(sessions []terminalSession, protocol func(uint32) (uint16, error)) (bool, error) {
	for _, session := range sessions {
		if session.State != 0 {
			continue
		}
		p, err := protocol(session.ID)
		if err != nil {
			return false, err
		}
		if p == 2 {
			return true, nil
		}
	}
	return false, nil
}
