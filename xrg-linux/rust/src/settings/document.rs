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

/// Why a value was not stored. Only `InvalidDocument` says the caller should
/// fall back to a fresh document: every other refusal is a request or
/// transport problem the same document can be asked about again.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum SetError {
    /// The document bytes are not a loadable settings document.
    InvalidDocument,
    /// The id or the value exceeds what the settings ABI accepts; the
    /// document itself is fine.
    RequestTooLarge,
    /// The id or the value could not be parsed — invalid UTF-8, malformed
    /// JSON, or nesting past the core parser's depth limit; the document
    /// itself is fine.
    UnparsableRequest,
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
    /// The request could not be encoded, or the pinned shared core answered
    /// in a shape it never produces: a binding problem, not a document one.
    Transport,
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
#[derive(Debug, Clone, Deserialize)]
pub struct Catalog {
    pub sections: Vec<String>,
    pub entries: Vec<CatalogEntry>,
}

/// One catalog entry; `default` carries the typed default value and `shown`
/// is false only for persisted state the settings windows never render.
#[derive(Debug, Clone, Deserialize)]
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
#[derive(Debug, Clone, Deserialize)]
pub struct CatalogRange {
    pub min: f64,
    pub max: f64,
    pub step: Option<f64>,
    pub unit: Option<String>,
}

/// One selectable value of a choice or segmented control.
#[derive(Debug, Clone, Deserialize)]
pub struct CatalogOption {
    pub value: serde_json::Value,
    pub label: String,
}

/// Another entry, and the value it must hold, for this control to be enabled.
#[derive(Debug, Clone, Deserialize)]
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
            "request-too-large" => Self::RequestTooLarge,
            "unparsable-request" => Self::UnparsableRequest,
            "wrong-type" => Self::WrongType,
            "out-of-range" => Self::OutOfRange {
                min: wire.min.unwrap_or_default(),
                max: wire.max.unwrap_or_default(),
            },
            "not-an-option" => Self::NotAnOption,
            "dependency-not-met" => Self::DependencyNotMet,
            // A kind outside the pinned ABI's set: the core, not the request.
            _ => Self::Transport,
        }
    }
}

