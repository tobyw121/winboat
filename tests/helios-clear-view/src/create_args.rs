//! Exercise the production null-descriptor guard and its error callback.
use std::cell::RefCell;
type Hdevice = usize;
const E_INVALIDARG: i32 = 0x80070057u32 as i32;
const E_FAIL: i32 = 0x80004005u32 as i32;
include!(concat!(env!("OUT_DIR"), "/create_error.rs"));
#[test]
fn creation_preserves_real_errors_and_translates_device_loss() {
    for raw in [0x887a0005u32, 0x887a0006, 0x887a0007, 0x887a0020] {
        assert_eq!(create_callback_hr(raw as i32), crate::hr::D3DDDIERR_DEVICEREMOVED);
    }
    for raw in [E_INVALIDARG, E_FAIL, 0x8007000eu32 as i32, crate::hr::D3DDDIERR_DEVICEREMOVED] {
        assert_eq!(create_callback_hr(raw), raw); // Never disguise a bug as OOM.
    }
    assert_eq!(create_callback_hr(0), E_FAIL);
    assert_eq!(create_callback_hr(1), E_FAIL);
}
thread_local! { static ERRORS: RefCell<Vec<(usize, i32)>> = const { RefCell::new(Vec::new()) }; }
unsafe fn set_runtime_error(h: Hdevice, code: i32) { ERRORS.with(|errors| errors.borrow_mut().push((h, code))); }
include!(concat!(env!("OUT_DIR"), "/create_args.rs"));
#[test]
fn invalid_descriptors_fail_the_originating_runtime_call() {
    ERRORS.with(|errors| errors.borrow_mut().clear());
    let descriptor = 42u32;
    // SAFETY: either null or storage that remains live for this call.
    unsafe {
        assert_eq!(checked_create_arg(7, &descriptor), Some(&42));
        assert!(checked_create_arg::<u32>(11, std::ptr::null()).is_none());
    }
    ERRORS.with(|errors| assert_eq!(&*errors.borrow(), &[(11, E_INVALIDARG)]));
}
