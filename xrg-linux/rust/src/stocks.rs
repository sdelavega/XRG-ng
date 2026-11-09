// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! The Stocks graph's collector and dashboard panel: the same Yahoo chart
//! data macOS graphs, parsed only through the shared core, fetched off the
//! sampling thread.
//!
//! Behaviour copies `XRGCore/XRGStock.swift` and `XRGCore/XRGStockView.swift`:
//! the ticker list parses exactly as macOS parses it, the Dow joins as a
//! secondary curve, the data refreshes on macOS's two-hour cadence, the
//! displayed ticker rotates every 30 seconds, and a network failure leaves
//! the last good values on screen.
use crate::{
    dashboard::{Readout, Row},
    engine::{Panel, Scale},
    https::{self},
    settings::{Module, StockSettings},
    shared,
};
use std::{
    sync::{Arc, Mutex, mpsc},
    thread,
    time::{Duration, Instant},
};

/// macOS reloads the stock module on every fourth 30-minute update
/// (`XRGStockView.min30Update`'s `slowPhase`), so the data refreshes every
/// two hours.
const REFRESH: Duration = Duration::from_secs(7_200);
/// The displayed ticker switches every 30 seconds: the stock view's
/// 2-second ticker on its 15th tick.
const ROTATE: Duration = Duration::from_secs(30);
/// The Dow index, added as the secondary curve while Show DJIA is on.
const DJIA: &str = "^DJI";
/// One chart response the shared ABI accepts is bounded at 8 MiB; a larger
/// body is refused without crossing it.
const RESPONSE_LIMIT: usize = 8 * 1024 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StockStatus {
    Ok,
    NotFound,
    NetworkError,
    BadResponse,
}

#[derive(Clone, Debug, PartialEq)]
pub struct StockReading {
    pub ticker: String,
    pub price: Option<f64>,
    pub change: Option<f64>,
    pub closes: Vec<f64>,
    pub status: StockStatus,
}

/// One dashboard's worth of Stocks state: the settings the readings were
/// collected with, so a settings edit blocks the panel until fresh readings
/// answer the edited symbols.
#[derive(Clone, Debug, PartialEq)]
pub struct Update {
    pub settings: StockSettings,
    pub readings: Vec<StockReading>,
}

/// The ticker list exactly as macOS parses it
/// (`XRGStockView.parseSymbols`): every whitespace character removed, the
/// rest uppercased, split on commas, empty segments dropped.
pub fn parse_symbols(text: &str) -> Vec<String> {
    let squeezed: String = text.chars().filter(|c| !c.is_whitespace()).collect();
    squeezed
        .to_uppercase()
        .split(',')
        .filter(|symbol| !symbol.is_empty())
        .map(str::to_owned)
        .collect()
}

/// The price string exactly as macOS formats it: `$%.2f`, or `n/a` when
/// there is no current value.
pub fn price_string(price: Option<f64>) -> String {
    price.map_or_else(|| "n/a".into(), |price| format!("${price:.2}"))
}

/// One bounded fetch: a URL in, the body bytes or the failure out. The
/// exact type the brief names for `StockCollector::new`.
pub type Fetch = Box<dyn Fn(&str) -> Result<Vec<u8>, String> + Send>;

/// The change string exactly as macOS formats it: `n/a` without a value,
/// `unch` on a zero change, otherwise a direction glyph and the magnitude.
/// The bundled fonts carry no ▲/▼ geometric shapes (they render as tofu), so
/// the direction is a `+`/`-` ASCII sign every font has (visual finding V1).
pub fn change_string(change: Option<f64>) -> String {
    let Some(change) = change else {
        return "n/a".into();
    };
    if change == 0. {
        return "unch".into();
    }
    format!("{}{:.2}", if change > 0. { "+" } else { "-" }, change.abs())
}

/// The live fetch path: the bounded HTTPS GET that keeps the HTTP status and
/// body, so a 404's not-found envelope reaches the classifier. Weather keeps
/// its own `--fail` client; both share the same timeouts and response cap
/// (spec §7).
pub fn live_fetcher() -> Fetch {
    Box::new(|url| https::stock_https_get(url, https::TIMEOUT))
}

/// How the engine starts the collector: the initial visible state and the
/// fetch path. Production fetches live; the smoke passes recorded
/// responses.
pub struct Launch {
    pub settings: StockSettings,
    pub visible: bool,
    pub fetcher: Option<Fetch>,
}
impl Launch {
    pub fn from_settings(settings: &crate::settings::Settings) -> Self {
        Self {
            settings: settings.stocks.clone(),
            visible: settings.module(Module::Stocks).visible,
            fetcher: None,
        }
    }
    /// The off state: the module hidden, so nothing fetches and the panel
    /// explains where to enable it.
    pub fn off() -> Self {
        Self {
            settings: StockSettings::default(),
            visible: false,
            fetcher: None,
        }
    }
}

