use std::{env, fs, path::PathBuf};
fn main() {
    let source = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap())
        .join("../../helios/upstream/kmd_render/src/ddi/vidpn.rs");
    println!("cargo:rerun-if-changed={}", source.display());
    let text = fs::read_to_string(source).unwrap();
    let start = text
        .find("pub unsafe fn commit_vidpn(")
        .expect("production CommitVidPn not found");
    fs::write(
        PathBuf::from(env::var("OUT_DIR").unwrap()).join("commit.rs"),
        &text[start..],
    )
    .unwrap();
}
