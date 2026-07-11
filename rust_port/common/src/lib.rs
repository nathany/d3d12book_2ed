//! Port of the book's `Common/` layer. Grows chapter by chapter.
//!
//! Modules that are (partial) ports of DirectXTK12 rather than the book's own code say so
//! in their module docs — check there before comparing against the C++.

pub mod d3d_app;
pub mod d3d_util;
pub mod descriptor_util;
pub mod game_timer;
pub mod testing;

use std::path::PathBuf;

/// Resolve a path to the book's shared assets (`Shaders/`, `Textures/`, `Models/` at the
/// repository root), regardless of the current working directory.
///
/// The C++ demos hardcode paths relative to `bin\` and must be run from there. Here we walk
/// up from the executable's location (`rust_port/target/debug/...`) until we find the asset
/// root, so `cargo run` works from anywhere in the repo — including a custom
/// `CARGO_TARGET_DIR`, as long as it lives under the repository.
pub fn asset_path(relative: &str) -> PathBuf {
    let exe = std::env::current_exe().expect("current_exe unavailable");
    let mut dir = exe.parent().expect("exe has no parent").to_path_buf();
    loop {
        if dir.join("Shaders").is_dir() && dir.join("Textures").is_dir() {
            return dir.join(relative);
        }
        if !dir.pop() {
            panic!(
                "could not find the book's asset root (a directory containing Shaders/ and \
                 Textures/) above {} — is the exe inside the repository?",
                exe.display()
            );
        }
    }
}