/// The collector's fetch state, pushed by the app when the graph is shown
/// or hidden: `None` inside means the module is not displayed, and no
/// request is made for it. A push wakes the sampling worker, the way the
/// other controls do, so the graph follows the edit within a frame.
#[derive(Default)]
struct Pending(Option<Option<StockSettings>>);
#[derive(Clone, Default)]
pub struct Control {
    pending: Arc<Mutex<Pending>>,
    wake: Option<crate::sampling::Control>,
}
impl Control {
    /// The engine's control: pushes wake the sampling worker.
    pub fn with_wake(wake: crate::sampling::Control) -> Self {
        Self {
            pending: Default::default(),
            wake: Some(wake),
        }
    }
    pub fn set(&self, visible: bool, settings: StockSettings) {
        *self.pending.lock().unwrap() = Pending(Some(visible.then_some(settings)));
        if let Some(wake) = &self.wake {
            // A refused wake is a worker already shutting down; the next
            // start re-reads the settings anyway.
            let _ = wake.request();
        }
    }
    pub(crate) fn take(&self) -> Option<Option<StockSettings>> {
        std::mem::take(&mut self.pending.lock().unwrap().0)
    }
}

enum Request {
    Cycle {
        generation: u64,
        tickers: Vec<String>,
    },
}
enum Posted {
    Reading {
        generation: u64,
        reading: StockReading,
    },
    Done,
}

/// The dashboard collector. `poll` never blocks: a due refresh hands the
/// ticker list to a fetch thread this collector owns, and later polls adopt
/// the responses that thread has already answered. A slow or failing fetch
/// therefore never stalls the sampling thread or the other graphs, and the
/// last good values stay on screen until a response replaces them.
pub struct StockCollector {
    requests: mpsc::Sender<Request>,
    results: mpsc::Receiver<Posted>,
    tickers: Vec<String>,
    readings: Vec<StockReading>,
    last_attempt: Option<Instant>,
    generation: u64,
    busy: bool,
}
impl StockCollector {
    pub fn new(fetch: Fetch) -> Self {
        let (requests, inbox) = mpsc::channel();
        let (outbound, results) = mpsc::channel();
        // The handle is dropped at once: dropping a JoinHandle detaches the
        // thread, which is what the collector wants — a cycle in flight may
        // outlive it, and the sampler's shutdown must never wait out curl.
        // The thread ends when the request channel closes or a send fails.
        thread::Builder::new()
            .name("xrg-stocks-fetch".into())
            .spawn(move || {
                let fetch = fetch;
                while let Ok(request) = inbox.recv() {
                    let Request::Cycle {
                        generation,
                        tickers,
                    } = request;
                    for ticker in tickers {
                        let reading = fetch_ticker(&*fetch, &ticker);
                        if outbound
                            .send(Posted::Reading {
                                generation,
                                reading,
                            })
                            .is_err()
                        {
                            return;
                        }
                    }
                    if outbound.send(Posted::Done).is_err() {
                        return;
                    }
                }
            })
            .expect("the stocks fetch thread spawns");
        Self {
            requests,
            results,
            tickers: Vec::new(),
            readings: Vec::new(),
            last_attempt: None,
            generation: 0,
            busy: false,
        }
    }

    pub fn poll(&mut self, settings: &StockSettings, now: Instant) -> Vec<StockReading> {
        let mut tickers = parse_symbols(&settings.symbols);
        // The Dow joins exactly as macOS joins it: alongside the symbols,
        // only while the list is not empty (XRGStockView.synchronizeDJIA).
        if settings.show_djia && !tickers.is_empty() && !tickers.iter().any(|t| t == DJIA) {
            tickers.push(DJIA.into());
        }
        if self.tickers != tickers {
            // A changed list is a new graph: macOS cancels the old objects
            // and rebuilds, so no stale ticker keeps a reading here either.
            self.tickers = tickers;
            self.readings.clear();
            self.last_attempt = None;
            self.generation = self.generation.wrapping_add(1);
        }
        if self.tickers.is_empty() {
            return Vec::new();
        }
        let due = self.last_attempt.is_none_or(|last| now >= last + REFRESH);
        if due && !self.busy {
            self.busy = true;
            self.last_attempt = Some(now);
            let _ = self.requests.send(Request::Cycle {
                generation: self.generation,
                tickers: self.tickers.clone(),
            });
        }
        while let Ok(posted) = self.results.try_recv() {
            match posted {
                Posted::Done => self.busy = false,
                Posted::Reading {
                    generation,
                    reading,
                } if generation == self.generation => self.adopt(reading),
                // A cycle the symbol edit cancelled still answers; its
                // readings are dropped unopened.
                Posted::Reading { .. } => (),
            }
        }
        self.readings.clone()
    }

