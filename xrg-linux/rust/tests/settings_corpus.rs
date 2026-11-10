// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! The shared settings conformance corpus through the C ABI.
//!
//! The same fixtures the Swift tests pin (`Shared/Tests/Fixtures/settings/`,
//! read from the repository path) are driven through the shared core's
//! settings entry points, so Linux sees exactly the bytes the hand-derived
//! `*.expected.json` files hold: the canonical document, its diagnostics,
//! the version-40 migration and the Linux view. The stock chart parser and
//! URL builder ride along behind the same ABI version.
use std::{
    fs,
    path::{Path, PathBuf},
};
use xrg_ng_linux::{
    settings::{Settings, StockSettings, document},
    shared,
};

// The raw ABI entry points a C caller uses, for the buffer contract checks
// and the request-level refusals no Rust type can express.
unsafe extern "C" {
    fn xrg_settings_load(doc: *const u8, len: u32, out: *mut u8, cap: u32, needed: *mut u32)
    -> i32;
    fn xrg_settings_linux_view(
        doc: *const u8,
        len: u32,
        out: *mut u8,
        cap: u32,
        needed: *mut u32,
    ) -> i32;
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
}

/// The status and decoded body of one raw `xrg_settings_set` call, so the
/// wire itself can be inspected for inputs `serde_json::Value` cannot hold.
fn raw_set(doc: &[u8], id: &[u8], value: &[u8]) -> (i32, Option<serde_json::Value>) {
    let mut needed = 0;
    let mut output = vec![0u8; 8192];
    let status = unsafe {
        xrg_settings_set(
            doc.as_ptr(),
            u32::try_from(doc.len()).expect("the document fits the ABI"),
            id.as_ptr(),
            u32::try_from(id.len()).expect("the id fits the ABI"),
            value.as_ptr(),
            u32::try_from(value.len()).expect("the value fits the ABI"),
            output.as_mut_ptr(),
            output.len() as u32,
            &mut needed,
        )
    };
    if status <= 0 {
        return (status, None);
    }
    (
        status,
        serde_json::from_slice(&output[..status as usize]).ok(),
    )
}

/// The status and decoded body of one raw `xrg_settings_reset_section`
/// call, for section bytes `&str` cannot hold.
fn raw_reset_section(doc: &[u8], section: &[u8]) -> (i32, Option<serde_json::Value>) {
    let mut needed = 0;
    let mut output = vec![0u8; 8192];
    let status = unsafe {
        xrg_settings_reset_section(
            doc.as_ptr(),
            u32::try_from(doc.len()).expect("the document fits the ABI"),
            section.as_ptr(),
            u32::try_from(section.len()).expect("the section fits the ABI"),
            output.as_mut_ptr(),
            output.len() as u32,
            &mut needed,
        )
    };
    if status <= 0 {
        return (status, None);
    }
    (
        status,
        serde_json::from_slice(&output[..status as usize]).ok(),
    )
}

/// The wire kind one response's `error` carries, or None when there is no
/// error object at all.
fn error_kind(response: &serde_json::Value) -> Option<&str> {
    response.get("error")?.get("kind")?.as_str()
}

/// Shared/Tests/Fixtures/settings, the same files the Swift corpus reads.
fn fixtures() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Shared/Tests/Fixtures/settings")
}

/// The `<name>.expected.json` shape: the load's diagnostics plus the exact
/// canonical document bytes, or no document when the input is unreadable.
#[derive(Debug, serde::Deserialize)]
struct Expected {
    diagnostics: Vec<document::Diagnostic>,
    document: Option<String>,
}

