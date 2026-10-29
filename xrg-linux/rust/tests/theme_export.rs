// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use std::{
    fs,
    path::PathBuf,
    sync::{
        Arc, Barrier,
        atomic::{AtomicU64, Ordering},
    },
};
use xrg_ng_linux::{settings::ThemeDocument, shared::Theme};
static NEXT: AtomicU64 = AtomicU64::new(0);
struct Scratch(PathBuf);
impl Scratch {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "xrg-theme-export-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
fn theme(name: &str) -> ThemeDocument {
    ThemeDocument::new(&Theme {
        name: name.into(),
        colors: [[0.2, 0.3, 0.4, 1.]; 7],
    })
}
#[test]
fn concurrent_new_exports_publish_exactly_one_complete_private_file() {
    use std::os::unix::fs::PermissionsExt;
    let s = Scratch::new();
    let path = s.0.join("theme.json");
    let barrier = Arc::new(Barrier::new(2));
    let threads: [_; 2] = ["first", "second"].map(|name| {
        let path = path.clone();
        let barrier = barrier.clone();
        std::thread::spawn(move || {
            barrier.wait();
            (name, theme(name).save_new(&path))
        })
    });
    let results = threads.map(|t| t.join().unwrap());
    assert_eq!(results.iter().filter(|(_, r)| r.is_ok()).count(), 1);
    let winner = results.iter().find(|(_, r)| r.is_ok()).unwrap().0;
    assert_eq!(ThemeDocument::load(&path).unwrap(), theme(winner));
    assert_eq!(
        fs::metadata(&path).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert_eq!(fs::read_dir(&s.0).unwrap().count(), 1);
}
#[test]
fn new_export_preserves_existing_files_and_links_until_explicit_replacement() {
    use std::os::unix::fs::symlink;
    let s = Scratch::new();
    let path = s.0.join("theme.json");
    let original = theme("original");
    original.save_new(&path).unwrap();
    let bytes = fs::read(&path).unwrap();
    assert!(theme("replacement").save_new(&path).is_err());
    assert_eq!(fs::read(&path).unwrap(), bytes);
    let link = s.0.join("linked.json");
    symlink(&path, &link).unwrap();
    assert!(theme("linked").save_new(&link).is_err());
    assert_eq!(fs::read(&path).unwrap(), bytes);
    theme("replacement").save(&path).unwrap();
    assert_eq!(ThemeDocument::load(&path).unwrap().name, "replacement");
    assert!(
        fs::symlink_metadata(&link)
            .unwrap()
            .file_type()
            .is_symlink()
    );
}
