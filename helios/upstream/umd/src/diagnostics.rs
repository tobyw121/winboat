//! Bounded per-device initialization journal, independent of UmdTrace.
//! No per-frame output or changes to synchronization.
use std::collections::{BTreeMap, VecDeque};
use std::sync::{Mutex, atomic::{AtomicBool, AtomicU64, Ordering}};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

/// Process-local test override; reject everything outside the three known profiles.
pub(crate) fn profile_override(value: &str) -> Option<u32> {
    match value { "0" => Some(0), "1" => Some(1), "2" => Some(2), _ => None }
}

/// Diagnostic-only intersection with the real backend. Keep existing runtime
/// normalization, but never invent output/MSAA capabilities missing below it.
/// Low DDI MSAA bits collide with API SO_BUFFER/TEXTURE1D and are handled apart.
pub(crate) fn backend_bounded_format(fmt: u32, raw: u32, normalized: u32) -> u32 {
    const OUTPUT: u32 = 0x0004_0000 | 0x0020_0000 | 0x0040_0000 |
        0x0000_4000 | 0x0000_8000 | 0x0001_0000;
    let mut answer = normalized & !(OUTPUT & !raw);
    if raw & 0x0020_0000 == 0 { answer &= !8; }
    if raw & 0x0040_0000 == 0 { answer &= !16; }
    if fmt == 89 && raw == 0 { return 0x8000_0000; }
    answer
}

// Scope the operation to its DDI callback and thread. An unrelated callback
// must never inherit a stale label from an earlier resource/view operation.
thread_local! { static OPERATION: std::cell::Cell<Option<(u64,[u64;6])>> = const { std::cell::Cell::new(None) }; }
pub(crate) struct OperationScope(Option<(u64,[u64;6])>);
impl Drop for OperationScope { fn drop(&mut self) { OPERATION.with(|slot| slot.set(self.0)); } }
fn operation_code(kind: &str) -> u64 { match kind { "resource"=>1,"view"=>2,"shader"=>3,_=>0 } }
fn annotate_error(mut values:[u64;6]) -> [u64;6] {
    if let Some((kind,context))=OPERATION.with(|slot| slot.get()) {
        values[1]=kind; values[2..6].copy_from_slice(&context[..4]);
    }
    values
}
/// SAFETY: same live runtime HDEVICE contract as `note`. Guard must remain in
/// the DDI stack frame; dropping it restores a nested caller's context.
pub(crate) unsafe fn operation(h: crate::ddi::D3D10DDI_HDEVICE, kind: &'static str, values:[u64;6]) -> OperationScope {
    let previous=OPERATION.with(|slot| slot.replace(Some((operation_code(kind),values))));
    // SAFETY: caller supplies the current DDI's live HDEVICE.
    unsafe { note(h,kind,values); }
    OperationScope(previous)
}

const LIMIT: usize = 96;
static NEXT_ID: AtomicU64 = AtomicU64::new(1);