/// Every corpus input, mirroring the Swift document test's selection: `.json`
/// files that are not expected outputs and not migration fixtures.
fn corpus_inputs() -> Vec<(String, Vec<u8>)> {
    let mut inputs = Vec::new();
    for entry in fs::read_dir(fixtures()).expect("the settings fixtures are checked out") {
        let path = entry.expect("a readable fixture").path();
        let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        let Some(stem) = name.strip_suffix(".json") else {
            continue;
        };
        if stem.ends_with(".expected")
            || ["macos-0.2.2-", "linux-v40"]
                .iter()
                .any(|prefix| stem.starts_with(prefix))
        {
            continue;
        }
        inputs.push((stem.to_owned(), fs::read(&path).expect("fixture bytes")));
    }
    inputs.sort_by(|a, b| a.0.cmp(&b.0));
    assert!(!inputs.is_empty(), "the settings corpus is missing");
    inputs
}

/// The canonical bytes of the document with every setting at its default.
fn defaults_document() -> Vec<u8> {
    match document::load(br#"{"format": "xrg-ng-settings", "version": 1, "settings": {}}"#) {
        document::Loaded::Ok { document, .. } => document,
        document::Loaded::Unreadable { .. } => panic!("the defaults document must load"),
    }
}

/// The raw Linux view bytes from the ABI, retried with `needed` like a C
/// caller would, proving the byte-level wire contract.
fn raw_linux_view(document: &[u8]) -> Vec<u8> {
    let length = u32::try_from(document.len()).unwrap();
    let mut needed = 0;
    assert_eq!(
        unsafe {
            xrg_settings_linux_view(
                document.as_ptr(),
                length,
                std::ptr::null_mut(),
                0,
                &mut needed,
            )
        },
        -2
    );
    let mut output = vec![0u8; needed as usize];
    let written = unsafe {
        xrg_settings_linux_view(
            document.as_ptr(),
            length,
            output.as_mut_ptr(),
            needed,
            &mut needed,
        )
    };
    assert_eq!(written, needed as i32);
    output
}

#[test]
fn the_conformance_corpus_loads_identically_through_the_abi() {
    shared::check_abi();
    for (name, bytes) in corpus_inputs() {
        let expected: Expected = serde_json::from_slice(
            &fs::read(fixtures().join(format!("{name}.expected.json"))).unwrap(),
        )
        .unwrap();
        match document::load(&bytes) {
            document::Loaded::Ok {
                document,
                diagnostics,
            } => {
                let expected_document = expected
                    .document
                    .unwrap_or_else(|| panic!("{name}: expected an unreadable document"));
                assert_eq!(
                    document,
                    expected_document.as_bytes(),
                    "{name}: canonical bytes differ"
                );
                assert_eq!(
                    diagnostics, expected.diagnostics,
                    "{name}: diagnostics differ"
                );
            }
            document::Loaded::Unreadable { diagnostic } => {
                assert!(
                    expected.document.is_none(),
                    "{name}: expected a readable document"
                );
                assert_eq!(
                    vec![diagnostic],
                    expected.diagnostics,
                    "{name}: diagnostics differ"
                );
            }
        }
    }
}

#[test]
fn an_oversized_settings_file_loads_as_unreadable_without_panicking() {
    shared::check_abi();
    // Exactly 2 MiB: a document that would load (its only extra member is
    // an unknown root key, preserved verbatim) but for the ABI's 1 MiB
    // input bound. Loading must answer "unreadable" — never panic — so the
    // caller runs on defaults and keeps the file untouched.
    let prefix = br#"{"format": "xrg-ng-settings", "padding": ""#;
    let suffix = br#", "settings": {}, "version": 1}"#;
    let mut bytes = prefix.to_vec();
    bytes.extend(std::iter::repeat_n(
        b'a',
        2 * 1024 * 1024 - prefix.len() - suffix.len(),
    ));
    bytes.extend_from_slice(suffix);
    assert_eq!(bytes.len(), 2 * 1024 * 1024);
    match document::load(&bytes) {
        document::Loaded::Unreadable { diagnostic } => assert_eq!(
            diagnostic,
            document::Diagnostic {
                id: None,
                problem: "the settings file exceeds the 1 MiB the settings ABI accepts".into()
            }
        ),
        document::Loaded::Ok { .. } => panic!("an oversized file must not load"),
    }
}

