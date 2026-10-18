//! Allocation-free virtual display mode policy shared by VidPn and scanout.
//! Preferred is the immutable boot/EDID mode; active is published by CommitVidPn.
pub const PRESETS: &[(u32, u32)] = &[
    (1024,768), (1280,720), (1280,800), (1366,768), (1440,900),
    (1600,900), (1920,1080), (1920,1200), (2560,1440), (2560,1600), (3840,2160),
];

/// Keep the preferred mode first and unique, including valid custom host modes.
pub fn modes(preferred: (u32,u32)) -> impl Iterator<Item=(u32,u32)> {
    core::iter::once(preferred).chain(PRESETS.iter().copied().filter(move |m| *m != preferred))
}

pub fn supported(preferred: (u32,u32), mode: (u32,u32)) -> bool {
    modes(preferred).any(|candidate| candidate == mode)
}

/// Identity/centered paths have no resampler. A pin on either end restricts the
/// opposite end to the same dimensions; never advertise incompatible pairs.
pub fn cofunctional(candidate: (u32,u32), opposite: Option<(u32,u32)>) -> bool {
    opposite.is_none_or(|mode| candidate == mode)
}

pub const fn pack(mode: (u32,u32)) -> u64 {
    ((mode.0 as u64) << 32) | mode.1 as u64
}

#[cfg(test)]
mod tests {
    extern crate std;
    use super::*;
    #[test]
    fn preferred_first_without_duplicate_and_all_sizes_safe() {
        for preferred in PRESETS.iter().copied().chain([(1680,1050)]) {
            let mut iter = modes(preferred);
            assert_eq!(iter.next(), Some(preferred));
            assert_eq!(iter.filter(|m| *m == preferred).count(), 0);
            assert_eq!(modes(preferred).count(), PRESETS.len() + usize::from(!PRESETS.contains(&preferred)));
            for (w,h) in modes(preferred) {
                assert!(super::super::edid::build_edid(w,h,"Helios","WinBoat",2026).is_some());
                assert!(u64::from(w)*u64::from(h)*4 <= 64*1024*1024);
            }
        }
    }
    #[test]
    fn pins_restrict_both_directions_and_invalid_modes_refused() {
        let preferred=(1280,800);
        for pin in PRESETS.iter().copied() {
            assert_eq!(modes(preferred).filter(|m| cofunctional(*m,Some(pin))).collect::<std::vec::Vec<_>>(), [pin]);
            assert!(supported(preferred,pin));
        }
        assert_eq!(modes(preferred).filter(|m| cofunctional(*m,None)).count(), PRESETS.len());
        assert!(!supported(preferred,(0,0)));
        assert!(!supported(preferred,(u32::MAX,u32::MAX)));
        assert_eq!(pack((3840,2160)), 0x00000f0000000870);
    }
}
