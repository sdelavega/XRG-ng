// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! The Stocks collector against the Task 6 recorded responses: a fake
//! fetcher answers every request, so no test touches the network. The
//! cadence, the ticker parsing and the failure handling copy macOS's
//! `XRGStock`/`XRGStockView` values exactly.
use std::{
    fs,
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicUsize, Ordering},
        mpsc,
    },
    thread,
    time::{Duration, Instant},
};
use xrg_ng_linux::{
    settings::{Module, Settings, StockSettings},
    stocks::{Fetch, StockCollector, StockReading, StockStatus, parse_symbols},
};

/// Shared/Tests/Fixtures/stocks, the same files the macOS and corpus tests
/// read.
fn fixtures() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Shared/Tests/Fixtures/stocks")
}

fn fixture(name: &str) -> Vec<u8> {
    fs::read(fixtures().join(format!("{name}.json"))).expect("the stock fixtures are checked out")
}

/// The recorded happy path: the history URL answers `history-1y.json`, the
/// quote URL `quote-15m.json`, exactly as the shared URL builder addresses
/// them.
fn recorded() -> Fetch {
    let fixtures = fixtures();
    Box::new(move |url: &str| {
        let name = if url.contains("/v7/") {
            "history-1y"
        } else {
            "quote-15m"
        };
        fs::read(fixtures.join(format!("{name}.json"))).map_err(|e| e.to_string())
    })
}

/// Every answer the collector asks for, until `fail` is set.
fn switchable(fail: Arc<AtomicBool>) -> Fetch {
    let fixtures = fixtures();
    Box::new(move |url: &str| {
        if fail.load(Ordering::SeqCst) {
            return Err("curl exited with failure".into());
        }
        let name = if url.contains("/v7/") {
            "history-1y"
        } else {
            "quote-15m"
        };
        fs::read(fixtures.join(format!("{name}.json"))).map_err(|e| e.to_string())
    })
}

/// The one ticker every fixture records, without the Dow.
fn settings() -> StockSettings {
    StockSettings {
        symbols: " aapl ".into(),
        timeframe: 12,
        show_change: true,
        show_djia: false,
    }
}

