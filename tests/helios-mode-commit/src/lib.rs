// Tests execute the unmodified production CommitVidPn body. The Windows VidPn
// objects/callbacks are fixtures: native ABI, cofunc negotiation and GPU scanout
// are separate gates, not established by this harness.
#![allow(non_snake_case, non_camel_case_types, dead_code)]
use helios_kmd_logic::display_modes;
use std::ptr::{null, null_mut};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
type NTSTATUS = i32;
type SIZE_T = usize;
type D3DKMDT_HVIDPN = *mut State;
const STATUS_SUCCESS: NTSTATUS = 0;
const STATUS_INVALID_PARAMETER: NTSTATUS = 0xc000000du32 as i32;
const STATUS_GRAPHICS_INVALID_VIDPN: NTSTATUS = 0xc01e0303u32 as i32;
const CHILD_UID: u32 = 0;
fn ok(status: NTSTATUS) -> bool {
    status >= 0
}
fn rec(_: &[u8], _: u32) {}
fn legalize_vidpn(status: NTSTATUS) -> NTSTATUS {
    if status >= 0 || status as u32 >> 16 == 0xc01e || status as u32 == 0xc0000017 {
        status
    } else {
        STATUS_GRAPHICS_INVALID_VIDPN
    }
}
pub struct AdapterContext {
    committed_mode_wh: AtomicU64,
}
impl AdapterContext {
    fn preferred_display_mode(&self) -> (u32, u32) {
        (1280, 800)
    }
}
struct Flags(bool);
impl Flags {
    fn PathPoweredOff(&self) -> u32 {
        self.0 as u32
    }
}
pub struct DXGKARG_COMMITVIDPN {
    Flags: Flags,
    AffectedVidPnSourceId: u32,
    hFunctionalVidPn: D3DKMDT_HVIDPN,
}
struct Path {
    VidPnSourceId: u32,
    VidPnTargetId: u32,
}
struct State {
    count: usize,
    source: Option<(u32, u32)>,
    target: Option<(u32, u32)>,
    path: Path,
    error: NTSTATUS,
    open_error: bool,
    missing_topo: bool,
    missing_count: bool,
    paths_held: AtomicUsize,
    queries: AtomicUsize,
}
impl Default for State {
    fn default() -> Self {
        Self {
            count: 1,
            source: Some((1920, 1080)),
            target: Some((1920, 1080)),
            path: Path {
                VidPnSourceId: 0,
                VidPnTargetId: 0,
            },
            error: 0,
            open_error: false,
            missing_topo: false,
            missing_count: false,
            paths_held: AtomicUsize::new(0),
            queries: AtomicUsize::new(0),
        }
    }
}
struct DXGK_VIDPNTOPOLOGY_INTERFACE {
    pfnGetNumPaths: Option<unsafe fn(*mut State, *mut SIZE_T) -> NTSTATUS>,
}
struct Interface {
    pfnGetTopology: Option<
        unsafe fn(
            *mut State,
            *mut *mut State,
            *mut *const DXGK_VIDPNTOPOLOGY_INTERFACE,
        ) -> NTSTATUS,
    >,
}
unsafe fn count(state: *mut State, out: *mut SIZE_T) -> NTSTATUS {
    // SAFETY: fixture pointers live throughout the tested DDI call.
    unsafe {
        *out = (*state).count;
    }
    STATUS_SUCCESS
}
static TOPO: DXGK_VIDPNTOPOLOGY_INTERFACE = DXGK_VIDPNTOPOLOGY_INTERFACE {
    pfnGetNumPaths: Some(count),
};
static MISSING_COUNT: DXGK_VIDPNTOPOLOGY_INTERFACE = DXGK_VIDPNTOPOLOGY_INTERFACE {
    pfnGetNumPaths: None,
};
unsafe fn topology(
    state: *mut State,
    handle: *mut *mut State,
    out: *mut *const DXGK_VIDPNTOPOLOGY_INTERFACE,
) -> NTSTATUS {
    // SAFETY: fixture output pointers and State are valid for the call.
    unsafe {
        *handle = state;
        *out = if (*state).missing_count {
            &MISSING_COUNT
        } else {
            &TOPO
        };
    }
    STATUS_SUCCESS
}
struct VidPn {
    handle: *mut State,
    iface: Interface,
}
impl VidPn {
    unsafe fn open(
        _: &AdapterContext,
        handle: *mut State,
        _: &DXGKARG_COMMITVIDPN,
    ) -> Result<Self, NTSTATUS> {
        // SAFETY: a non-null fixture handle points to the State passed by run().
        if handle.is_null() || unsafe { (*handle).open_error } {
            return Err(STATUS_GRAPHICS_INVALID_VIDPN);
        }
        Ok(Self {
            handle,
            iface: Interface{pfnGetTopology:
            // SAFETY: same fixture validity window.
            if unsafe{(*handle).missing_topo} {None} else {Some(topology)}},
        })
    }
    fn iface(&self) -> &Interface {
        &self.iface
    }
    fn handle(&self) -> *mut State {
        self.handle
    }
}
struct PathInfo {
    state: *mut State,
}
impl PathInfo {
    unsafe fn first(
        _: &DXGK_VIDPNTOPOLOGY_INTERFACE,
        state: *mut State,
    ) -> Result<Option<Self>, NTSTATUS> {
        // SAFETY: topology fixture handle is valid for the tested call.
        unsafe {
            (*state).paths_held.fetch_add(1, Ordering::SeqCst);
        }
        Ok(Some(Self { state }))
    }
    fn get(&self) -> &Path {
        // SAFETY: State outlives the PathInfo guard.
        unsafe { &(*self.state).path }
    }
}
impl Drop for PathInfo {
    fn drop(&mut self) {
        // SAFETY: guard always drops before its caller-owned State.
        unsafe {
            (*self.state).paths_held.fetch_sub(1, Ordering::SeqCst);
        }
    }
}
unsafe fn pinned_extents(
    _: &Interface,
    state: *mut State,
    source: u32,
    target: u32,
) -> Result<(Option<(u32, u32)>, Option<(u32, u32)>), NTSTATUS> {
    assert_eq!(
        (source, target),
        (0, 0),
        "sentinel or invalid IDs reached an OS mode-set acquire"
    );
    // SAFETY: state is the fixture handle belonging to the live test call.
    let state = unsafe { &*state };
    state.queries.fetch_add(1, Ordering::SeqCst);
    if state.error < 0 {
        Err(state.error)
    } else {
        Ok((state.source, state.target))
    }
}
include!(concat!(env!("OUT_DIR"), "/commit.rs"));