/// Why a settings ABI call did not answer with a response.
enum CallError {
    /// The core refused the request (-1): for the entry points that take a
    /// document, that document does not load.
    Rejected,
    /// The core broke the buffer contract the pinned ABI never breaks.
    Transport(&'static str),
}

/// One settings ABI call that answers UTF-8 JSON into a caller buffer,
/// retried with the size the core reports when the buffer is too small.
fn json_call(call: impl Fn(*mut u8, u32, &mut u32) -> i32) -> Result<Vec<u8>, CallError> {
    let mut output = vec![0u8; 8192];
    loop {
        let mut needed = 0;
        let written = call(output.as_mut_ptr(), output.len() as u32, &mut needed);
        if written == -2 {
            let reported = needed as usize;
            if reported <= output.len() {
                return Err(CallError::Transport(
                    "the shared core reported a size no larger buffer satisfies",
                ));
            }
            output.resize(reported, 0);
            continue;
        }
        if written < 0 {
            return Err(CallError::Rejected);
        }
        let count = written as usize;
        if count > output.len() {
            return Err(CallError::Transport(
                "the shared core wrote past the buffer it was given",
            ));
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

/// The unreadable result for a problem found on the Rust side of the ABI:
/// the caller runs on defaults and must keep the file untouched.
fn unreadable(problem: &str) -> Loaded {
    Loaded::Unreadable {
        diagnostic: Diagnostic {
            id: None,
            problem: problem.to_owned(),
        },
    }
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
/// document-level problem that makes the file unreadable. Loading never
/// panics: input the ABI refuses, and any ABI failure, are unreadable
/// results, so the file is kept and the defaults are used.
pub fn load(bytes: &[u8]) -> Loaded {
    // The header's documented input bound, mirrored so an oversized file
    // never crosses the ABI: it is unreadable, not wrong.
    let length = match u32::try_from(bytes.len()) {
        Ok(length) if bytes.len() <= INPUT_LIMIT => length,
        _ => {
            return unreadable("the settings file exceeds the 1 MiB the settings ABI accepts");
        }
    };
    let response = match json_call(|out, cap, needed| unsafe {
        xrg_settings_load(bytes.as_ptr(), length, out, cap, needed)
    }) {
        Ok(response) => response,
        Err(CallError::Rejected) => return unreadable("the shared core refused the settings file"),
        Err(CallError::Transport(problem)) => return unreadable(problem),
    };
    match loaded_from(&response) {
        Ok(loaded) => loaded,
        Err(problem) => unreadable(&problem),
    }
}

/// Store one value in a document, enforcing the entry's rules: the new
/// canonical bytes, or the refusal. Only `InvalidDocument` means the
/// document bytes do not load; the request and transport failures are their
/// own kinds, so a caller never mistakes a refused request for a file it
/// must replace.
pub fn set(doc: &[u8], id: &str, value: &serde_json::Value) -> Result<Vec<u8>, SetError> {
    // The document is the document: one too large to cross is as unusable
    // as one that does not load, exactly as `load` reports it. The request
    // parts are requests: too large to cross is a request problem.
    let doc_len = u32::try_from(doc.len()).map_err(|_| SetError::InvalidDocument)?;
    let id_len = u32::try_from(id.len()).map_err(|_| SetError::RequestTooLarge)?;
    let value_json = serde_json::to_vec(value).map_err(|_| SetError::Transport)?;
    let value_len = u32::try_from(value_json.len()).map_err(|_| SetError::RequestTooLarge)?;
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
    .map_err(|failure| match failure {
        CallError::Rejected => SetError::InvalidDocument,
        CallError::Transport(_) => SetError::Transport,
    })?;
    let wire: Wire = serde_json::from_slice(&response).map_err(|_| SetError::Transport)?;
    if let Some(error) = wire.error {
        return Err(error.into());
    }
    wire.document
        .map(String::into_bytes)
        .ok_or(SetError::Transport)
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
    .map_err(|failure| match failure {
        CallError::Rejected => "the settings document did not load".to_owned(),
        CallError::Transport(problem) => problem.to_owned(),
    })?;
    let wire: Wire = serde_json::from_slice(&response).map_err(|error| error.to_string())?;
    if let Some(error) = wire.error {
        // A refusal here is about the request, most plainly a section name
        // that is not UTF-8; it never means the document is at fault.
        return Err(match error.kind.as_str() {
            "unparsable-request" => "the section name could not be parsed".to_owned(),
            problem => format!("the shared core refused the reset: {problem}"),
        });
    }
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
    .map_err(|failure| match failure {
        CallError::Rejected => "the version-40 input is not a JSON object".to_owned(),
        CallError::Transport(problem) => problem.to_owned(),
    })?;
    loaded_from(&response)
}

/// The version-40-shaped view of a document, deserialised straight into the
/// Rust serde model. The view the core renders is authoritative: nothing
/// re-validates it or bounds its size, so every core-valid document loads
/// here, whatever the legacy model's own file limit was. (`Settings::parse`,
/// with its 128 KiB bound, its old-format upgrade chain and its validator,
/// belongs to the old local-file upgrade path, never to the core's output.)
pub fn linux_view(doc: &[u8]) -> Result<Settings, String> {
    let length =
        u32::try_from(doc.len()).map_err(|_| "the settings document is too large".to_owned())?;
    let view = json_call(|out, cap, needed| unsafe {
        xrg_settings_linux_view(doc.as_ptr(), length, out, cap, needed)
    })
    .map_err(|failure| match failure {
        CallError::Rejected => "the settings document did not load".to_owned(),
        CallError::Transport(problem) => problem.to_owned(),
    })?;
    let mut settings: Settings = serde_json::from_slice(&view).map_err(|error| {
        format!("the shared core's Linux view is not the model's shape: {error}")
    })?;
    // The core's version-40 view names no Stocks graph yet (ruling R2); it
    // joins hidden here, so every view the app holds is a complete module
    // list and the model's own lookup never misses.
    settings.ensure_modules();
    Ok(settings)
}