#[test]
fn set_reports_the_catalogs_bounds_and_kinds() {
    let defaults = defaults_document();
    let canonical_defaults = br#"{
  "format": "xrg-ng-settings",
  "settings": {},
  "version": 1
}
"#
    .to_vec();

    // The entry's bounds travel with the refusal, exactly as the core
    // reports them.
    assert_eq!(
        document::set(
            &defaults,
            "general.window.border_width",
            &serde_json::json!(99)
        ),
        Err(document::SetError::OutOfRange {
            min: 1.0,
            max: 16.0
        })
    );
    assert_eq!(
        document::set(&defaults, "graphs.refresh", &serde_json::json!(0.1)),
        Err(document::SetError::OutOfRange {
            min: 0.2,
            max: 10.0
        })
    );

    // Every refusal kind the core defines crosses the ABI.
    assert_eq!(
        document::set(&defaults, "nope.nope", &serde_json::json!(true)),
        Err(document::SetError::UnknownId)
    );
    assert_eq!(
        document::set(&defaults, "general.window.title", &serde_json::json!(5)),
        Err(document::SetError::WrongType)
    );
    assert_eq!(
        document::set(
            &defaults,
            "general.window.orientation",
            &serde_json::json!("diagonal")
        ),
        Err(document::SetError::NotAnOption)
    );
    assert_eq!(
        document::set(
            b"garbage bytes",
            "general.window.border_width",
            &serde_json::json!(8)
        ),
        Err(document::SetError::InvalidDocument)
    );
    // The dependency rule: bring-to-front needs expand-on-hover to hold.
    let collapsed = document::set(
        &defaults,
        "general.window.expand_on_hover",
        &serde_json::json!(false),
    )
    .unwrap();
    assert_eq!(
        document::set(
            &collapsed,
            "general.window.bring_to_front_on_expand",
            &serde_json::json!(true)
        ),
        Err(document::SetError::DependencyNotMet)
    );

    // A valid set changes the bytes; storing the default removes it again.
    let changed = document::set(
        &defaults,
        "general.window.border_width",
        &serde_json::json!(8),
    )
    .unwrap();
    assert_eq!(
        changed,
        br#"{
  "format": "xrg-ng-settings",
  "settings": {
    "general.window.border_width": 8
  },
  "version": 1
}
"#
        .to_vec()
    );
    let restored = document::set(
        &changed,
        "general.window.border_width",
        &serde_json::json!(4),
    )
    .unwrap();
    assert_eq!(restored, canonical_defaults);
}

#[test]
fn oversized_set_requests_are_not_invalid_documents() {
    // Against a valid document, an id over the ABI's 256-byte bound and a
    // string value over its 8 KiB bound are request problems: the error
    // must not invite document-replacement recovery.
    let defaults = defaults_document();
    let long_id = "i".repeat(300 * 1024);
    let long_value = "v".repeat(9 * 1024);
    // A text value the catalog accepts (text controls carry no bound) whose
    // JSON encoding escapes past the 8 KiB wire bound.
    let escaped_value = "\\".repeat(4300);
    for result in [
        document::set(&defaults, &long_id, &serde_json::json!(1)),
        document::set(
            &defaults,
            "graphs.processes.filter",
            &serde_json::json!(long_value),
        ),
        document::set(
            &defaults,
            "graphs.processes.filter",
            &serde_json::json!(escaped_value),
        ),
    ] {
        assert_eq!(result, Err(document::SetError::RequestTooLarge));
    }
    // A document that does not load still reports exactly that.
    assert_eq!(
        document::set(
            b"not json",
            "graphs.processes.filter",
            &serde_json::json!("")
        ),
        Err(document::SetError::InvalidDocument)
    );
}