#[cfg(test)]
mod tests {
    use super::*;
    fn run(
        state: &mut State,
        adapter: &AdapterContext,
        source: u32,
        powered_off: bool,
    ) -> NTSTATUS {
        let args = DXGKARG_COMMITVIDPN {
            Flags: Flags(powered_off),
            AffectedVidPnSourceId: source,
            hFunctionalVidPn: state,
        };
        // SAFETY: argument, state and adapter remain live through the tested call.
        let status = unsafe { commit_vidpn(adapter, &args) };
        assert_eq!(
            state.paths_held.load(Ordering::SeqCst),
            0,
            "path reference leaked"
        );
        status
    }
    fn adapter() -> AdapterContext {
        AdapterContext {
            committed_mode_wh: AtomicU64::new(display_modes::pack((1280, 800))),
        }
    }
    #[test]
    fn every_mode_commits_both_directions_including_all_source_updates() {
        let adapter = adapter();
        let mut state = State::default();
        for affected in [0, 0xffff_fffd] {
            for extent in display_modes::PRESETS
                .iter()
                .chain(display_modes::PRESETS.iter().rev())
            {
                state.source = Some(*extent);
                state.target = Some(*extent);
                assert_eq!(run(&mut state, &adapter, affected, false), STATUS_SUCCESS);
                assert_eq!(
                    adapter.committed_mode_wh.load(Ordering::Acquire),
                    display_modes::pack(*extent)
                );
            }
        }
        assert_eq!(state.queries.load(Ordering::SeqCst), 44);
    }
    #[test]
    fn incomplete_or_mismatched_pins_leave_previous_mode_intact() {
        let adapter = adapter();
        let mut state = State::default();
        for (source, target) in [
            (None, None),
            (None, Some((1920, 1080))),
            (Some((1920, 1080)), None),
            (Some((1920, 1080)), Some((1280, 800))),
            (Some((0, 0)), Some((0, 0))),
            (Some((u32::MAX, u32::MAX)), Some((u32::MAX, u32::MAX))),
        ] {
            state.source = source;
            state.target = target;
            assert_eq!(
                run(&mut state, &adapter, 0, false),
                STATUS_GRAPHICS_INVALID_VIDPN
            );
            assert_eq!(
                adapter.committed_mode_wh.load(Ordering::Acquire),
                display_modes::pack((1280, 800))
            );
        }
    }
    #[test]
    fn invalid_topology_and_callback_failure_are_not_fake_success() {
        let adapter = adapter();
        for case in 0..9 {
            let mut state = State::default();
            match case {
                0 => state.count = 2,
                1 => state.path.VidPnSourceId = 1,
                2 => state.path.VidPnTargetId = 1,
                3 => state.error = STATUS_INVALID_PARAMETER,
                4 => state.open_error = true,
                5 => state.missing_count = true,
                6 => state.missing_topo = true,
                _ => {}
            }
            let affected = if case == 7 {
                0xffff_ffff
            } else if case == 8 {
                1
            } else {
                0
            };
            assert_eq!(
                run(&mut state, &adapter, affected, false),
                STATUS_GRAPHICS_INVALID_VIDPN,
                "case {case}"
            );
            assert_eq!(
                adapter.committed_mode_wh.load(Ordering::Acquire),
                display_modes::pack((1280, 800))
            );
        }
    }
    #[test]
    fn empty_and_powered_off_paths_are_legal_and_do_not_publish_unknown_modes() {
        let adapter = adapter();
        let mut state = State::default();
        state.count = 0;
        assert_eq!(run(&mut state, &adapter, 0, false), STATUS_SUCCESS);
        state.count = 1;
        state.source = None;
        state.target = None;
        assert_eq!(run(&mut state, &adapter, 0, true), STATUS_SUCCESS);
        assert_eq!(state.queries.load(Ordering::SeqCst), 0);
        assert_eq!(
            adapter.committed_mode_wh.load(Ordering::Acquire),
            display_modes::pack((1280, 800))
        );
        // SAFETY: null is intentionally tested before the handler dereferences it.
        assert_eq!(
            unsafe { commit_vidpn(&adapter, null()) },
            STATUS_INVALID_PARAMETER
        );
    }
}
