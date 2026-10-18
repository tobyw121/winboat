//! Real production MSAA query body against Windows WARP; no Helios hardware claim.
use windows::{core::Interface, Win32::Graphics::{
    Direct3D11::{ID3D11Device, ID3D11Device2}, Dxgi::Common::*}};
type Hdevice = *const ID3D11Device;
struct Throttle;
impl Throttle { fn first_n_then_every(&self, _: usize, _: usize) -> Option<usize> { None } }
static MSAA_LOG_COUNT: Throttle = Throttle;
unsafe fn d3d11_device(h: Hdevice) -> Option<ID3D11Device> {
    // SAFETY: fixtures keep the referenced COM device alive for each call.
    unsafe { h.as_ref().cloned() }
}
mod ddi { pub type DXGI_FORMAT = i32; }
include!(concat!(env!("OUT_DIR"), "/msaa.rs"));

#[test]
fn msaa_matches_real_backend_including_invalid_formats_and_counts() {
    // SAFETY: live WARP COM device, scalar inputs, no application memory buffers.
    unsafe {
        let (device, _) = super::device();
        for format in [DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_FORMAT_R32G32B32A32_FLOAT,
                       DXGI_FORMAT_D32_FLOAT, DXGI_FORMAT_UNKNOWN] {
            for count in [0u32, 1, 2, 3, 4, 8, 16, 32, 33] {
                let expected = device.CheckMultisampleQualityLevels(format, count).unwrap_or(0);
                assert_eq!(helios_multisample_quality_levels(&device, format.0, count, 0), expected,
                    "format={} samples={count}", format.0);
            }
        }
        assert_eq!(helios_multisample_quality_levels(std::ptr::null(), 87, 1, 0), 0);
        assert_eq!(helios_multisample_quality_levels(&device, 87, 4, 2), 0);
        let device2: ID3D11Device2 = device.cast().unwrap();
        let expected = device2.CheckMultisampleQualityLevels1(DXGI_FORMAT_B8G8R8A8_UNORM, 4, 1).unwrap_or(0);
        assert_eq!(helios_multisample_quality_levels(&device, 87, 4, 1), expected);
        crate::caps::SINGLE.set(true);
        assert_eq!(helios_multisample_quality_levels(&device, 87, 4, 0), 0);
        // WARP may report the trivial single-sample level even for UNKNOWN.
        // SingleSampleOnly constrains counts, not the backend's format oracle.
        assert_eq!(helios_multisample_quality_levels(&device, 0, 1, 0),
            device.CheckMultisampleQualityLevels(DXGI_FORMAT_UNKNOWN, 1).unwrap_or(0));
        crate::caps::SINGLE.set(false);
    }
}
