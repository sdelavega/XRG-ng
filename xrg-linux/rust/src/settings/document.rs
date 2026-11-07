// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! The unified settings document, read and written through the shared core's
//! C ABI. Linux keeps no model of its own: the canonical bytes the core
//! returns are the bytes that are written, and the typed values the platform
//! needs come from the version-40 view the core renders.
//!
//! The wire shapes are the additive ABI v2 entry points declared in
//! `Shared/include/xrg_shared.h`; every response is UTF-8 JSON in a
//! caller-provided buffer, retried with the size the core reports when the
//! buffer is too small.
use crate::settings::Settings;
use serde::Deserialize;

/// Settings documents and version-40 files are bounded like the core's other
/// JSON inputs; ids and sections are catalog names.
const INPUT_LIMIT: usize = 1_048_576;

unsafe extern "C" {
    fn xrg_settings_catalog(platform: u32, out: *mut u8, cap: u32, needed: *mut u32) -> i32;
    fn xrg_settings_load(doc: *const u8, len: u32, out: *mut u8, cap: u32, needed: *mut u32)
    -> i32;
    fn xrg_settings_set(
        doc: *const u8,
        len: u32,
        id: *const u8,
        id_len: u32,
        value: *const u8,
        value_len: u32,
        out: *mut u8,
        cap: u32,
        needed: *mut u32,
    ) -> i32;
    fn xrg_settings_reset_section(
        doc: *const u8,
        len: u32,
        section: *const u8,
        section_len: u32,
        out: *mut u8,
        cap: u32,
        needed: *mut u32,
    ) -> i32;
    fn xrg_settings_migrate_linux_v40(
        v40: *const u8,
        len: u32,
        out: *mut u8,
        cap: u32,
        needed: *mut u32,
    ) -> i32;
    fn xrg_settings_linux_view(
        doc: *const u8,
        len: u32,
        out: *mut u8,
        cap: u32,
        needed: *mut u32,
    ) -> i32;
}

/// One problem the core reported while loading or migrating. `id` names the
/// settings key the problem is about; document-level problems carry none.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Diagnostic {
    pub id: Option<String>,
    pub problem: String,
}

/// Why the core refused to store a value, mirroring the core's refusals.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum SetError {
    /// The document bytes are not a loadable settings document.
    InvalidDocument,
    /// The id is not in the catalog.
    UnknownId,
    /// The value cannot have this control's shape.
    WrongType,
    /// A number or duration outside its bounds, carrying the bounds.
    OutOfRange { min: f64, max: f64 },
    /// A choice value outside its options, or an order list that is not the
    /// default ids rearranged.
    NotAnOption,
    /// The entry's `depends` requirement does not hold.
    DependencyNotMet,
}

/// The result of loading or migrating a document, mirroring the core's load:
/// an unreadable document means the caller runs on defaults and must not
/// overwrite the file without the user's confirmation.
#[derive(Debug, PartialEq)]
pub enum Loaded {
    /// The canonical document bytes, plus the load's diagnostics.
    Ok {
        document: Vec<u8>,
        diagnostics: Vec<Diagnostic>,
    },
    /// The document-level problem that made the file unreadable.
    Unreadable { diagnostic: Diagnostic },
}

/// The settings catalog for Linux: the sections in sidebar order and, in
/// display order, the entries the platform renders.
#[derive(Debug, Deserialize)]
pub struct Catalog {
    pub sections: Vec<String>,
    pub entries: Vec<CatalogEntry>,
}

/// One catalog entry; `default` carries the typed default value and `shown`
/// is false only for persisted state the settings windows never render.
#[derive(Debug, Deserialize)]
pub struct CatalogEntry {
    pub id: String,
    pub section: String,
    pub group: String,
    pub label: String,
    pub help: Option<String>,
    pub control: String,
    pub default: serde_json::Value,
    pub range: Option<CatalogRange>,
    pub options: Option<Vec<CatalogOption>>,
    pub platforms: Vec<String>,
    #[serde(default = "shown_by_default")]
    pub shown: bool,
    pub depends: Option<CatalogDependency>,
    /// The runtime source kind whose options the platform supplies.
    pub source: Option<String>,
}