#[test]
fn unparsable_set_values_are_request_errors_not_invalid_documents() {
    shared::check_abi();
    let defaults = defaults_document();
    let id = b"general.window.border_width".to_vec();

    // 257 nested arrays around 0: valid JSON, only 515 bytes on the wire,
    // but nesting past the core parser's 256 depth limit. Against a valid
    // document it must be a request error, never InvalidDocument, so the
    // caller never mistakes it for a file to replace.
    let mut too_deep = serde_json::json!(0);
    for _ in 0..257 {
        too_deep = serde_json::Value::Array(vec![too_deep]);
    }
    assert_eq!(
        document::set(&defaults, "general.window.border_width", &too_deep),
        Err(document::SetError::UnparsableRequest)
    );
    // One level less parses on the core side and is refused for its shape.
    let mut bounded = serde_json::json!(0);
    for _ in 0..256 {
        bounded = serde_json::Value::Array(vec![bounded]);
    }
    assert_eq!(
        document::set(&defaults, "general.window.border_width", &bounded),
        Err(document::SetError::WrongType)
    );

    // Malformed JSON and invalid UTF-8 cannot pass through `serde_json`,
    // so they ride the raw wire: still a request error, still never -1.
    for value in [b"{not json".to_vec(), vec![0xff, 0xfe]] {
        let (status, response) = raw_set(&defaults, &id, &value);
        let response = response.unwrap_or_else(|| {
            panic!("a value the core cannot parse must ride the wire, got {status}")
        });
        assert_eq!(error_kind(&response), Some("unparsable-request"));
    }
    // An id that is not UTF-8 is refused the same way.
    let (id_status, id_response) = raw_set(&defaults, &[0xff], b"8");
    let id_response = id_response.unwrap_or_else(|| {
        panic!("an id the core cannot parse must ride the wire, got {id_status}")
    });
    assert_eq!(error_kind(&id_response), Some("unparsable-request"));
    // So is a section name that is not UTF-8, in the reset entry point.
    let (section_status, section_response) = raw_reset_section(&defaults, &[0xff]);
    let section_response = section_response.unwrap_or_else(|| {
        panic!("a section the core cannot parse must ride the wire, got {section_status}")
    });
    assert_eq!(error_kind(&section_response), Some("unparsable-request"));

    // An unreadable document with a perfectly valid value is still -1, and
    // still exactly InvalidDocument on the Rust side.
    let (refused, refused_response) = raw_set(b"not json", &id, b"8");
    assert_eq!(refused, -1);
    assert!(refused_response.is_none());
    assert_eq!(
        document::set(
            b"not json",
            "general.window.border_width",
            &serde_json::json!(8)
        ),
        Err(document::SetError::InvalidDocument)
    );
}

#[test]
fn reset_section_restores_only_that_section() {
    let bytes = fs::read(fixtures().join("unknown-keys.json")).unwrap();
    let reset = document::reset_section(&bytes, "general").unwrap();
    // The one stored general-section value is gone; the unknown keys at both
    // levels survive untouched.
    assert_eq!(
        reset,
        br#"{
  "format": "xrg-ng-settings",
  "settings": {
    "another.scalar": -7,
    "experiments.alpha.flag": true,
    "future.widget.config": {
      "labels": [
        "a",
        "b"
      ],
      "nested": {
        "deep": null
      },
      "size": 2
    },
    "some.scalar": 3.25
  },
  "toplevel.extra": "kept",
  "version": 1
}
"#
        .to_vec()
    );
    // A section the catalog does not have is refused, as is a document that
    // does not load.
    assert!(document::reset_section(&bytes, "nope").is_err());
    assert!(document::reset_section(b"not json", "general").is_err());
}

