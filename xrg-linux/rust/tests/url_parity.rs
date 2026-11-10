// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! The shared loopback-endpoint parity table (round 3, ruling R40):
//! `Shared/Tests/Fixtures/url-parity.json` holds every accept/reject case
//! both platforms assert identically — the Swift suite through the shared
//! core's `isLoopbackHTTPURL`, this suite through the AI workers' own
//! `validate_url`, whose authority parsing is std's
//! `SocketAddr`/`IpAddr` parser. The table is derived from what Rust's
//! parser does, so a working 0.2.2 endpoint is never dropped and a
//! malformed one is never newly accepted.
use serde::Deserialize;
use std::{
    fs,
    net::{Ipv6Addr, SocketAddr},
    path::Path,
};

/// One parity case: the URL and whether the workers' endpoint rule accepts.
#[derive(Deserialize)]
struct Case {
    url: String,
    accept: bool,
}

#[derive(Deserialize)]
struct Table {
    cases: Vec<Case>,
}

#[test]
fn the_shared_table_matches_the_workers_std_parser() {
    let text = fs::read_to_string(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Shared/Tests/Fixtures/url-parity.json"),
    )
    .expect("the shared parity table is checked out");
    let table: Table = serde_json::from_str(&text).unwrap();
    assert!(!table.cases.is_empty(), "the shared parity table is empty");
    for case in &table.cases {
        assert_eq!(
            xrg_ng_linux::ai::validate_url(&case.url).is_ok(),
            case.accept,
            "{} must {} by the workers' own rule",
            case.url,
            if case.accept {
                "be accepted"
            } else {
                "be refused"
            }
        );
    }
}

/// The std parser's own rules the table pins (ruling R40): a leading-zero
/// port parses to its value, and an embedded IPv4 quad is valid only AFTER
/// a `::`, never before it — the grammar the shared validator mirrors.
#[test]
fn std_socket_parser_rules_the_table_pins() {
    assert_eq!("127.0.0.1:080".parse::<SocketAddr>().unwrap().port(), 80);
    assert_eq!("127.0.0.1:00080".parse::<SocketAddr>().unwrap().port(), 80);
    assert_eq!("[::1]:080".parse::<SocketAddr>().unwrap().port(), 80);
    assert!("::1.2.3.4".parse::<Ipv6Addr>().is_ok());
    // A dotted quad before the compression is not an IPv6 address.
    assert!("0.0.0.0::1".parse::<Ipv6Addr>().is_err());
    assert!("1.2.3.4::1".parse::<Ipv6Addr>().is_err());
    // Seven hex groups plus an embedded quad are nine groups.
    assert!("1:2:3:4:5:6:7:1.2.3.4".parse::<Ipv6Addr>().is_err());
}
