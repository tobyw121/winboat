use std::{env, fs, path::PathBuf};
fn main() {
    let source = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap())
        .join("../../helios/upstream/umd/src/forward/transfer.rs");
    println!("cargo:rerun-if-changed={}", source.display());
    let text = fs::read_to_string(source).unwrap();
    let start = text.find("pub(crate) unsafe extern \"system\" fn clear_view_11_1(").unwrap();
    let end = text[start..].find("\npub(crate) unsafe extern \"system\" fn resource_update_subresource(").unwrap() + start;
    fs::write(PathBuf::from(env::var("OUT_DIR").unwrap()).join("handler.rs"), &text[start..end]).unwrap();
    let source = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap())
        .join("../../helios/upstream/umd/src/forward/queries.rs");
    println!("cargo:rerun-if-changed={}", source.display());
    let text = fs::read_to_string(source).unwrap();
    let start = text.find("pub(crate) unsafe fn helios_multisample_quality_levels(").unwrap();
    let end = text[start..].find("pub(crate) unsafe extern \"system\" fn check_multisample_quality_levels(").unwrap() + start;
    fs::write(PathBuf::from(env::var("OUT_DIR").unwrap()).join("msaa.rs"), &text[start..end]).unwrap();

    let source = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap())
        .join("../../helios/upstream/umd/src/forward/state.rs");
    println!("cargo:rerun-if-changed={}", source.display());
    let text = fs::read_to_string(source).unwrap();
    let start = text.find("pub(crate) fn create_callback_hr").unwrap();
    let end = text[start..].find("pub(crate) fn create_error_hr").unwrap() + start;
    fs::write(PathBuf::from(env::var("OUT_DIR").unwrap()).join("create_error.rs"), &text[start..end]).unwrap();
    let start = text.find("pub(crate) unsafe fn checked_create_arg").unwrap();
    let end = text[start..].find("/// The only way a VOID-returning").unwrap() + start;
    fs::write(PathBuf::from(env::var("OUT_DIR").unwrap()).join("create_args.rs"), &text[start..end]).unwrap();

    let source = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap())
        .join("../../helios/upstream/umd/src/bridge.rs");
    println!("cargo:rerun-if-changed={}", source.display());
    let text = fs::read_to_string(source).unwrap();
    let start = text.rfind("fn shader_create_result(").unwrap();
    fs::write(PathBuf::from(env::var("OUT_DIR").unwrap()).join("shader_result.rs"), &text[start..]).unwrap();

}
