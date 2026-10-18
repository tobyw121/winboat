//! Execute the actual Helios ClearView handler with real Windows WARP contexts.
//! Only device/handle lookup and diagnostics are fixtures. This does not load
//! Helios's UMD or validate its WDDM ABI, Venus transport or GPU presentation.
#![cfg(all(test, windows))]
#![allow(non_snake_case, non_camel_case_types, non_upper_case_globals)]
use std::{ffi::c_void, mem::ManuallyDrop, sync::atomic::{AtomicUsize, Ordering}};
use windows::{core::Interface, Win32::{Foundation::{HMODULE, RECT}, Graphics::{
    Direct3D::{D3D_DRIVER_TYPE_WARP, D3D_FEATURE_LEVEL_11_0}, Direct3D11::*, Dxgi::Common::*}}};

mod ddi {
    pub type D3D11DDI_HANDLETYPE = u32;
    // Fixture tags only: native DDI constants/layout remain checked by WDK builds.
    pub const D3D11DDI_HANDLETYPE_D3D10DDI_HT_RENDERTARGETVIEW: u32 = 1;
    pub const D3D11DDI_HANDLETYPE_D3D11DDI_HT_UNORDEREDACCESSVIEW: u32 = 2;
    pub type D3D10_DDI_RECT = windows::Win32::Foundation::RECT;
}
type Hdevice = *const ID3D11DeviceContext1;
struct Counter(AtomicUsize);
impl Counter {
    fn first_n(&self, _: usize) -> Option<usize> { None }
    fn bump(&self) { self.0.fetch_add(1, Ordering::Relaxed); }
}
struct Refusals { clear_view_unsupported: Counter }
static D3D11_1_LOG_COUNT: Counter = Counter(AtomicUsize::new(0));
static DDI_REFUSALS: Refusals = Refusals { clear_view_unsupported: Counter(AtomicUsize::new(0)) };
fn note_ddi_refusal(counter: &Counter) { counter.bump(); }
macro_rules! trace_line { ($($arg:tt)*) => { eprintln!($($arg)*); } }
macro_rules! log_error { ($($arg:tt)*) => { eprintln!($($arg)*); } }
unsafe fn d3d11_context1(h: Hdevice) -> Option<ID3D11DeviceContext1> {
    // SAFETY: fixtures pass a live context reference for the complete call.
    unsafe { h.as_ref().cloned() }
}
unsafe fn load_com_at<T: Interface>(slot: *mut c_void) -> Option<ManuallyDrop<T>> {
    // SAFETY: UAV fixtures own a pointer-sized slot with the matching COM word.
    let raw = unsafe { *(slot.cast::<usize>().as_ref()?) };
    if raw == 0 { None } else { Some(ManuallyDrop::new(unsafe { T::from_raw(raw as *mut c_void) })) }
}
struct RtvState { view: ID3D11RenderTargetView }
unsafe fn load_rtv_at(slot: *mut c_void) -> Option<ManuallyDrop<ID3D11RenderTargetView>> {
    // SAFETY: RTV fixtures own a slot pointing to a live boxed state, not COM.
    let state = unsafe { *(slot.cast::<*const RtvState>().as_ref()?) };
    Some(ManuallyDrop::new(unsafe { ID3D11RenderTargetView::from_raw(state.as_ref()?.view.as_raw()) }))
}
// This is the production function verbatim, not a copied implementation.
include!(concat!(env!("OUT_DIR"), "/handler.rs"));

