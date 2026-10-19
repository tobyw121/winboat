//! Execute the production journal without Windows handle lookup or log I/O.
#![allow(dead_code)]
#[macro_export]
macro_rules! log_error { ($($arg:tt)*) => { let _ = format_args!($($arg)*); } }
mod ddi { #[allow(non_camel_case_types)] pub type D3D10DDI_HDEVICE = usize; }
struct Device { diagnostics: diagnostics::DeviceDiagnostics }
mod forward {
    pub unsafe fn helios_device(_: usize) -> Option<&'static super::Device> { None }
}
#[path = "../helios/upstream/umd/src/diagnostics.rs"]
mod diagnostics;
