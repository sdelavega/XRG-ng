// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
#[cfg(unix)]
use std::os::unix::fs::MetadataExt;
use std::{fs, path::Path};

/// The saved source excludes hwmon class numbering and transient inode numbers
/// when sysfs exposes a physical device path. The history identity includes the
/// current directory/input incarnation. Neither string is ever opened as a path.
pub(super) fn identity(
    sys: &Path,
    directory: &Path,
    input: &Path,
    chip: &str,
) -> Result<(String, String), String> {
    let root = fs::canonicalize(sys).map_err(|e| e.to_string())?;
    let directory = fs::canonicalize(directory).map_err(|e| e.to_string())?;
    let input = fs::canonicalize(input).map_err(|e| e.to_string())?;
    if input.parent() != Some(directory.as_path()) {
        return Err("Sensor attribute does not belong to its device".into());
    }
    let relative = directory
        .strip_prefix(&root)
        .map_err(|_| "Sensor outside sysfs root")?;
    let mut owner = relative;
    if relative.starts_with("devices")
        && relative
            .parent()
            .and_then(Path::file_name)
            .is_some_and(|n| n == "hwmon")
        && directory
            .file_name()
            .and_then(|n| n.to_str())
            .is_some_and(|n| {
                n.strip_prefix("hwmon")
                    .is_some_and(|s| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()))
            })
    {
        owner = relative
            .parent()
            .and_then(Path::parent)
            .ok_or("Invalid hwmon owner")?;
    }
    let owner = owner.to_str().ok_or("Non-UTF-8 sensor identity")?;
    let attribute = input
        .file_name()
        .and_then(|n| n.to_str())
        .ok_or("Invalid sensor attribute")?;
    let source = serde_json::to_string(&[owner, chip, attribute]).map_err(|e| e.to_string())?;
    if source.len() > 4096 || source.chars().any(char::is_control) {
        return Err("Sensor identity exceeds limits".into());
    }
    let directory = fs::metadata(&directory).map_err(|e| e.to_string())?;
    let input = fs::metadata(&input).map_err(|e| e.to_string())?;
    if !input.is_file() {
        return Err("Expected a regular sensor attribute".into());
    }
    // Inode incarnation metadata is POSIX; every unix target keeps it.
    #[cfg(unix)]
    let id = format!(
        "{source}:{}:{}:{}",
        directory.dev(),
        directory.ino(),
        input.ino()
    );
    #[cfg(not(unix))]
    let id = {
        // No device/inode incarnation metadata exists off Unix, so the
        // history identity degrades to the saved source identity; sysfs
        // never exists there to be scanned either.
        let _ = directory;
        format!("{source}:unavailable")
    };
    Ok((source, id))
}