unsafe fn device() -> (ID3D11Device, ID3D11DeviceContext1) {
    let (mut device, mut context) = (None, None);
    // SAFETY: valid output pointers and Windows' built-in software adapter.
    unsafe { D3D11CreateDevice(None, D3D_DRIVER_TYPE_WARP, HMODULE::default(),
        D3D11_CREATE_DEVICE_BGRA_SUPPORT, Some(&[D3D_FEATURE_LEVEL_11_0]), D3D11_SDK_VERSION,
        Some(&mut device), None, Some(&mut context)).unwrap(); }
    (device.unwrap(), context.unwrap().cast().unwrap())
}
unsafe fn read_texture(device: &ID3D11Device, context: &ID3D11DeviceContext1, texture: &ID3D11Texture2D) -> Vec<[f32; 4]> {
    let mut desc = D3D11_TEXTURE2D_DESC::default();
    // SAFETY: texture and all output pointers remain live throughout readback.
    unsafe {
        texture.GetDesc(&mut desc);
        desc.Usage = D3D11_USAGE_STAGING; desc.BindFlags = 0;
        desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ.0 as u32;
        let mut staging = None;
        device.CreateTexture2D(&desc, None, Some(&mut staging)).unwrap();
        let staging = staging.unwrap(); context.CopyResource(&staging, texture);
        let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
        context.Map(&staging, 0, D3D11_MAP_READ, 0, Some(&mut mapped)).unwrap();
        let mut pixels = Vec::new();
        for y in 0..desc.Height {
            let row = (mapped.pData as *const u8).add(y as usize * mapped.RowPitch as usize).cast::<[f32; 4]>();
            pixels.extend_from_slice(std::slice::from_raw_parts(row, desc.Width as usize));
        }
        context.Unmap(&staging, 0); pixels
    }
}
#[test]
fn real_warp_rtv_and_uav_preserve_pixels_outside_rectangles() {
    // SAFETY: all resource, COM-slot and rectangle lifetimes cover each DDI call.
    unsafe {
        let (device, context) = device();
        let desc = D3D11_TEXTURE2D_DESC { Width: 4, Height: 4, MipLevels: 1, ArraySize: 1,
            Format: DXGI_FORMAT_R32G32B32A32_FLOAT, SampleDesc: DXGI_SAMPLE_DESC {Count: 1, Quality: 0},
            Usage: D3D11_USAGE_DEFAULT, BindFlags: (D3D11_BIND_RENDER_TARGET.0 | D3D11_BIND_UNORDERED_ACCESS.0) as u32,
            ..Default::default() };
        let mut texture = None; device.CreateTexture2D(&desc, None, Some(&mut texture)).unwrap();
        let texture = texture.unwrap();
        let mut rtv = None; device.CreateRenderTargetView(&texture, None, Some(&mut rtv)).unwrap();
        let rtv = rtv.unwrap();
        let state = Box::new(RtvState {view: rtv.clone()});
        let mut state_pointer: *const RtvState = &*state;
        let mut uav = None; device.CreateUnorderedAccessView(&texture, None, Some(&mut uav)).unwrap();
        let uav = uav.unwrap(); let mut com_pointer = uav.as_raw() as usize;
        let color = [0.25, 0.5, 0.75, 1.0];
        let rects = [RECT {left: 1, top: 1, right: 3, bottom: 3}, RECT {left: 0, top: 0, right: 0, bottom: 4}];
        for (kind, slot) in [(ddi::D3D11DDI_HANDLETYPE_D3D10DDI_HT_RENDERTARGETVIEW,
                (&mut state_pointer as *mut *const RtvState).cast::<c_void>()),
                (ddi::D3D11DDI_HANDLETYPE_D3D11DDI_HT_UNORDEREDACCESSVIEW,
                (&mut com_pointer as *mut usize).cast::<c_void>())] {
            context.ClearRenderTargetView(&rtv, &[0.0; 4]);
            clear_view_11_1(&context, kind, slot, color.as_ptr(), std::ptr::null(), 0);
            assert!(read_texture(&device, &context, &texture).iter().all(|p| *p == color), "full view kind={kind}");
            context.ClearRenderTargetView(&rtv, &[0.0; 4]);
            clear_view_11_1(&context, kind, slot, color.as_ptr(), rects.as_ptr(), rects.len() as u32);
            for (i, pixel) in read_texture(&device, &context, &texture).iter().enumerate() {
                let inner = (1..3).contains(&(i % 4)) && (1..3).contains(&(i / 4));
                assert_eq!(*pixel, if inner {color} else {[0.0; 4]}, "rect view kind={kind} pixel={i}");
            }
        }
        // An unsupported tag or missing slot must not touch the surface.
        context.ClearRenderTargetView(&rtv, &[0.0; 4]);
        clear_view_11_1(&context, 99, std::ptr::null_mut(), color.as_ptr(), std::ptr::null(), 0);
        clear_view_11_1(&context, ddi::D3D11DDI_HANDLETYPE_D3D11DDI_HT_UNORDEREDACCESSVIEW,
            std::ptr::null_mut(), color.as_ptr(), std::ptr::null(), 0);
        assert!(read_texture(&device, &context, &texture).iter().all(|p| *p == [0.0; 4]));
        assert!(DDI_REFUSALS.clear_view_unsupported.0.load(Ordering::Relaxed) >= 2);
    }
}

