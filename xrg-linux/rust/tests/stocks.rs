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
        Arc, Mutex,
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
    use xrg_ng_linux::engine::Worker;
    // The Stocks fetch blocks on its own thread until the test releases it.
    let started = Arc::new(AtomicBool::new(false));
    let hold = Arc::new(AtomicBool::new(true));
    let started_fetch = started.clone();
    let hold_fetch = hold.clone();
    let fetch: Fetch = Box::new(move |_| {
        started_fetch.store(true, Ordering::SeqCst);
        while hold_fetch.load(Ordering::SeqCst) {
            thread::sleep(Duration::from_millis(5));
        }
        Err("fixture released".into())
    });
    let mut settings = Settings::default();
    settings.module_mut(Module::Stocks).visible = true;
    settings.sampling_interval_ms = 200; // the fastest valid cadence
    let worker = Worker::start_with_stocks_fetcher(false, &settings, Some(fetch));
    let (send, receive) = mpsc::channel();
    let send = Arc::new(Mutex::new(send));
    let latest = worker.latest.clone();
    worker.on_publish(move || {
        if let Some(snapshot) = latest.lock().unwrap().take() {
            let _ = send.lock().unwrap().send(snapshot);
        }
    });
    // The fetch really started, on the collector's own thread.
    let deadline = Instant::now() + Duration::from_secs(5);
    while !started.load(Ordering::SeqCst) {
        assert!(Instant::now() < deadline, "the Stocks fetch never started");
        thread::sleep(Duration::from_millis(5));
    }
    // While the fetch stays blocked, several worker snapshots must arrive.
    let mut snapshots = Vec::new();
    for _ in 0..3 {
        snapshots.push(
            receive
                .recv_timeout(Duration::from_secs(5))
                .expect("the sampling worker keeps publishing while the fetch is blocked"),
        );
    }
    // Distinct samples: the sampler (and every other collector) never
    // waited on the blocked curl.
    for pair in snapshots.windows(2) {
        assert!(pair[1].sequence > pair[0].sequence);
    }
    // Another collector keeps making progress: the CPU graph is re-sampled
    // with a full series in every one of those snapshots, independent of
    // Stocks' answer.
    for snapshot in &snapshots {
        let cpu = snapshot
            .panels
            .iter()
            .find(|panel| panel.title == "CPU")
            .expect("the CPU panel is drawn");
        assert!(
            cpu.series.first().is_some_and(|series| !series.is_empty()),
            "CPU keeps sampling while the Stocks fetch is blocked"
        );
    }
    // The Stocks fetch is still blocked: no reading has answered yet, yet
    // nothing stalled.
    assert!(snapshots.iter().all(|snapshot| {
        snapshot
            .stocks
            .as_ref()
            .is_none_or(|update| update.readings.iter().all(|r| r.status != StockStatus::Ok))
    }));
    // A worker control is still serviced while the fetch is blocked: resetting
    // the sensor statistics advances a later snapshot's generation. Drain the
    // queued snapshots until that fresh one arrives.
    let base_generation = snapshots.last().unwrap().sensors.generation;
    worker.sensor_stats_control().reset().unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let next = receive
            .recv_timeout(Duration::from_secs(5))
            .expect("the worker still publishes while the fetch is blocked");
        if next.sensors.generation > base_generation {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "the sensor-statistics reset never reached a new snapshot"
        );
    }
    // Release the fetch and shut the worker down.
    hold.store(false, Ordering::SeqCst);
    drop(worker);
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

// --- Fix round 1: these fail against the first implementation (RED) ---