#[test]
fn the_linux_migration_and_view_round_trip_through_the_model() {
    let v40 = fs::read(fixtures().join("linux-v40.json")).unwrap();
    let migrated = match document::migrate_v40(&v40).unwrap() {
        document::Loaded::Ok {
            document,
            diagnostics,
        } => {
            let expected: Expected = serde_json::from_slice(
                &fs::read(fixtures().join("linux-v40-expected.json")).unwrap(),
            )
            .unwrap();
            assert_eq!(diagnostics, expected.diagnostics);
            assert_eq!(document, expected.document.unwrap().as_bytes());
            document
        }
        document::Loaded::Unreadable { .. } => panic!("the version-40 fixture must migrate"),
    };

    // The view bytes through the ABI are exactly the hand-derived fixture
    // bytes, and they deserialise into the Rust model: equal to the struct
    // the fixture file itself parses to, carrying the shared Stocks object.
    let expected_view = fs::read(fixtures().join("linux-v40-view-expected.json")).unwrap();
    let view = raw_linux_view(&migrated);
    assert_eq!(
        view, expected_view,
        "the Linux view differs from the hand-derived v40 shape"
    );
    let expected_settings = Settings::parse(&expected_view).unwrap();
    assert_eq!(document::linux_view(&migrated).unwrap(), expected_settings);
    assert_eq!(
        document::linux_view(&migrated).unwrap().stocks,
        StockSettings {
            symbols: "AAPL".into(),
            timeframe: 12,
            show_change: true,
            show_djia: true
        }
    );

    // Anything that is not a JSON object is refused, never migrated empty;
    // an unreadable document has no view.
    assert!(document::migrate_v40(b"not json").is_err());
    assert!(document::migrate_v40(b"[1, 2, 3]").is_err());
    assert!(document::migrate_v40(b"null").is_err());
    assert!(document::linux_view(b"not json").is_err());
}

#[test]
fn a_core_valid_view_larger_than_the_legacy_rust_limit_loads() {
    shared::check_abi();
    // A text control the catalog leaves length-unbounded — the ticker list —
    // accepts a value far longer than the legacy Rust model's 128 KiB file
    // limit. The view the core renders is authoritative: it must deserialise
    // without a Rust-side size limit or validator. (The process filter
    // gained the workers' 128-character rule in the final review, finding 1,
    // so the ticker list is the unbounded control now.)
    let symbols = "y".repeat(140_000);
    let bytes = format!(
        r#"{{"format": "xrg-ng-settings", "settings": {{"stocks.symbols": "{symbols}"}}, "version": 1}}"#
    )
    .into_bytes();
    let document = match document::load(&bytes) {
        document::Loaded::Ok {
            document,
            diagnostics,
        } => {
            assert!(diagnostics.is_empty(), "the long ticker list is core-valid");
            document
        }
        document::Loaded::Unreadable { .. } => panic!("the long-symbols document must load"),
    };
    let raw = raw_linux_view(&document);
    assert!(
        raw.len() > 128 * 1024,
        "the view must exceed the legacy 128 KiB limit ({} bytes)",
        raw.len()
    );
    let settings = document::linux_view(&document).expect("the core's view must load");
    assert_eq!(settings.stocks.symbols, symbols);
}

#[test]
fn a_short_buffer_reports_needed_and_the_retry_succeeds() {
    let bytes = fs::read(fixtures().join("valid.json")).unwrap();
    let length = u32::try_from(bytes.len()).unwrap();
    let mut small = vec![0x5au8; 8];
    let mut needed = 0;
    let status =
        unsafe { xrg_settings_load(bytes.as_ptr(), length, small.as_mut_ptr(), 8, &mut needed) };
    assert_eq!(status, -2);
    assert!(needed > 8, "the required size must exceed the capacity");
    assert_eq!(small, vec![0x5a; 8], "a short buffer is left untouched");
    let mut exact = vec![0u8; needed as usize];
    let written = unsafe {
        xrg_settings_load(
            bytes.as_ptr(),
            length,
            exact.as_mut_ptr(),
            needed,
            &mut needed,
        )
    };
    assert_eq!(written, needed as i32);
    // The retry's response decodes to the same canonical document the
    // wrapper loads.
    let wire: serde_json::Value = serde_json::from_slice(&exact).unwrap();
    let raw_document = wire["document"]
        .as_str()
        .expect("the load response carries the document");
    match document::load(&bytes) {
        document::Loaded::Ok { document, .. } => assert_eq!(document, raw_document.as_bytes()),
        document::Loaded::Unreadable { .. } => panic!("valid.json must load"),
    }
}