    /// Merge one answered ticker. A network failure keeps the last values
    /// on screen; an unknown symbol or an unreadable response keeps none.
    fn adopt(&mut self, reading: StockReading) {
        let position = self
            .readings
            .iter()
            .position(|existing| existing.ticker == reading.ticker);
        let (price, change, closes) = if reading.status == StockStatus::NetworkError {
            let Some(previous) = position.map(|index| &self.readings[index]) else {
                self.readings.push(reading);
                return;
            };
            (previous.price, previous.change, previous.closes.clone())
        } else {
            (reading.price, reading.change, reading.closes)
        };
        let merged = StockReading {
            ticker: reading.ticker,
            price,
            change,
            closes,
            status: reading.status,
        };
        match position {
            Some(index) => self.readings[index] = merged,
            None => self.readings.push(merged),
        }
    }
}

fn fetch_ticker(fetch: &dyn Fn(&str) -> Result<Vec<u8>, String>, ticker: &str) -> StockReading {
    let reading = |status, price, change, closes| StockReading {
        ticker: ticker.to_owned(),
        price,
        change,
        closes,
        status,
    };
    // The URLs come from the shared core, byte-exact with macOS 0.2.2.
    let Some((history_url, quote_url)) = shared::stock_urls(ticker) else {
        // A ticker the ABI refuses to address (over its 256-byte bound, or
        // not UTF-8) is the same "no data" state macOS shows for it.
        return reading(StockStatus::BadResponse, None, None, Vec::new());
    };
    let history = match fetch(&history_url) {
        Ok(bytes) => bytes,
        Err(_) => return reading(StockStatus::NetworkError, None, None, Vec::new()),
    };
    let quote = match fetch(&quote_url) {
        Ok(bytes) => bytes,
        Err(_) => return reading(StockStatus::NetworkError, None, None, Vec::new()),
    };
    let history_chart = shared::stock_history(&history).filter(|_| history.len() <= RESPONSE_LIMIT);
    let quote_chart = shared::stock_quote(&quote).filter(|_| quote.len() <= RESPONSE_LIMIT);
    let closes = history_chart
        .as_ref()
        .and_then(|chart| chart.closes.clone())
        .unwrap_or_default();
    let status = if !closes.is_empty()
        || quote_chart
            .as_ref()
            .is_some_and(|chart| chart.price.is_some() && chart.change.is_some())
    {
        StockStatus::Ok
    } else if refused_not_found(&history) || refused_not_found(&quote) {
        StockStatus::NotFound
    } else {
        StockStatus::BadResponse
    };
    // The current value is the quote's, or macOS's fallback: the last two
    // daily closes (XRGStock.getCurrentPriceAndChange).
    let (price, change) = match quote_chart
        .as_ref()
        .and_then(|chart| chart.price.zip(chart.change))
    {
        Some((price, change)) => (Some(price), Some(change)),
        None => match closes.as_slice() {
            // `[.., previous, last]`: the final close is the price and the
            // change is final minus its predecessor, exactly as macOS
            // `getCurrentPriceAndChange` computes. (The reversed binding
            // made the penultimate close the price and negated the change.)
            [.., previous, last] => (Some(*last), Some(last - previous)),
            _ => (None, None),
        },
    };
    reading(status, price, change, closes)
}

/// Yahoo answers an unknown symbol with a chart error envelope; any other
/// response the shared core refuses is unreadable, not unknown. Only the
/// envelope's presence is read here — the chart data itself never is.
fn refused_not_found(bytes: &[u8]) -> bool {
    serde_json::from_slice::<serde_json::Value>(bytes)
        .ok()
        .and_then(|value| {
            value
                .get("chart")
                .and_then(|chart| chart.get("error"))
                .map(|error| !error.is_null())
        })
        == Some(true)
}

