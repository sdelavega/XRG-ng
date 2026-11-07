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

// The raw ABI entry points a C caller uses, for the buffer contract checks.
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
    // A text control has no catalog bound, so the core accepts a process
    // filter far longer than the legacy Rust model's 128 KiB file limit.
    // The view the core renders is authoritative: it must deserialise
    // without a Rust-side size limit or validator.
    let filter = "x".repeat(140_000);
    let bytes = format!(
        r#"{{"format": "xrg-ng-settings", "settings": {{"graphs.processes.filter": "{filter}"}}, "version": 1}}"#
    )
    .into_bytes();
    let document = match document::load(&bytes) {
        document::Loaded::Ok {
            document,
            diagnostics,
        } => {
            assert!(diagnostics.is_empty(), "the long filter is core-valid");
            document
        }
        document::Loaded::Unreadable { .. } => panic!("the long-filter document must load"),
    };
    let raw = raw_linux_view(&document);
    assert!(
        raw.len() > 128 * 1024,
        "the view must exceed the legacy 128 KiB limit ({} bytes)",
        raw.len()
    );
    let settings = document::linux_view(&document).expect("the core's view must load");
    assert_eq!(settings.processes.filter, filter);
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