#[test]
fn real_warp_typed_buffer_uav_whole_and_partial_clear() {
    // SAFETY: fixture slots own live COM references and staging Map bounds are
    // the buffer's exact ByteWidth; Unmap follows each successful Map.
    unsafe {
        let (device, context) = device();
        let desc = D3D11_BUFFER_DESC {ByteWidth: 16 * 4, Usage: D3D11_USAGE_DEFAULT,
            BindFlags: D3D11_BIND_UNORDERED_ACCESS.0 as u32, ..Default::default()};
        let mut buffer = None; device.CreateBuffer(&desc, None, Some(&mut buffer)).unwrap();
        let buffer = buffer.unwrap();
        let view_desc = D3D11_UNORDERED_ACCESS_VIEW_DESC {Format: DXGI_FORMAT_R32_FLOAT,
            ViewDimension: D3D11_UAV_DIMENSION_BUFFER,
            Anonymous: D3D11_UNORDERED_ACCESS_VIEW_DESC_0 {Buffer: D3D11_BUFFER_UAV {
                FirstElement: 0, NumElements: 16, Flags: 0}}};
        let mut view = None; device.CreateUnorderedAccessView(&buffer, Some(&view_desc), Some(&mut view)).unwrap();
        let view = view.unwrap(); let mut pointer = view.as_raw() as usize;
        let slot = (&mut pointer as *mut usize).cast::<c_void>();
        let mut staging = None;
        let staging_desc = D3D11_BUFFER_DESC {Usage: D3D11_USAGE_STAGING, BindFlags: 0,
            CPUAccessFlags: D3D11_CPU_ACCESS_READ.0 as u32, ..desc};
        device.CreateBuffer(&staging_desc, None, Some(&mut staging)).unwrap();
        let staging = staging.unwrap();
        let rectangle = RECT {left: 4, right: 8, top: 0, bottom: 1};
        for partial in [false, true] {
            context.ClearUnorderedAccessViewFloat(&view, &[0.0; 4]);
            clear_view_11_1(&context, ddi::D3D11DDI_HANDLETYPE_D3D11DDI_HT_UNORDEREDACCESSVIEW,
                slot, [0.25, 0.5, 0.75, 1.0].as_ptr(),
                if partial {&rectangle} else {std::ptr::null()}, if partial {1} else {0});
            context.CopyResource(&staging, &buffer);
            let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
            context.Map(&staging, 0, D3D11_MAP_READ, 0, Some(&mut mapped)).unwrap();
            let values = std::slice::from_raw_parts(mapped.pData as *const f32, 16).to_vec();
            context.Unmap(&staging, 0);
            for (i, value) in values.into_iter().enumerate() {
                assert_eq!(value, if !partial || (4..8).contains(&i) {0.25} else {0.0}, "buffer index={i} partial={partial}");
            }
        }
    }
}

mod caps {
    use std::cell::Cell;
    #[derive(PartialEq)]
    pub enum MsaaPolicy { SingleSampleOnly, Backend }
    pub struct Profile { pub msaa: MsaaPolicy }
    thread_local! { pub static SINGLE: Cell<bool> = const { Cell::new(false) }; }
    pub fn feature_profile() -> Profile {
        Profile { msaa: if SINGLE.get() { MsaaPolicy::SingleSampleOnly } else { MsaaPolicy::Backend } }
    }
}
mod msaa;

mod create_args;