/// How much history the chart shows, as macOS slices it: the last
/// `count / (12 / months)` closes of the one-year history
/// (`XRGStock.get1MonthValues` and friends). A history shorter than the
/// period slices to nothing, exactly as macOS's suffix does.
fn slice(closes: &[f64], timeframe: u32) -> Vec<f64> {
    let divisor = match timeframe {
        1 => 12,
        3 => 4,
        6 => 2,
        _ => 1,
    };
    let keep = closes.len() / divisor;
    let start = closes.len().saturating_sub(keep);
    closes[start..].to_vec()
}

/// The timeframe's footer text, exactly as macOS names it.
fn timeframe_text(timeframe: u32) -> &'static str {
    match timeframe {
        1 => "1m",
        3 => "3m",
        6 => "6m",
        _ => "1y",
    }
}

fn timeframe_words(timeframe: u32) -> &'static str {
    match timeframe {
        1 => "1 month",
        3 => "3 months",
        6 => "6 months",
        _ => "12 months",
    }
}

/// The macOS curve bounds: the period's range padded 10% each way
/// (`XRGStockView.plots`). A flat series keeps one cent of padding, so the
/// bounds stay a displayable range instead of collapsing to nothing.
fn curve_bounds(closes: &[f64]) -> Option<(f64, f64)> {
    let low = closes.iter().copied().reduce(f64::min)?;
    let high = closes.iter().copied().reduce(f64::max)?;
    let padding = ((high - low) * 0.1).max(0.01);
    Some((low - padding, high + padding))
}

/// The stocks curve's equally spaced positions, the way macOS draws curve
/// samples across the graph.
fn positions(count: usize) -> Vec<f64> {
    (0..count)
        .map(|index| index as f64 / count.saturating_sub(1).max(1) as f64)
        .collect()
}

/// The dashboard's Stocks panel: the rotating ticker's filled curve, the
/// Dow as a secondary line, the quote rows and the failure states, drawn
/// from the dashboard theme exactly like the weather graph's curves.
#[derive(Default)]
pub struct Graph {
    phase: usize,
    switched: Option<Instant>,
}
impl Graph {
    pub fn clear_graph(&mut self) {
        self.switched = None;
    }
    /// Position the rotating ticker at one index (tests and diagnostics);
    /// the next timed tick keeps rotating from here.
    pub fn set_phase(&mut self, phase: usize) {
        self.phase = phase;
        self.switched = Some(Instant::now());
    }
    pub fn panel(&mut self, update: Option<&Update>) -> Panel {
        let mut panel = Panel {
            title: "Stocks",
            label: "Stocks off".into(),
            detail: "The Stocks graph is off. Enable the stock graph in the Graphs \
                     settings; XRG-ng makes no stock requests while it is off."
                .into(),
            series: Vec::new(),
            scale: Scale::Automatic,
            temperature_text: None,
            weather_plot: None,
            readout: Readout::default(),
        };
        let Some(update) = update else {
            return panel;
        };
        let symbols = parse_symbols(&update.settings.symbols);
        if symbols.is_empty() {
            panel.label = "No Stocks Found".into();
            panel.detail = "No ticker symbols are configured. Add comma-separated \
                            symbols in the Stocks settings."
                .into();
            return panel;
        }
        let reading = |ticker: &str| {
            update
                .readings
                .iter()
                .find(|reading| reading.ticker == *ticker)
        };
        let djia = update.settings.show_djia.then_some(DJIA).and_then(reading);
        // macOS shows Fetching Data and draws no curve while any ticker of
        // the list is still loading (XRGStockView.gettingData).
        if symbols.iter().any(|ticker| reading(ticker).is_none())
            || (update.settings.show_djia && djia.is_none())
        {
            panel.label = "Fetching Data".into();
            panel.detail = "Fetching the chart data. The graph draws as soon as every \
                            ticker's response has arrived; nothing else is stalled by it."
                .into();
            return panel;
        }
        // The rotation macOS shows: the next ticker every 30 seconds,
        // starting with the list's first ticker.
        let now = Instant::now();
        match self.switched {
            Some(switched) if now.duration_since(switched) >= ROTATE => {
                self.switched = Some(now);
                self.phase = self.phase.wrapping_add(1);
            }
            None => self.switched = Some(now),
            _ => (),
        }
        let selected_index = self.phase % symbols.len();
        let selected =
            reading(&symbols[selected_index]).expect("settled readings cover every symbol");
        if let Some(djia) = djia {
            panel
                .readout
                .bottom
                .push(Row::new("DJIA", price_string(djia.price)));
        }
        panel.readout.bottom.push(Row::new(
            "Period",
            timeframe_text(update.settings.timeframe),
        ));
        // macOS starts the visible quote rows at the displayed ticker
        // (`stockToShow`), so the rotating curve's own quote is never
        // clipped away when the list is longer than the panel holds.
        for index in (selected_index..symbols.len()).chain(0..selected_index) {
            let ticker = &symbols[index];
            let Some(reading) = reading(ticker) else {
                continue;
            };
            panel
                .readout
                .top
                .push(Row::new(ticker, price_string(reading.price)));
            if update.settings.show_change {
                panel
                    .readout
                    .top
                    .push(Row::new("", change_string(reading.change)));
            }
            // `panel.label` is not painted while quote rows exist, so a
            // failed ticker's status must appear in the readout itself.
            if reading.status != StockStatus::Ok {
                panel
                    .readout
                    .top
                    .push(Row::new("Status", failure_label(reading.status)));
            }
        }
        let change = if update.settings.show_change && selected.change.is_some() {
            format!(" {}", change_string(selected.change))
        } else {
            String::new()
        };
        panel.label = match selected.status {
            StockStatus::Ok => {
                format!(
                    "{} · {}{change}",
                    selected.ticker,
                    price_string(selected.price)
                )
            }
            StockStatus::NotFound => format!("{} · not found", selected.ticker),
            StockStatus::NetworkError => format!("{} · network error{change}", selected.ticker),
            StockStatus::BadResponse => format!("{} · bad response", selected.ticker),
        };
        panel.detail = detail(&update.settings, &update.readings, &symbols);
        // The filled curve of the rotating ticker, and the Dow as macOS's
        // unfilled secondary curve, each scaled to its own padded range.
        // Retained closes stay drawn through a failure (NetworkError keeps
        // the last values): only an empty slice has no bounds, so the
        // error/stale label above still reports the failure state.
        if let Some((lower, upper)) =
            curve_bounds(&slice(&selected.closes, update.settings.timeframe))
        {
            panel.scale = Scale::Stocks { lower, upper };
            panel
                .series
                .push(slice(&selected.closes, update.settings.timeframe));
            let mut secondary = None;
            if let Some(djia) = djia {
                let sliced = slice(&djia.closes, update.settings.timeframe);
                if let Some((lower, upper)) = curve_bounds(&sliced) {
                    secondary = Some(crate::weather::SecondaryAxis {
                        lower,
                        upper,
                        label: "Dow Jones Industrial Average".into(),
                    });
                    panel.series.push(sliced);
                }
            }
            panel.weather_plot = Some(crate::weather::ObservationPlot {
                positions: positions(panel.series[0].len()),
                secondary,
                range_label: format!(
                    "the last {} of daily closes",
                    timeframe_words(update.settings.timeframe)
                ),
            });
        }
        panel
    }
}

