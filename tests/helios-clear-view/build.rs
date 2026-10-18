use std::{env, fs, path::PathBuf};
fn main() {
    let source = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap())
        .join("../../helios/upstream/umd/src/forward/transfer.rs");
    println!("cargo:rerun-if-changed={}", source.display());
    let text = fs::read_to_string(source).unwrap();
    let start = text.find("pub(crate) unsafe extern \"system\" fn clear_view_11_1(").unwrap();
    let end = text[start..].find("\npub(crate) unsafe extern \"system\" fn resource_update_subresource(").unwrap() + start;
    fs::write(PathBuf::from(env::var("OUT_DIR").unwrap()).join("handler.rs"), &text[start..end]).unwrap();
}