#[derive(Clone, Copy)]
struct Event { seq: u64, kind: &'static str, values: [u64; 6] }
#[derive(Default)]
struct Journal {
    seq: u64,
    entries: VecDeque<Event>,
    formats: BTreeMap<u64, u64>,
    mismatches: u64,
    first_mismatch: Option<[u64; 6]>,
    first_failure: Option<Vec<Event>>,
}
impl Journal {
    fn record(&mut self, kind: &'static str, values: [u64; 6]) {
        self.seq += 1;
        if kind == "format" && values[0] <= 255 {
            self.formats.insert(values[0], values[2]);
        }
        // A flagged FL11 render format must support 4x MSAA. A zero level
        // for optional counts (2x/16x/32x) is not itself a contradiction.
        if kind == "msaa" && values[1] == 4 && values[2] == 0 &&
            values[3] == 0 && values[5] == 1 &&
            self.formats.get(&values[0]).is_some_and(|caps| caps & 8 != 0) {
            self.mismatches += 1;
            self.first_mismatch.get_or_insert(values);
        }
        if self.entries.len() == LIMIT { self.entries.pop_front(); }
        self.entries.push_back(Event { seq: self.seq, kind, values });
        if kind == "runtime-error" && values[0] & 0x8000_0000 != 0 && self.first_failure.is_none() {
            // Freeze the immediate numeric context; later successful queries
            // must not erase the first reported DDI failure.
            self.first_failure = Some(self.entries.iter().rev().take(16).copied().collect::<Vec<_>>());
        }
    }
}

pub(crate) struct DeviceDiagnostics {
    id: u64,
    birth: u128,
    started: Instant,
    journal: Mutex<Journal>,
    presented: AtomicBool,
    failure_dumped: AtomicBool,
}
impl DeviceDiagnostics {
    pub(crate) fn new() -> Self {
        Self { id: NEXT_ID.fetch_add(1, Ordering::Relaxed),
            birth: SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_micros(),
            started: Instant::now(), journal: Mutex::new(Journal::default()), presented: AtomicBool::new(false),
            failure_dumped: AtomicBool::new(false) }
    }
    fn record(&self, kind: &'static str, values: [u64; 6]) {
        if kind == "present" && self.presented.swap(true, Ordering::Relaxed) { return; }
        self.journal.lock().unwrap_or_else(|e| e.into_inner()).record(kind, values);
        if kind == "runtime-error" && values[0] & 0x8000_0000 != 0 &&
            !self.failure_dumped.swap(true, Ordering::Relaxed) {
            // No journal mutex is held during dump acquisition. At most once
            // per device; no per-frame flush or changes to runtime callbacks.
            self.dump();
        }
    }
    pub(crate) fn dump(&self) {
        let journal = self.journal.lock().unwrap_or_else(|e| e.into_inner());
        crate::log_error!("GPU-DIAG device={} birth={} elapsed_ms={} queries={} mismatches={} presented={}",
            self.id, self.birth, self.started.elapsed().as_millis(), journal.seq, journal.mismatches, u8::from(self.presented.load(Ordering::Relaxed)));
        if let Some(v) = journal.first_mismatch {
            crate::log_error!("GPU-DIAG mismatch device={} birth={} fmt={} samples={} flags={} levels={} hr=0x{:08x}",
                self.id, self.birth, v[0], v[1], v[2], v[3], v[4]);
        }
        if let Some(events) = &journal.first_failure {
            for e in events.iter().rev() {
                let v = e.values;
                crate::log_error!("GPU-DIAG first-failure device={} birth={} seq={} kind={} a={} b={} c={} d={} e={} f={}",
                    self.id, self.birth, e.seq, e.kind, v[0], v[1], v[2], v[3], v[4], v[5]);
            }
        }
        for e in &journal.entries {
            let v = e.values;
            crate::log_error!("GPU-DIAG event device={} birth={} seq={} kind={} a={} b={} c={} d={} e={} f={}",
                self.id, self.birth, e.seq, e.kind, v[0], v[1], v[2], v[3], v[4], v[5]);
        }
    }
}

/// SAFETY: callers supply the runtime's live HDEVICE for the current DDI.
/// Resolver checks the object tag and follows deferred contexts to their parent.
pub(crate) unsafe fn note(h: crate::ddi::D3D10DDI_HDEVICE, kind: &'static str, values: [u64; 6]) {
    let code=operation_code(kind);
    if code!=0 {
        OPERATION.with(|slot| { if slot.get().is_some_and(|v|v.0==code) { slot.set(Some((code,values))); } });
    }
    let values=if kind=="runtime-error" {annotate_error(values)} else {values};
    // SAFETY: lifetime/handle contract is provided by the DDI caller above.
    if let Some(dev) = unsafe { crate::forward::helios_device(h) } {
        dev.diagnostics.record(kind, values);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ddi_failure_context_is_thread_scoped_and_restored() {
        let failure=[0x80070057,0,0,0,0,0];
        // SAFETY: the host test's resolver always returns None; no HDEVICE is read.
        let outer=unsafe {operation(0,"resource",[28,1920,1080,4,0,0])};
        assert_eq!(annotate_error(failure),[0x80070057,1,28,1920,1080,4]);
        {
            // SAFETY: same test resolver with no pointer dereference.
            let _inner=unsafe {operation(0,"view",[2,1,0,0,0,0])};
            assert_eq!(annotate_error(failure)[1],2);
        }
        assert_eq!(annotate_error(failure)[1],1);
        assert_eq!(std::thread::spawn(move ||annotate_error(failure)).join().unwrap(),failure);
        drop(outer);assert_eq!(annotate_error(failure),failure);
    }
    #[test]
    fn backend_profile_cannot_add_output_caps_or_lose_xr_sentinel() {
        assert_eq!(backend_bounded_format(28, 0, 0x0064_c018) & 0x0064_c018, 0);
        assert_eq!(backend_bounded_format(28, 0x0064_c000, 0x0064_c018), 0x0064_c018);
        assert_eq!(backend_bounded_format(89, 0, 0), 0x8000_0000);
        for raw in [0, 8, 16, 0x20_0000, 0x40_0000, u32::MAX] {
            let answer = backend_bounded_format(28, raw, u32::MAX);
            assert_eq!(answer & 0x0065_c000 & !raw, 0);
        }
    }
    #[test]
    fn diagnostic_profiles_are_explicit_and_bounded() {
        for n in 0..3 { assert_eq!(profile_override(&n.to_string()), Some(n)); }
        for bad in ["", "3", "-1", "true", " 1"] { assert_eq!(profile_override(bad), None); }
    }
    #[test]
    fn journal_keeps_last_events_and_first_contract_failure() {
        let mut j = Journal::default();
        j.record("format", [28, 0, 8, 0, 0, 0]);
        j.record("msaa", [28, 4, 0, 0, 0, 1]);
        for i in 0..200 { j.record("view", [i, 0, 0, 0, 0, 0]); }
        assert_eq!(j.entries.len(), LIMIT);
        assert_eq!(j.entries.front().unwrap().seq, 107);
        assert_eq!(j.entries.back().unwrap().seq, 202);
        assert_eq!(j.first_mismatch.unwrap()[0], 28);
        assert_eq!(j.mismatches, 1);
    }
    #[test]
    fn optional_samples_tiled_queries_and_fl10_are_not_mismatches() {
        let mut j = Journal::default();
        j.record("format", [28, 0, 8, 0, 0, 0]);
        for v in [[28, 2, 0, 0, 0, 1], [28, 4, 1, 0, 0, 1], [28, 4, 0, 0, 0, 0]] {
            j.record("msaa", v);
        }
        assert_eq!(j.mismatches, 0);
        assert!(j.first_mismatch.is_none());
        assert_ne!(DeviceDiagnostics::new().id, DeviceDiagnostics::new().id);
    }
    #[test]
    fn first_failure_context_survives_ring_wrap_and_later_failures() {
        let mut j = Journal::default();
        j.record("resource", [28, 1920, 1080, 4, 0, 32]);
        j.record("runtime-error", [0, 0, 0, 0, 0, 0]);
        assert!(j.first_failure.is_none());
        j.record("runtime-error", [0x80070057, 0, 0, 0, 0, 0]);
        for i in 0..200 { j.record("format", [i, 0, 0, 0, 0, 0]); }
        j.record("runtime-error", [0x80004005, 0, 0, 0, 0, 0]);
        let first = j.first_failure.unwrap();
        assert_eq!(first.len(), 3);
        assert_eq!(first[0].values[0], 0x80070057);
        assert_eq!(first[2].values, [28, 1920, 1080, 4, 0, 32]);
    }
}