/// The short status label shown in the readout for a failed ticker.
fn failure_label(status: StockStatus) -> &'static str {
    match status {
        StockStatus::Ok => "ok",
        StockStatus::NotFound => "not found",
        StockStatus::NetworkError => "network error",
        StockStatus::BadResponse => "bad response",
    }
}

/// The full reading, the way macOS's `fullReading` assembles it, plus the
/// per-ticker failure states.
fn detail(settings: &StockSettings, readings: &[StockReading], symbols: &[String]) -> String {
    let mut lines = vec![
        "Source: Yahoo Finance chart API · query1.finance.yahoo.com".into(),
        "One-year daily closes and a 15-minute intraday quote; XRG-ng refreshes \
         them every 2 hours, and the Dow joins while Show DJIA is on."
            .into(),
    ];
    let reading = |ticker: &str| readings.iter().find(|reading| reading.ticker == ticker);
    for ticker in symbols {
        let Some(reading) = reading(ticker) else {
            continue;
        };
        let line = match reading.status {
            StockStatus::Ok => {
                let change = if settings.show_change && reading.change.is_some() {
                    format!(" {}", change_string(reading.change))
                } else {
                    String::new()
                };
                format!("{ticker}: {}{change}", price_string(reading.price))
            }
            StockStatus::NotFound => {
                format!("{ticker}: not found — the symbol may be delisted")
            }
            StockStatus::NetworkError => {
                format!(
                    "{ticker}: network error — the last values stay on screen until the next refresh"
                )
            }
            StockStatus::BadResponse => {
                format!("{ticker}: bad response — the chart data could not be read")
            }
        };
        lines.push(line);
    }
    if settings.show_djia
        && let Some(djia) = reading(DJIA)
    {
        lines.push(format!("DJIA: {}", price_string(djia.price)));
    }
    lines.push(format!(
        "Period: {} ({})",
        timeframe_text(settings.timeframe),
        timeframe_words(settings.timeframe)
    ));
    lines.join("\n\n")
}
