// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Decode legacy XTF data without instantiating archived Objective-C classes.
use super::ThemeDocument;
use plist::{
    Dictionary, Value,
    stream::{Event, Reader},
};
use std::io::Cursor;
const NAMES: [&str; 7] = [
    "background",
    "graphBG",
    "graphFG1",
    "graphFG2",
    "graphFG3",
    "border",
    "text",
];

// The streaming API is intentionally pinned to plist ~1.10.3. Ignore binary
// collection-size hints and bound nesting/events/payload before building values.
struct Decoder<'a> {
    reader: Reader<Cursor<&'a [u8]>>,
    events: usize,
    payload: usize,
}
impl Decoder<'_> {
    fn next(&mut self) -> Result<Option<Event<'static>>, String> {
        self.events += 1;
        if self.events > 2048 {
            return Err("XTF property-list event limit exceeded".into());
        }
        let event = self
            .reader
            .next()
            .transpose()
            .map_err(|_| "Invalid XTF property list")?;
        self.payload += match &event {
            Some(Event::Data(v)) => v.len(),
            Some(Event::String(v)) => v.len(),
            _ => 0,
        };
        if self.payload > 256 * 1024 {
            return Err("XTF expanded payload limit exceeded".into());
        }
        Ok(event)
    }
    fn value(&mut self, event: Event<'static>, depth: usize) -> Result<Value, String> {
        if depth > 12 {
            return Err("XTF nesting limit exceeded".into());
        }
        Ok(match event {
            Event::StartArray(_) => {
                let mut values = Vec::new();
                loop {
                    match self.next()?.ok_or("Incomplete XTF array")? {
                        Event::EndCollection => break,
                        event => values.push(self.value(event, depth + 1)?),
                    }
                }
                Value::Array(values)
            }
            Event::StartDictionary(_) => {
                let mut values = Dictionary::new();
                loop {
                    let key = match self.next()?.ok_or("Incomplete XTF dictionary")? {
                        Event::EndCollection => break,
                        Event::String(key) if key.len() <= 128 => key.into_owned(),
                        _ => return Err("Invalid XTF dictionary key".into()),
                    };
                    if values.contains_key(&key) {
                        return Err("Duplicate XTF dictionary key".into());
                    }
                    let event = self.next()?.ok_or("Missing XTF dictionary value")?;
                    values.insert(key, self.value(event, depth + 1)?);
                }
                Value::Dictionary(values)
            }
            Event::Boolean(v) => Value::Boolean(v),
            Event::Data(v) => Value::Data(v.into_owned()),
            Event::Integer(v) => Value::Integer(v),
            Event::Real(v) => Value::Real(v),
            Event::String(v) => Value::String(v.into_owned()),
            Event::Uid(v) => Value::Uid(v),
            _ => return Err("Unsupported XTF property-list value".into()),
        })
    }
}
fn decode(bytes: &[u8]) -> Result<Value, String> {
    if bytes.len() > super::LIMIT {
        return Err("XTF property list exceeds 128 KiB".into());
    }
    let mut decoder = Decoder {
        reader: Reader::new(Cursor::new(bytes)),
        events: 0,
        payload: 0,
    };
    let event = decoder.next()?.ok_or("Empty XTF property list")?;
    let value = decoder.value(event, 0)?;
    if decoder.next()?.is_some() {
        return Err("Trailing XTF property-list values".into());
    }
    Ok(value)
}
fn dictionary(value: &Value) -> Result<&Dictionary, String> {
    value
        .as_dictionary()
        .ok_or_else(|| "Expected an XTF dictionary".into())
}
fn keys(value: &Dictionary, allowed: &[&str]) -> Result<(), String> {
    if value.keys().any(|key| !allowed.contains(&key.as_str())) {
        return Err("Unsupported XTF color/archive fields".into());
    }
    Ok(())
}
fn object<'a>(value: Option<&Value>, objects: &'a [Value]) -> Result<&'a Value, String> {
    let index = value
        .and_then(Value::as_uid)
        .and_then(|v| usize::try_from(v.get()).ok())
        .filter(|v| *v != 0)
        .ok_or("Invalid XTF archive reference")?;
    objects
        .get(index)
        .ok_or_else(|| "XTF archive reference out of range".into())
}
fn components(value: Option<&Value>, count: usize) -> Result<Vec<f64>, String> {
    let bytes = value
        .and_then(Value::as_data)
        .ok_or("Missing XTF color components")?;
    if bytes.len() > 256 {
        return Err("XTF color components too long".into());
    }
    let text = std::str::from_utf8(bytes.strip_suffix(&[0]).unwrap_or(bytes))
        .map_err(|_| "Invalid XTF color component encoding")?;
    let values: Vec<_> = text
        .split_ascii_whitespace()
        .map(|v| v.parse::<f64>())
        .collect::<Result<_, _>>()
        .map_err(|_| "Invalid XTF color components")?;
    if !matches!(values.len(), n if n == count || n == count + 1)
        || values
            .iter()
            .any(|v| !v.is_finite() || !(0. ..=1.).contains(v))
    {
        return Err("XTF color components must be finite and between 0 and 1".into());
    }
    Ok(values)
}
fn class(value: &Value, objects: &[Value], name: &str) -> Result<(), String> {
    let value = dictionary(value)?;
    let class = dictionary(object(value.get("$class"), objects)?)?;
    keys(class, &["$classname", "$classes"])?;
    let classes = class
        .get("$classes")
        .and_then(Value::as_array)
        .ok_or("Missing XTF class hierarchy")?;
    if class.get("$classname").and_then(Value::as_string) != Some(name)
        || classes.len() != 2
        || classes[0].as_string() != Some(name)
        || classes[1].as_string() != Some("NSObject")
    {
        return Err(format!("Only plain {name} archives are supported"));
    }
    Ok(())
}
fn srgb(root: &Dictionary, objects: &[Value]) -> Result<[f64; 3], String> {
    keys(
        root,
        &[
            "$class",
            "NSColorSpace",
            "NSRGB",
            "NSComponents",
            "NSCustomColorSpace",
            "NSLinearExposure",
        ],
    )?;
    if root
        .get("NSColorSpace")
        .and_then(Value::as_unsigned_integer)
        != Some(1)
    {
        return Err("Unsupported XTF custom color space".into());
    }
    let space = object(root.get("NSCustomColorSpace"), objects)?;
    class(space, objects, "NSColorSpace")?;
    let space = dictionary(space)?;
    keys(space, &["$class", "NSID", "NSICC"])?;
    if space.get("NSID").and_then(Value::as_unsigned_integer) != Some(7) {
        return Err("Unsupported XTF custom color space; only standard sRGB is supported".into());
    }
    if let Some(profile) = space.get("NSICC") {
        let profile = object(Some(profile), objects)?
            .as_data()
            .ok_or("Invalid XTF ICC profile")?;
        // AppKit's sRGB IEC61966-2.1 profile, verified from a real archive.
        // NSID alone must not override an arbitrary embedded ICC profile.
        if profile.len() != 3144
            || blake3::hash(profile).to_hex().as_str()
                != "584d7f5ba6f0afe67a1bba04b2a12d5e336e9721b198d6c98ee20b1a6e5759fc"
        {
            return Err(
                "Unsupported XTF ICC profile; export standard sRGB without a custom profile".into(),
            );
        }
    }
    if let Some(exposure) = root.get("NSLinearExposure")
        && exposure.as_data() != Some(b"0".as_slice())
    {
        return Err("Nonzero or malformed XTF linear exposure is unsupported".into());
    }
    // NSRGB is a legacy calibrated fallback. AppKit's archived values differ
    // from the original sRGB channels, which NSComponents preserves.
    let v = components(root.get("NSComponents"), 3)?;
    Ok([v[0], v[1], v[2]])
}
fn color(bytes: &[u8]) -> Result<[f64; 3], String> {
    if bytes.len() > 64 * 1024 {
        return Err("XTF color archive exceeds 64 KiB".into());
    }
    let archive = decode(bytes)?;
    let archive = dictionary(&archive)?;
    keys(archive, &["$archiver", "$version", "$top", "$objects"])?;
    if archive.get("$archiver").and_then(Value::as_string) != Some("NSKeyedArchiver")
        || archive.get("$version").and_then(Value::as_unsigned_integer) != Some(100_000)
    {
        return Err("Unsupported XTF color archive".into());
    }
    let objects = archive
        .get("$objects")
        .and_then(Value::as_array)
        .filter(|v| v.len() <= 64 && v.first().and_then(Value::as_string) == Some("$null"))
        .ok_or("Invalid XTF archive object table")?;
    let top = dictionary(archive.get("$top").ok_or("Missing XTF archive root")?)?;
    keys(top, &["root"])?;
    let root = object(top.get("root"), objects)?;
    class(root, objects, "NSColor")?;
    let root = dictionary(root)?;
    if root.contains_key("NSCustomColorSpace") || root.contains_key("NSComponents") {
        return srgb(root, objects);
    }
    keys(root, &["$class", "NSColorSpace", "NSRGB", "NSWhite"])?;
    match root
        .get("NSColorSpace")
        .and_then(Value::as_unsigned_integer)
    {
        Some(1 | 2) if !root.contains_key("NSWhite") => {
            let v = components(root.get("NSRGB"), 3)?;
            Ok([v[0], v[1], v[2]])
        }
        Some(3 | 4) if !root.contains_key("NSRGB") => {
            let v = components(root.get("NSWhite"), 1)?;
            Ok([v[0]; 3])
        }
        _ => Err("Unsupported XTF color space; use RGB or grayscale".into()),
    }
}
pub(super) fn parse(bytes: &[u8]) -> Result<ThemeDocument, String> {
    let value = decode(bytes)?;
    let fields = dictionary(&value)?;
    // The macOS format consists of seven color archives and seven separate
    // transparency numbers. Separate transparency overrides archived alpha.
    let mut colors = [[0.; 4]; 7];
    for (index, name) in NAMES.iter().enumerate() {
        let read = || -> Result<[f64; 4], String> {
            let bytes = fields
                .get(&format!("{name}Color"))
                .and_then(Value::as_data)
                .ok_or("Missing XTF color archive")?;
            let alpha = fields
                .get(&format!("{name}Transparency"))
                .and_then(|v| match v {
                    Value::Real(v) => Some(*v),
                    Value::Integer(v) => v.as_signed().map(|v| v as f64),
                    _ => None,
                })
                .filter(|v| v.is_finite() && (0. ..=1.).contains(v))
                .ok_or("XTF transparency must be a number between 0 and 1")?;
            let [r, g, b] = color(bytes)?;
            Ok([r, g, b, alpha])
        };
        colors[index] = read().map_err(|e| format!("{name}: {e}"))?;
    }
    let theme = ThemeDocument {
        format: "xrg-ng-theme".into(),
        version: 1,
        name: "Imported macOS".into(),
        colors,
    };
    theme.validate()?;
    Ok(theme)
}