/// Poll until `want` holds, driving the collector with synthetic instants
/// anchored at `start` so the cadence never fires mid-test.
fn settle(
    collector: &mut StockCollector,
    settings: &StockSettings,
    now: Instant,
    want: impl Fn(&[StockReading]) -> bool,
) -> Vec<StockReading> {
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    loop {
        let readings = collector.poll(settings, now);
        if want(&readings) {
            return readings;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "the fake fetch never settled"
        );
        thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn recorded_responses_produce_quote_and_history() {
    let mut collector = StockCollector::new(recorded());
    let start = Instant::now();
    let readings = settle(&mut collector, &settings(), start, |readings| {
        readings.iter().any(|r| r.status == StockStatus::Ok)
    });
    assert_eq!(readings.len(), 1);
    let reading = &readings[0];
    assert_eq!(
        reading.ticker, "AAPL",
        "the list parses exactly as macOS does"
    );
    assert_eq!(reading.status, StockStatus::Ok);
    assert_eq!(reading.price, Some(342.37));
    assert_eq!(reading.change, Some(342.37 - 344.17));
    assert_eq!(reading.closes.len(), 251);
    assert_eq!(reading.closes.first(), Some(&268.4700012207031));
    assert_eq!(reading.closes.last(), Some(&342.3699951171875));
}

#[test]
fn unknown_ticker_reports_not_found() {
    let responses = fixture("error-not-found");
    let mut collector = StockCollector::new(Box::new(move |_| Ok(responses.clone())));
    let start = Instant::now();
    let readings = settle(&mut collector, &settings(), start, |readings| {
        !readings.is_empty()
    });
    let reading = &readings[0];
    assert_eq!(reading.ticker, "AAPL");
    assert_eq!(reading.status, StockStatus::NotFound);
    assert_eq!(reading.price, None);
    assert_eq!(reading.change, None);
    assert!(reading.closes.is_empty(), "a dead symbol keeps no values");
}

#[test]
fn network_failure_reports_and_keeps_last_values() {
    let fail = Arc::new(AtomicBool::new(false));
    let mut collector = StockCollector::new(switchable(fail.clone()));
    let start = Instant::now();
    let good = settle(&mut collector, &settings(), start, |readings| {
        readings.iter().any(|r| r.status == StockStatus::Ok)
    });
    fail.store(true, Ordering::SeqCst);
    // The macOS cadence: the next attempt is two hours after the last one.
    let readings = settle(
        &mut collector,
        &settings(),
        start + Duration::from_secs(7_200),
        |readings| {
            readings
                .iter()
                .any(|r| r.status == StockStatus::NetworkError)
        },
    );
    let before = &good[0];
    let after = readings
        .iter()
        .find(|r| r.ticker == "AAPL")
        .expect("the ticker stays listed");
    assert_eq!(after.status, StockStatus::NetworkError);
    assert_eq!(after.price, before.price, "the last price stays on screen");
    assert_eq!(after.change, before.change);
    assert_eq!(after.closes, before.closes);
}

#[test]
fn malformed_response_reports_bad_response() {
    let responses = fixture("malformed");
    let mut collector = StockCollector::new(Box::new(move |_| Ok(responses.clone())));
    let start = Instant::now();
    let readings = settle(&mut collector, &settings(), start, |readings| {
        !readings.is_empty()
    });
    assert_eq!(readings[0].status, StockStatus::BadResponse);
    assert_eq!(readings[0].price, None);
    assert!(readings[0].closes.is_empty());
}

#[test]
fn empty_result_is_not_a_chart() {
    let responses = fixture("empty-result");
    let mut collector = StockCollector::new(Box::new(move |_| Ok(responses.clone())));
    let start = Instant::now();
    let readings = settle(&mut collector, &settings(), start, |readings| {
        !readings.is_empty()
    });
    assert_eq!(readings[0].status, StockStatus::BadResponse);
    assert!(readings[0].closes.is_empty());
}

#[test]
fn slow_fetch_does_not_block_other_collectors() {
    let (started, wait) = mpsc::channel();
    let (release, gate) = mpsc::channel();
    let mut collector = StockCollector::new(Box::new(move |_| {
        let _ = started.send(());
        let _ = gate.recv_timeout(Duration::from_secs(9));
        Err("fixture released".into())
    }));
    let settings = settings();
    let begin = std::time::Instant::now();
    let readings = collector.poll(&settings, Instant::now());
    assert!(
        begin.elapsed() < Duration::from_secs(1),
        "poll waited {:?} for the fetch instead of leaving it to its own thread",
        begin.elapsed()
    );
    // The request really did start, on the fetcher's own thread, while the
    // caller already holds its (empty) readings — the sampling thread's
    // other collectors are never stalled by it.
    wait.recv_timeout(Duration::from_secs(5))
        .expect("the fetch started");
    assert!(readings.is_empty());
    release.send(()).unwrap();
    let readings = settle(&mut collector, &settings, Instant::now(), |readings| {
        readings
            .iter()
            .any(|r| r.status == StockStatus::NetworkError)
    });
    assert_eq!(readings[0].status, StockStatus::NetworkError);
}

#[test]
fn refresh_cadence_matches_macos() {
    let calls = Arc::new(AtomicUsize::new(0));
    let counter = calls.clone();
    let fixtures = fixtures();
    let fetch = Box::new(move |url: &str| {
        counter.fetch_add(1, Ordering::SeqCst);
        let name = if url.contains("/v7/") {
            "history-1y"
        } else {
            "quote-15m"
        };
        fs::read(fixtures.join(format!("{name}.json"))).map_err(|e| e.to_string())
    });
    let mut collector = StockCollector::new(fetch);
    let settings = settings();
    let start = Instant::now();
    settle(&mut collector, &settings, start, |readings| {
        readings.iter().any(|r| r.status == StockStatus::Ok)
    });
    // One cycle: the history and the quote of the one ticker.
    assert_eq!(calls.load(Ordering::SeqCst), 2);
    // macOS reloads on every fourth 30-minute update, so nothing refetches
    // before the two hours are out — polling every tick changes nothing.
    for offset in [1, 60, 1_800, 3_600, 7_199] {
        collector.poll(&settings, start + Duration::from_secs(offset));
    }
    assert_eq!(
        calls.load(Ordering::SeqCst),
        2,
        "a poll inside the cadence must not refetch"
    );
    // The cadence refetches at two hours; the fetch runs off-thread, so
    // poll until its calls land.
    let due = start + Duration::from_secs(7_200);
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    loop {
        collector.poll(&settings, due);
        if calls.load(Ordering::SeqCst) >= 4 {
            break;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "the cadence refetch never ran"
        );
        thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(
        calls.load(Ordering::SeqCst),
        4,
        "the cadence refetches at two hours"
    );
}

#[test]
fn changed_symbols_refetch_immediately_and_clear_the_old_ticker() {
    let calls = Arc::new(AtomicUsize::new(0));
    let counter = calls.clone();
    let fixtures = fixtures();
    let fetch = Box::new(move |url: &str| {
        counter.fetch_add(1, Ordering::SeqCst);
        let name = if url.contains("/v7/") {
            "history-1y"
        } else {
            "quote-15m"
        };
        fs::read(fixtures.join(format!("{name}.json"))).map_err(|e| e.to_string())
    });
    let mut collector = StockCollector::new(fetch);
    let start = Instant::now();
    let mut settings = settings();
    settle(&mut collector, &settings, start, |readings| {
        readings.iter().any(|r| r.status == StockStatus::Ok)
    });
    settings.symbols = "msft".into();
    let readings = settle(&mut collector, &settings, start, |readings| {
        readings
            .iter()
            .any(|r| r.ticker == "MSFT" && r.status == StockStatus::Ok)
    });
    assert!(
        readings.iter().all(|r| r.ticker != "AAPL"),
        "the old ticker's readings must not survive the edit"
    );
    assert!(
        calls.load(Ordering::SeqCst) >= 4,
        "the edited list refetches at once"
    );
}

#[test]
fn the_ticker_list_parses_exactly_as_macos_parses_it() {
    // Every whitespace character goes, the rest uppercases, empty segments
    // drop — XRGStockView.parseSymbols.
    assert_eq!(parse_symbols(" aapl , MsFT "), vec!["AAPL", "MSFT"]);
    assert_eq!(parse_symbols("A\tA"), vec!["AA"]);
    assert_eq!(parse_symbols(",,,"), Vec::<String>::new());
    assert_eq!(parse_symbols(""), Vec::<String>::new());
}

#[test]
fn show_djia_fetches_the_index() {
    let mut collector = StockCollector::new(recorded());
    let settings = StockSettings {
        show_djia: true,
        ..settings()
    };
    let start = Instant::now();
    let readings = settle(&mut collector, &settings, start, |readings| {
        readings
            .iter()
            .any(|r| r.ticker == "^DJI" && r.status == StockStatus::Ok)
    });
    assert!(readings.iter().any(|r| r.ticker == "AAPL"));
    let djia = readings.iter().find(|r| r.ticker == "^DJI").unwrap();
    assert_eq!(
        djia.closes.len(),
        251,
        "the Dow rides the same recorded history"
    );
}

#[test]
fn module_is_off_by_default() {
    let settings = Settings::default();
    assert!(
        !settings.module(Module::Stocks).visible,
        "the Stocks graph must join the dashboard off (ruling R7)"
    );
    assert!(
        Module::ALL.contains(&Module::Stocks),
        "the module list knows Stocks"
    );
}