#[test]
fn fallback_price_is_the_final_close_and_change_is_final_minus_previous() {
    // A valid one-year history ending [100, 110] with a quote the shared
    // parser cannot use: macOS falls back to the last two daily closes. The
    // final close is the price; the change is final minus its predecessor.
    let fetch: Fetch = Box::new(|url: &str| {
        if url.contains("/v7/") {
            Ok(
                br#"{"chart":{"result":[{"indicators":{"quote":[{"close":[90,100,110]}]}}]}}"#
                    .to_vec(),
            )
        } else {
            Ok(br#"{"chart":{"result":[{}]}}"#.to_vec())
        }
    });
    let mut collector = StockCollector::new(fetch);
    let start = Instant::now();
    let readings = settle(&mut collector, &settings(), start, |readings| {
        readings.iter().any(|r| r.status == StockStatus::Ok)
    });
    assert_eq!(readings[0].price, Some(110.));
    assert_eq!(readings[0].change, Some(10.));
}

// --- Final review, finding 8: one endpoint's failure keeps the other's
// --- usable result, exactly as macOS accepts either response.

#[test]
fn a_quote_transport_error_keeps_the_fetched_history() {
    // The history answers with the recorded one-year curve; the quote
    // request fails at transport. The first refresh shows the history with
    // the macOS fallback price, not the empty network-error state.
    let fixtures = fixtures();
    let fetch: Fetch = Box::new(move |url: &str| {
        if url.contains("/v8/") {
            Err("connection reset by peer".into())
        } else {
            fs::read(fixtures.join("history-1y.json")).map_err(|e| e.to_string())
        }
    });
    let mut collector = StockCollector::new(fetch);
    let start = Instant::now();
    let readings = settle(&mut collector, &settings(), start, |readings| {
        readings.iter().any(|r| r.status == StockStatus::Ok)
    });
    let reading = &readings[0];
    assert_eq!(reading.status, StockStatus::Ok);
    assert_eq!(reading.closes.len(), 251);
    // The fallback price: the final close, and the change final minus the
    // previous close — the same values the recorded happy path's quote
    // carries, derived from the curve.
    assert_eq!(reading.price, Some(342.3699951171875));
    assert_eq!(
        reading.change,
        Some(342.3699951171875 - reading.closes[reading.closes.len() - 2])
    );
}

#[test]
fn a_history_transport_error_keeps_the_quote() {
    // The quote answers with the recorded 15-minute price; the history
    // request fails at transport. The first refresh shows the quote, with
    // no curve to draw — what macOS displays for the same responses.
    let fixtures = fixtures();
    let fetch: Fetch = Box::new(move |url: &str| {
        if url.contains("/v7/") {
            Err("connection timed out".into())
        } else {
            fs::read(fixtures.join("quote-15m.json")).map_err(|e| e.to_string())
        }
    });
    let mut collector = StockCollector::new(fetch);
    let start = Instant::now();
    let readings = settle(&mut collector, &settings(), start, |readings| {
        readings.iter().any(|r| r.status == StockStatus::Ok)
    });
    let reading = &readings[0];
    assert_eq!(reading.status, StockStatus::Ok);
    assert_eq!(reading.price, Some(342.37));
    assert_eq!(reading.change, Some(342.37 - 344.17));
    assert!(reading.closes.is_empty(), "no history arrived to draw");
}

#[test]
fn network_failure_keeps_the_retained_curve_in_the_panel() {
    use xrg_ng_linux::stocks::{Graph, StockReading, StockStatus, Update};
    let update = Update {
        settings: settings(),
        readings: vec![StockReading {
            ticker: "AAPL".into(),
            price: Some(110.),
            change: Some(10.),
            closes: vec![90., 100., 110.],
            status: StockStatus::NetworkError,
        }],
    };
    let mut graph = Graph::default();
    let panel = graph.panel(Some(&update));
    assert!(
        !panel.series.is_empty(),
        "the retained closes stay drawn while the failure is reported"
    );
    assert!(panel.label.contains("network error"));
}

#[test]
fn missing_change_is_na_and_failure_status_appears_in_the_readout() {
    use xrg_ng_linux::{
        dashboard::Row,
        stocks::{Graph, StockReading, StockStatus, Update, change_string},
        temperature::Units,
    };
    assert_eq!(change_string(None), "n/a");
    assert_eq!(change_string(Some(0.)), "unch");
    // A bundled-font glyph, never macOS's ▲/▼ tofu (V1).
    assert_eq!(change_string(Some(-1.8)), "-1.80");
    assert_eq!(change_string(Some(1.8)), "+1.80");
    for (status, label) in [
        (StockStatus::NotFound, "not found"),
        (StockStatus::BadResponse, "bad response"),
    ] {
        let update = Update {
            settings: settings(),
            readings: vec![StockReading {
                ticker: "AAPL".into(),
                price: None,
                change: None,
                closes: Vec::new(),
                status,
            }],
        };
        let mut graph = Graph::default();
        let panel = graph.panel(Some(&update));
        let texts: Vec<String> = panel
            .readout
            .top
            .iter()
            .map(|row: &Row| row.right.render(Units::Celsius).into_owned())
            .collect();
        assert!(texts.iter().any(|t| t == "n/a"), "{texts:?}");
        assert!(
            texts.iter().any(|t| t == label),
            "the {label:?} status must be visible in the readout: {texts:?}"
        );
        assert!(!texts.iter().any(|t| t == "unch"), "{texts:?}");
    }
}

#[test]
fn http_404_not_found_envelope_reaches_not_found_classification() {
    use xrg_ng_linux::https::{HttpReply, stock_body};
    let envelope = fixture("error-not-found");
    // The new Stocks transport keeps a 404's status and body; `stock_body`
    // hands that body through (Weather's `--fail` would have turned it into a
    // transport error). Model that boundary in a Stocks fetch closure.
    let kept = stock_body(Ok(HttpReply {
        status: 404,
        body: envelope.clone(),
    }))
    .expect("a 404 keeps its body for classification");
    assert_eq!(kept, envelope);
    // A genuine transport failure and a non-404 HTTP error stay errors, so
    // the collector retains the last good values for them.
    assert!(stock_body(Err("curl exited with failure".into())).is_err());
    assert!(
        stock_body(Ok(HttpReply {
            status: 500,
            body: b"gateway error".to_vec(),
        }))
        .is_err()
    );
    let fetch: Fetch = Box::new(move |_| {
        stock_body(Ok(HttpReply {
            status: 404,
            body: envelope.clone(),
        }))
    });
    let mut collector = StockCollector::new(fetch);
    let start = Instant::now();
    let readings = settle(&mut collector, &settings(), start, |readings| {
        !readings.is_empty()
    });
    assert_eq!(
        readings[0].status,
        StockStatus::NotFound,
        "the 404 envelope is classified as NotFound, not NetworkError"
    );
}

#[test]
fn quote_rows_start_at_the_displayed_ticker() {
    use xrg_ng_linux::stocks::{Graph, StockReading, StockStatus, Update};
    // More tickers than the 148x212 panel can show: the first visible rows
    // must belong to the rotating curve, or its quote is clipped away.
    let symbols: Vec<String> = (0..12).map(|index| format!("T{index:02}")).collect();
    let update = Update {
        settings: StockSettings {
            symbols: symbols.join(","),
            timeframe: 12,
            show_change: true,
            show_djia: false,
        },
        readings: symbols
            .iter()
            .map(|ticker| StockReading {
                ticker: ticker.clone(),
                price: Some(1.),
                change: Some(0.5),
                closes: vec![90., 100., 110.],
                status: StockStatus::Ok,
            })
            .collect(),
    };
    let mut graph = Graph::default();
    graph.set_phase(7); // displayed ticker = symbols[7] = "T07"
    let panel = graph.panel(Some(&update));
    let ticker_rows: Vec<&str> = panel
        .readout
        .top
        .iter()
        .filter(|row| !row.left.is_empty())
        .map(|row| row.left.as_str())
        .collect();
    assert!(
        ticker_rows.len() > 8,
        "the list is longer than the panel holds"
    );
    assert_eq!(ticker_rows[0], "T07", "rows start at the displayed ticker");
    assert_eq!(ticker_rows[1], "T08", "the rest follow in list order");
    assert_eq!(ticker_rows.last(), Some(&"T06"), "the rows wrap around");
}