fn shown_by_default() -> bool {
    true
}

/// Bounds for number and duration controls.
#[derive(Debug, Deserialize)]
pub struct CatalogRange {
    pub min: f64,
    pub max: f64,
    pub step: Option<f64>,
    pub unit: Option<String>,
}

/// One selectable value of a choice or segmented control.
#[derive(Debug, Deserialize)]
pub struct CatalogOption {
    pub value: serde_json::Value,
    pub label: String,
}

/// Another entry, and the value it must hold, for this control to be enabled.
#[derive(Debug, Deserialize)]
pub struct CatalogDependency {
    pub id: String,
    pub equals: serde_json::Value,
}

/// Every response the settings entry points answer with; the fields a call
/// does not produce stay at their defaults.
#[derive(Debug, Deserialize)]
struct Wire {
    document: Option<String>,
    #[serde(default)]
    diagnostics: Vec<Diagnostic>,
    #[serde(default)]
    unreadable: bool,
    #[serde(default)]
    error: Option<WireError>,
}

/// One core refusal: the kind, with the bounds an out-of-range value carries.
#[derive(Debug, Deserialize)]
struct WireError {
    kind: String,
    min: Option<f64>,
    max: Option<f64>,
}

impl From<WireError> for SetError {
    fn from(wire: WireError) -> Self {
        match wire.kind.as_str() {
            "unknown-id" => Self::UnknownId,
            "wrong-type" => Self::WrongType,
            "out-of-range" => Self::OutOfRange {
                min: wire.min.unwrap_or_default(),
                max: wire.max.unwrap_or_default(),
            },
            "not-an-option" => Self::NotAnOption,
            "dependency-not-met" => Self::DependencyNotMet,
            // The ABI version pin (shared::check_abi) keeps the kind set closed.
            _ => unreachable!("the shared core reported an unknown settings refusal"),
        }
    }
}

/// One settings ABI call that answers UTF-8 JSON into a caller buffer,
/// retried with the size the core reports when the buffer is too small.
fn json_call(call: impl Fn(*mut u8, u32, &mut u32) -> i32) -> Result<Vec<u8>, String> {
    let mut output = vec![0u8; 8192];
    loop {
        let mut needed = 0;
        let written = call(output.as_mut_ptr(), output.len() as u32, &mut needed);
        if written == -2 {
            let reported = needed as usize;
            if reported <= output.len() {
                return Err("the shared core reported a size no larger buffer satisfies".into());
            }
            output.resize(reported, 0);
            continue;
        }
        if written < 0 {
            return Err("the shared core rejected the settings request".into());
        }
        let count = written as usize;
        if count > output.len() {
            return Err("the shared core wrote past the buffer it was given".into());
        }
        output.truncate(count);
        return Ok(output);
    }
}

/// The `Loaded` a load or migration response carries.
fn loaded_from(response: &[u8]) -> Result<Loaded, String> {
    let wire: Wire = serde_json::from_slice(response).map_err(|error| error.to_string())?;
    if wire.unreadable {
        let diagnostic = wire.diagnostics.into_iter().next().unwrap_or(Diagnostic {
            id: None,
            problem: "malformed".into(),
        });
        return Ok(Loaded::Unreadable { diagnostic });
    }
    let document = wire
        .document
        .ok_or_else(|| "the shared core omitted a readable document".to_owned())?;
    Ok(Loaded::Ok {
        document: document.into_bytes(),
        diagnostics: wire.diagnostics,
    })
}

/// The settings catalog for Linux.
pub fn catalog() -> Result<Catalog, String> {
    // platform 1 is Linux in the shared ABI.
    let response =
        json_call(|out, cap, needed| unsafe { xrg_settings_catalog(1, out, cap, needed) })
            .map_err(|_| "the shared core did not provide the settings catalog".to_owned())?;
    serde_json::from_slice(&response).map_err(|error| error.to_string())
}

