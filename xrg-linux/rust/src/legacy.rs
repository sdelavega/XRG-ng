// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Explicit, read-only import of the C application's GLib key-file settings.
use crate::{
    settings::{GraphStyle, Layout, Module, Settings, ThemeChoice, ThemeDocument},
    system_file,
    temperature::Units,
};
use std::{
    collections::BTreeMap,
    ffi::OsStr,
    path::{Path, PathBuf},
};
const LIMIT: usize = 128 * 1024;

#[derive(Debug)]
pub struct Import {
    pub settings: Settings,
    pub imported: Vec<String>,
    pub skipped: Vec<String>,
    pub repeated_keys: usize,
}
impl Import {
    pub fn summary(&self) -> String {
        let mut text = format!(
            "{} entries ready to import; {} entries not transferred.\n\nImport into draft changes only this Preferences draft. Apply in Preferences to use and save it. The source file is never changed.\n\nMissing fields keep the current draft values. Graph styles, activity bar visibility/style/color, layout and system temperature units transfer when present. Graph order/sizes, metric sources, process filters, AI source settings and weather remain unchanged. VRAM and Fans keep their current visibility. Imported colors retain alpha; the main window background remains opaque.\n\nReady to import:\n{}",
            self.imported.len(),
            self.skipped.len(),
            self.imported.join("\n")
        );
        if self.repeated_keys > 0 {
            text.push_str(&format!(
                "\n\nRepeated keys: {}. The last value wins, matching GLib key files.",
                self.repeated_keys
            ));
        }
        if !self.skipped.is_empty() {
            text.push_str(&format!(
                "\n\nNot transferred (unsupported settings or metadata):\n{}",
                self.skipped.join("\n")
            ));
        }
        text
    }
}
pub fn path_from(config_home: Option<&OsStr>, home: Option<&OsStr>) -> Option<PathBuf> {
    crate::settings::path_from(config_home, home).and_then(|p| {
        p.parent()?
            .parent()
            .map(|r| r.join("xrg-linux/settings.conf"))
    })
}
pub fn load(path: &Path, base: &Settings) -> Result<Import, String> {
    parse(
        &system_file::read(path, LIMIT)
            .map_err(|e| format!("Could not read legacy settings: {e}"))?,
        base,
    )
}
pub fn parse(bytes: &[u8], base: &Settings) -> Result<Import, String> {
    base.validate()
        .map_err(|e| format!("Fix the current Preferences draft first: {e}"))?;
    if bytes.len() > LIMIT {
        return Err("Legacy settings exceed 128 KiB".into());
    }
    let text = std::str::from_utf8(bytes)
        .map_err(|_| "Legacy settings must be UTF-8")?
        .trim_start_matches('\u{feff}');
    let mut entries = BTreeMap::new();
    let mut group = String::new();
    let mut repeated_keys = 0;
    for (index, line) in text.lines().enumerate() {
        if index >= 4096 || line.len() > 8192 {
            return Err("Legacy settings exceed the line/count limits".into());
        }
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if line.chars().any(|c| c.is_control() && c != '\t') {
            return Err(format!("Invalid control character on line {}", index + 1));
        }
        if line.starts_with('[') {
            let name = line
                .strip_prefix('[')
                .and_then(|l| l.strip_suffix(']'))
                .filter(|n| valid_name(n) && !n.contains(['[', ']']))
                .ok_or_else(|| format!("Invalid group on line {}", index + 1))?;
            group = name.into();
            continue;
        }
        let (key, value) = line
            .split_once('=')
            .filter(|_| !group.is_empty())
            .ok_or_else(|| format!("Expected a grouped key=value on line {}", index + 1))?;
        let key = key.trim();
        if !valid_name(key) {
            return Err(format!("Invalid key on line {}", index + 1));
        }
        if entries
            .insert((group.clone(), key.to_owned()), value.trim().to_owned())
            .is_some()
        {
            repeated_keys += 1;
        }
        if entries.len() > 1024 {
            return Err("Legacy settings exceed 1024 entries".into());
        }
    }
    let mut settings = base.clone();
    let mut colors = base.theme.palette()?.colors;
    let mut has_colors = false;
    let mut imported = Vec::new();
    let mut skipped = Vec::new();
    let module_keys = [
        ("show_cpu", Module::Cpu),
        ("show_memory", Module::Memory),
        ("show_network", Module::Network),
        ("show_disk", Module::Disk),
        ("show_gpu", Module::Gpu),
        ("show_temperature", Module::Temperature),
        ("show_battery", Module::Battery),
        ("show_aitoken", Module::Ai),
        ("show_process", Module::Processes),
        ("show_tpu", Module::Tpu),
    ];
    let color_keys = [
        "background",
        "graph_bg",
        "graph_fg1",
        "graph_fg2",
        "graph_fg3",
        "border",
        "text",
    ];
    let style_keys = [
        ("cpu_style", Module::Cpu),
        ("memory_style", Module::Memory),
        ("network_style", Module::Network),
        ("disk_style", Module::Disk),
        ("gpu_style", Module::Gpu),
        ("battery_style", Module::Battery),
        ("temperature_style", Module::Temperature),
        ("aitoken_style", Module::Ai),
        ("tpu_style", Module::Tpu),
    ];
    let graph_colors = [
        ("memory_bg", Module::Memory, 0),
        ("memory_fg1", Module::Memory, 1),
        ("memory_fg2", Module::Memory, 2),
        ("memory_fg3", Module::Memory, 3),
        ("network_bg", Module::Network, 0),
        ("network_fg1", Module::Network, 1),
        ("network_fg2", Module::Network, 2),
        ("disk_bg", Module::Disk, 0),
        ("disk_fg1", Module::Disk, 1),
        ("disk_fg2", Module::Disk, 2),
        ("aitoken_bg", Module::Ai, 0),
        ("aitoken_fg1", Module::Ai, 1),
        ("aitoken_fg2", Module::Ai, 2),
    ];
    for ((group, key), value) in &entries {
        let label = format!("[{group}] {key}");
        if group == "Modules"
            && let Some((_, module)) = module_keys.iter().find(|(k, _)| k == key)
        {
            let visible = match value.as_str() {
                "true" => true,
                "false" => false,
                _ => return Err(format!("{label}: expected true or false")),
            };
            settings
                .modules
                .iter_mut()
                .find(|m| m.id == *module)
                .expect("Validated module set")
                .visible = visible;
            imported.push(format!("{label} = {visible}"));
        } else if group == "Display" && key == "layout_orientation" {
            settings.layout = match value.parse::<i32>() {
                Ok(0) => Layout::Vertical,
                Ok(1) => Layout::Horizontal,
                _ => return Err(format!("{label}: expected 0 (vertical) or 1 (horizontal)")),
            };
            imported.push(format!("{label} = {:?}", settings.layout));
        } else if group == "Display" && key == "show_activity_bars" {
            settings.activity_bars.visible = match value.as_str() {
                "true" => true,
                "false" => false,
                _ => return Err(format!("{label}: expected true or false")),
            };
            imported.push(format!("{label} = {}", settings.activity_bars.visible));
        } else if group == "Display" && key == "activity_bar_style" {
            settings.activity_bars.style = *value
                .parse::<usize>()
                .ok()
                .and_then(|n| GraphStyle::ALL.get(n))
                .ok_or_else(|| format!("{label}: expected an activity bar style from 0 to 3"))?;
            imported.push(format!("{label} = {}", settings.activity_bars.style.name()));
        } else if group == "Colors" && key == "activity_bar" {
            settings.activity_bars.color =
                color(&unescape(value).map_err(|e| format!("{label}: {e}"))?)
                    .map_err(|e| format!("{label}: {e}"))?;
            imported.push(format!("{label} (activity bar color)"));
        } else if group == "Temperature" && key == "units" {
            settings.temperature_units = match value.parse::<i32>() {
                Ok(0) => Units::Celsius,
                Ok(1) => Units::Fahrenheit,
                _ => return Err(format!("{label}: expected 0 (Celsius) or 1 (Fahrenheit)")),
            };
            imported.push(format!("{label} = {:?}", settings.temperature_units));
        } else if group == "GraphStyles"
            && let Some((_, id)) = style_keys.iter().find(|(name, _)| name == key)
        {
            let style = value
                .parse::<usize>()
                .ok()
                .and_then(|n| GraphStyle::ALL.get(n))
                .ok_or_else(|| format!("{label}: expected a graph style from 0 to 3"))?;
            settings
                .modules
                .iter_mut()
                .find(|m| m.id == *id)
                .expect("Validated module set")
                .style = *style;
            imported.push(format!("{label} = {}", style.name()));
        } else if group == "Colors"
            && let Some((_, id, index)) = graph_colors.iter().find(|(name, _, _)| name == key)
        {
            let rgba = color(&unescape(value).map_err(|e| format!("{label}: {e}"))?)
                .map_err(|e| format!("{label}: {e}"))?;
            settings
                .modules
                .iter_mut()
                .find(|m| m.id == *id)
                .expect("Validated module set")
                .colors
                .set(*index, Some(rgba))?;
            imported.push(format!("{label} ({} override)", id.title()));
        } else if group == "Colors"
            && let Some(index) = color_keys.iter().position(|k| k == key)
        {
            colors[index] = color(&unescape(value).map_err(|e| format!("{label}: {e}"))?)
                .map_err(|e| format!("{label}: {e}"))?;
            has_colors = true;
            let c = colors[index];
            imported.push(format!(
                "{label} = rgba({:.3},{:.3},{:.3},{:.6})",
                c[0] * 255.,
                c[1] * 255.,
                c[2] * 255.,
                c[3]
            ));
        } else {
            skipped.push(label);
        }
    }
    if imported.is_empty() {
        return Err("No supported legacy visibility, color, layout, graph-style, activity-bar or temperature-unit entries found".into());
    }
    if has_colors {
        let name = entries
            .get(&("Appearance".to_owned(), "theme".to_owned()))
            .map(|v| unescape(v))
            .transpose()?;
        let name = name.as_deref().unwrap_or("").trim();
        if name.chars().any(char::is_control) {
            return Err("[Appearance] theme: invalid control character".into());
        }
        let name = if name.is_empty() {
            "Imported Linux".into()
        } else {
            format!(
                "Imported Linux · {}",
                name.chars().take(63).collect::<String>().trim_end()
            )
        };
        if entries.contains_key(&("Appearance".to_owned(), "theme".to_owned())) {
            skipped.retain(|s| s != "[Appearance] theme");
            imported.push("[Appearance] theme (label only; colors define the palette)".into());
        }
        settings.theme = ThemeChoice::Custom {
            theme: Box::new(ThemeDocument {
                format: "xrg-ng-theme".into(),
                version: 1,
                name,
                colors,
            }),
        };
    }
    settings.validate()?;
    Ok(Import {
        settings,
        imported,
        skipped,
        repeated_keys,
    })
}
fn valid_name(name: &str) -> bool {
    !name.is_empty() && name.len() <= 128 && !name.chars().any(char::is_control)
}
fn unescape(text: &str) -> Result<String, String> {
    let mut result = String::new();
    let mut chars = text.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            result.push(c);
            continue;
        }
        result.push(match chars.next() {
            Some('s') => ' ',
            Some('n') => '\n',
            Some('r') => '\r',
            Some('t') => '\t',
            Some('\\') => '\\',
            _ => return Err("Invalid key-file string escape".into()),
        });
    }
    Ok(result)
}
fn color(text: &str) -> Result<[f64; 4], String> {
    let text = text.trim();
    if let Some(hex) = text.strip_prefix('#') {
        if !matches!(hex.len(), 3 | 4 | 6 | 8) || !hex.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err("Invalid hexadecimal color".into());
        }
        let mut result = [1.; 4];
        let step = if hex.len() <= 4 { 1 } else { 2 };
        for (index, start) in (0..hex.len()).step_by(step).enumerate() {
            let value =
                u8::from_str_radix(&hex[start..start + step], 16).map_err(|_| "Invalid color")?;
            result[index] = f64::from(value) * if step == 1 { 17. } else { 1. } / 255.;
        }
        return Ok(result);
    }
    let (body, count) =
        if let Some(body) = text.strip_prefix("rgba(").and_then(|s| s.strip_suffix(')')) {
            (body, 4)
        } else if let Some(body) = text.strip_prefix("rgb(").and_then(|s| s.strip_suffix(')')) {
            (body, 3)
        } else {
            return Err("Use rgba(R,G,B,A), rgb(R,G,B), or a hexadecimal RGB/RGBA color".into());
        };
    let parts: Vec<_> = body.split(',').collect();
    if parts.len() != count {
        return Err("Invalid color component count".into());
    }
    let mut result = [1.; 4];
    for (index, part) in parts.iter().enumerate() {
        let n = part
            .trim()
            .parse::<f64>()
            .map_err(|_| "Invalid color component")?;
        let max = if index < 3 { 255. } else { 1. };
        if !n.is_finite() || !(0. ..=max).contains(&n) {
            return Err("Color components out of range".into());
        }
        result[index] = n / max;
    }
    Ok(result)
}