#[test]
fn the_catalog_reaches_linux_entries() {
    let catalog = document::catalog().unwrap();
    assert_eq!(
        catalog.sections,
        [
            "general",
            "appearance",
            "graphs",
            "sources",
            "ai",
            "weather",
            "stocks",
            "themes"
        ]
    );
    assert!(!catalog.entries.is_empty());
    for entry in &catalog.entries {
        assert!(
            entry.platforms.iter().any(|platform| platform == "linux"),
            "{} is not a Linux entry",
            entry.id
        );
    }
    let find = |id: &str| catalog.entries.iter().find(|entry| entry.id == id);
    assert_eq!(
        find("stocks.symbols")
            .expect("stocks.symbols is a Linux entry")
            .default,
        serde_json::json!("AAPL")
    );
    assert_eq!(
        find("stocks.timeframe")
            .expect("stocks.timeframe is a Linux entry")
            .default,
        serde_json::json!(12)
    );
    let refresh = find("graphs.refresh").expect("graphs.refresh is a Linux entry");
    let range = refresh.range.as_ref().expect("graphs.refresh is bounded");
    assert_eq!((range.min, range.max), (0.2, 10.0));
    // Entries the platform does not render are filtered out of its catalog.
    assert!(find("general.window.border_width").is_none());
}

#[test]
fn the_stock_parsers_and_urls_cross_the_abi() {
    let stocks = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Shared/Tests/Fixtures/stocks");
    // A history parse fills only the closes; the quote side stays null.
    let history =
        shared::stock_history(&fs::read(stocks.join("history-1y.json")).unwrap()).unwrap();
    assert_eq!((history.price, history.change), (None, None));
    let closes = history.closes.expect("the history side carries the closes");
    assert_eq!(closes.len(), 251);
    assert_eq!(closes.first(), Some(&268.4700012207031));
    assert_eq!(closes.last(), Some(&342.3699951171875));

    // A quote parse fills only price and change; the history side stays null.
    let quote = shared::stock_quote(&fs::read(stocks.join("quote-15m.json")).unwrap()).unwrap();
    assert_eq!(quote.price, Some(342.37));
    assert_eq!(quote.change, Some(342.37 - 344.17));
    assert_eq!(quote.closes, None);

    // The failure shapes Yahoo returns are refused.
    for name in ["error-not-found", "malformed", "empty-result"] {
        let bytes = fs::read(stocks.join(format!("{name}.json"))).unwrap();
        assert!(shared::stock_history(&bytes).is_none(), "{name} history");
        assert!(shared::stock_quote(&bytes).is_none(), "{name} quote");
    }

    // The exact URLs the macOS 0.2.2 stock module built, unchanged.
    let aapl = shared::stock_urls("AAPL").unwrap();
    assert_eq!(
        aapl.0,
        "https://query1.finance.yahoo.com/v7/finance/chart/AAPL?range=1y&interval=1d&indicators=quote&includeTimestamps=true"
    );
    assert_eq!(
        aapl.1,
        "https://query1.finance.yahoo.com/v8/finance/chart/AAPL?region=US&lang=en-US&includePrePost=false&interval=15m&range=1d"
    );
    let gspc = shared::stock_urls("^GSPC").unwrap();
    assert_eq!(
        gspc.0,
        "https://query1.finance.yahoo.com/v7/finance/chart/%5EGSPC?range=1y&interval=1d&indicators=quote&includeTimestamps=true"
    );
    assert_eq!(
        gspc.1,
        "https://query1.finance.yahoo.com/v8/finance/chart/%5EGSPC?region=US&lang=en-US&includePrePost=false&interval=15m&range=1d"
    );
}