/// Load a settings document: the canonical bytes and its diagnostics, or the
/// document-level problem that makes the file unreadable.
pub fn load(bytes: &[u8]) -> Loaded {
    assert!(
        bytes.len() <= INPUT_LIMIT,
        "settings documents are bounded to 1 MiB"
    );
    let length = u32::try_from(bytes.len()).expect("bounded by the input limit");
    let response = json_call(|out, cap, needed| unsafe {
        xrg_settings_load(bytes.as_ptr(), length, out, cap, needed)
    })
    .expect("the shared core refused a bounded settings document");
    loaded_from(&response).expect("the shared core answered without a document")
}

/// Store one value in a document, enforcing the entry's rules: the new
/// canonical bytes, or the core's refusal.
pub fn set(doc: &[u8], id: &str, value: &serde_json::Value) -> Result<Vec<u8>, SetError> {
    let doc_len = u32::try_from(doc.len()).map_err(|_| SetError::InvalidDocument)?;
    let id_len = u32::try_from(id.len()).map_err(|_| SetError::InvalidDocument)?;
    let value_json = serde_json::to_vec(value).expect("a JSON value always serialises");
    let value_len = u32::try_from(value_json.len()).map_err(|_| SetError::InvalidDocument)?;
    let response = json_call(|out, cap, needed| unsafe {
        xrg_settings_set(
            doc.as_ptr(),
            doc_len,
            id.as_ptr(),
            id_len,
            value_json.as_ptr(),
            value_len,
            out,
            cap,
            needed,
        )
    })
    .map_err(|_| SetError::InvalidDocument)?;
    let wire: Wire = serde_json::from_slice(&response).map_err(|_| SetError::InvalidDocument)?;
    if let Some(error) = wire.error {
        return Err(error.into());
    }
    wire.document
        .map(String::into_bytes)
        .ok_or(SetError::InvalidDocument)
}

/// Restore every entry of one catalog section to its default, in the document
/// the core returns; unknown keys and other sections are untouched.
pub fn reset_section(doc: &[u8], section: &str) -> Result<Vec<u8>, String> {
    let doc_len =
        u32::try_from(doc.len()).map_err(|_| "the settings document is too large".to_owned())?;
    let section_len =
        u32::try_from(section.len()).map_err(|_| "the section name is too large".to_owned())?;
    let response = json_call(|out, cap, needed| unsafe {
        xrg_settings_reset_section(
            doc.as_ptr(),
            doc_len,
            section.as_ptr(),
            section_len,
            out,
            cap,
            needed,
        )
    })
    .map_err(|_| "the settings document did not load".to_owned())?;
    let wire: Wire = serde_json::from_slice(&response).map_err(|error| error.to_string())?;
    wire.document
        .map(String::into_bytes)
        .ok_or_else(|| "the shared core omitted the reset document".into())
}

/// Migrate a version-40 Linux settings file into the unified document.
/// Bytes that are not a JSON object are refused.
pub fn migrate_v40(v40: &[u8]) -> Result<Loaded, String> {
    let length =
        u32::try_from(v40.len()).map_err(|_| "the version-40 file is too large".to_owned())?;
    let response = json_call(|out, cap, needed| unsafe {
        xrg_settings_migrate_linux_v40(v40.as_ptr(), length, out, cap, needed)
    })
    .map_err(|_| "the version-40 input is not a JSON object".to_owned())?;
    loaded_from(&response)
}

/// The version-40-shaped view of a document, deserialised into the Rust
/// model: the shape the platform's own serde `Settings` reads.
pub fn linux_view(doc: &[u8]) -> Result<Settings, String> {
    let length =
        u32::try_from(doc.len()).map_err(|_| "the settings document is too large".to_owned())?;
    let view = json_call(|out, cap, needed| unsafe {
        xrg_settings_linux_view(doc.as_ptr(), length, out, cap, needed)
    })
    .map_err(|_| "the settings document did not load".to_owned())?;
    Settings::parse(&view)
}
