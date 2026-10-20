//! Bounded per-device initialization journal, independent of UmdTrace.
//! No per-frame output and no changes to capability answers or synchronization.
use std::collections::{BTreeMap, VecDeque};
use std::sync::{Mutex, atomic::{AtomicBool, AtomicU64, Ordering}};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

/// Process-local test override; reject everything outside the three known profiles.
pub(crate) fn profile_override(value: &str) -> Option<u32> {
    match value { "0" => Some(0), "1" => Some(1), "2" => Some(2), _ => None }
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
    // SAFETY: lifetime/handle contract is provided by the DDI caller above.
    if let Some(dev) = unsafe { crate::forward::helios_device(h) } {
        dev.diagnostics.record(kind, values);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
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
