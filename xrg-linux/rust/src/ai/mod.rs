// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Optional AI monitoring. A separate worker prevents scans/SQLite/local APIs
//! from delaying system collection or the UI. Tests inject roots and API responses.
pub mod accounting;
pub mod database;
#[cfg(target_os = "linux")]
pub mod desktop_alert;
#[cfg(not(target_os = "linux"))]
#[path = "desktop_alert_stub.rs"]
pub mod desktop_alert;
pub mod logs;
mod models;
mod preferences;
use crate::{
    command::BoundedCommand,
    engine::{Panel, Scale},
    shared::{self, History, Rates, Usage},
};
pub use models::ModelUsage;
pub use preferences::{ClaudeSource, Preferences, validate_url};
use std::{
    path::{Path, PathBuf},
    sync::{Arc, Mutex, mpsc},
    thread,
    time::{Duration, Instant},
};

#[derive(Clone, Debug)]
pub struct Reading {
    pub continuity: u64,
    pub usage: Usage,
    pub cost: Option<f64>,
    pub source: String,
    pub models: Option<Vec<ModelUsage>>,
}
impl Reading {
    fn accounting_source(&self) -> String {
        format!("{}:{}:{}", self.source.len(), self.source, self.continuity)
    }
}
#[derive(Clone, Debug)]
pub struct Report {
    pub providers: [Result<Reading, String>; 4],
    pub ollama: String,
    pub models: Models,
}
#[derive(Clone, Debug)]
pub struct Models {
    pub installed: Result<Vec<String>, String>,
    pub running: Result<Vec<String>, String>,
}
impl Default for Models {
    fn default() -> Self {
        Self {
            installed: Err("Model inventory unavailable".into()),
            running: Err("Loaded models unavailable".into()),
        }
    }
}
#[derive(Clone)]
pub struct Config {
    pub home: PathBuf,
}
impl Config {
    pub fn live() -> Option<Self> {
        std::env::var_os("HOME").map(|home| Self { home: home.into() })
    }
}
#[derive(Clone, Copy)]
pub enum Endpoint {
    Metrics,
    Models,
    Running,
}
pub trait LocalApi {
    fn get(&mut self, endpoint: Endpoint) -> Result<Vec<u8>, String>;
    fn configure(&mut self, preferences: &Preferences) -> Result<(), String> {
        preferences.validate()
    }
}
#[derive(Default)]
pub struct CurlApi {
    command: BoundedCommand,
    preferences: Preferences,
}
impl LocalApi for CurlApi {
    fn get(&mut self, endpoint: Endpoint) -> Result<Vec<u8>, String> {
        let url = match endpoint {
            Endpoint::Metrics => self.preferences.metrics_url.clone(),
            Endpoint::Models => format!(
                "{}/api/tags",
                self.preferences.ollama_url.trim_end_matches('/')
            ),
            Endpoint::Running => format!(
                "{}/api/ps",
                self.preferences.ollama_url.trim_end_matches('/')
            ),
        };
        self.fetch(&url)
    }
    fn configure(&mut self, preferences: &Preferences) -> Result<(), String> {
        preferences.validate()?;
        self.preferences = preferences.clone();
        Ok(())
    }
}
impl CurlApi {
    fn fetch(&mut self, url: &str) -> Result<Vec<u8>, String> {
        // -q first disables user curl config; no redirects, proxies or non-HTTP
        // protocols. Both child lifetime and output are bounded independently.
        self.command.output(
            Path::new("curl"),
            &[
                "-q",
                "--silent",
                "--globoff",
                "--fail",
                "--noproxy",
                "*",
                "--proto",
                "=http",
                "--max-time",
                "0.5",
                url,
            ],
            Duration::from_millis(650),
            1_048_576,
        )
    }
}
pub struct Collector {
    config: Config,
    preferences: Preferences,
    scans: [logs::LogScan; 3],
}
impl Collector {
    pub fn new(config: Config) -> Self {
        Self::configured(config, Preferences::default()).expect("Default AI preferences")
    }
    pub fn configured(config: Config, preferences: Preferences) -> Result<Self, String> {
        preferences.validate()?;
        use logs::Layout;
        let paths = preferences.paths(&config.home);
        let scans = [
            logs::LogScan::new(paths[0].clone(), Layout::Claude),
            logs::LogScan::new(paths[2].clone(), Layout::Codex),
            logs::LogScan::new(paths[3].clone(), Layout::Gemini),
        ];
        Ok(Self {
            config,
            preferences,
            scans,
        })
    }
    pub fn sample(&mut self, api: &mut impl LocalApi) -> Report {
        if let Err(error) = api.configure(&self.preferences) {
            return Report {
                providers: std::array::from_fn(|_| Err(error.clone())),
                ollama: error,
                models: Models::default(),
            };
        }
        let paths = self.preferences.paths(&self.config.home);
        let claude_root = &paths[0];
        let claude_db = &paths[1];
        // Source priority is exclusive. Never add transcript, database and OTel
        // views of the same requests together. Errors do not silently switch sources.
        let mode = self.preferences.claude_source;
        let claude = if !self.preferences.enabled[0] {
            Err("Disabled in preferences".into())
        } else if mode == ClaudeSource::Logs
            || (mode == ClaudeSource::Auto && claude_root.try_exists().unwrap_or(true))
        {
            self.logs(0, "Claude JSONL (includes cache input)")
        } else if mode == ClaudeSource::Database
            || (mode == ClaudeSource::Auto && claude_db.try_exists().unwrap_or(true))
        {
            database::snapshot(claude_db, false)
        } else {
            api.get(Endpoint::Metrics).and_then(|bytes| {
                let text = std::str::from_utf8(&bytes).map_err(|_| "Invalid metrics UTF-8")?;
                // Accept only Claude's metric namespace, never unrelated exporters.
                let filtered = text
                    .lines()
                    .filter(|line| {
                        [
                            "claude_code_token_usage",
                            "claude_code.token.usage",
                            "claude_code_cost_usage",
                            "claude_code.cost.usage",
                        ]
                        .iter()
                        .any(|prefix| line.starts_with(prefix))
                    })
                    .collect::<Vec<_>>()
                    .join("\n");
                let (total, cost) =
                    shared::metrics_sample(&filtered).ok_or("No valid Claude token samples")?;
                Ok(Reading {
                    continuity: 0,
                    usage: Usage {
                        total,
                        ..Usage::default()
                    },
                    cost,
                    source: "Claude local OTel metrics".into(),
                    models: None,
                })
            })
        };
        let codex = if self.preferences.enabled[1] {
            self.logs(1, "Codex cumulative session totals")
        } else {
            Err("Disabled in preferences".into())
        };
        let gemini = if self.preferences.enabled[2] {
            self.logs(2, "Gemini saved sessions")
        } else {
            Err("Disabled in preferences".into())
        };
        let hermes = if self.preferences.enabled[3] {
            database::snapshot(&paths[4], true)
        } else {
            Err("Disabled in preferences".into())
        };
        let mut inventory = Models::default();
        let ollama = if !self.preferences.ollama {
            "Ollama: disabled in preferences".into()
        } else {
            inventory.installed = api
                .get(Endpoint::Models)
                .and_then(|b| shared::model_names(&b).ok_or("Invalid model list".into()));
            inventory.running = api
                .get(Endpoint::Running)
                .and_then(|b| shared::model_names(&b).ok_or("Invalid running-model list".into()));
            match (&inventory.installed, &inventory.running) {
                (Ok(models), Ok(running)) => format!(
                    "Ollama: {} installed, {} loaded{} · no lifetime token counter exposed",
                    models.len(),
                    running.len(),
                    model_summary(running)
                ),
                (Ok(models), Err(_)) => format!(
                    "Ollama: {} installed · loaded models unavailable · no token counter exposed",
                    models.len()
                ),
                (Err(_), Ok(running)) => format!(
                    "Ollama: installed models unavailable · {} loaded{} · no token counter exposed",
                    running.len(),
                    model_summary(running)
                ),
                (Err(_), Err(_)) => "Ollama: unavailable · no token counter exposed".into(),
            }
        };
        Report {
            providers: [claude, codex, gemini, hermes],
            ollama,
            models: inventory,
        }
    }
    fn logs(&mut self, index: usize, source: &str) -> Result<Reading, String> {
        self.scans[index].scan_details().map(|scan| Reading {
            continuity: scan.continuity,
            usage: scan.usage,
            models: scan.models,
            cost: None,
            source: source.into(),
        })
    }
}

fn model_summary(names: &[String]) -> String {
    if names.is_empty() {
        String::new()
    } else {
        format!(
            " ({})",
            names
                .iter()
                .take(8)
                .map(|s| s.chars().take(80).collect::<String>())
                .collect::<Vec<_>>()
                .join(", ")
        )
    }
}

struct Counter {
    rates: Rates,
    source: Option<(String, u64)>,
    previous: Option<Reading>,
}
fn history_description(preferences: &Preferences) -> String {
    if preferences.history_minutes > 0 {
        return format!(
            "AI history: {} minutes ending at latest completed observation; latest value per 5-second bin. Observation timestamps define the window; missing intervals stay gaps.",
            preferences.history_minutes
        );
    }
    let samples = preferences.history_capacity();
    let span = (samples - 1) as f64 * shared::ai_sampling_milliseconds() as f64 / 1000.;
    format!(
        "AI history: {samples} samples; nominal {span:.0} seconds at 5 s cadence. Delays affect actual time coverage. Capacity changes preserve rate baselines and observed accounting."
    )
}
pub struct Display {
    counters: [Counter; 4],
    history: History,
    timed_history: shared::TimedHistory,
    preferences: Option<Preferences>,
}
impl Default for Display {
    fn default() -> Self {
        Self {
            counters: std::array::from_fn(|_| Counter {
                rates: Rates::new(),
                source: None,
                previous: None,
            }),
            history: History::new(120),
            timed_history: shared::TimedHistory::new(1),
            preferences: None,
        }
    }
}
impl Display {
    pub fn clear_graph(&mut self) {
        self.history.clear();
        self.timed_history.clear();
    }
    fn visible_history(&self, preferences: &Preferences) -> Vec<f64> {
        if preferences.history_minutes > 0 {
            self.timed_history
                .values(preferences.history_minutes)
                .remove(0)
        } else {
            self.history.values()
        }
    }
    /// Resize the published observation without sampling rates or accounting again.
    fn resize_cached(&mut self, update: &mut Update, preferences: Preferences, revision: u64) {
        debug_assert!(update.preferences.same_collection(&preferences));
        self.history.resize(preferences.history_capacity());
        self.preferences = Some(preferences.clone());
        if !update.panel.series.is_empty() {
            update.panel.series = vec![self.visible_history(&preferences)];
        }
        update.panel.detail = update.panel.detail.replacen(
            &history_description(&update.preferences),
            &history_description(&preferences),
            1,
        );
        update.preferences = preferences;
        update.control_revision = revision;
        update.detail = report_detail(&update.report, &update.preferences, &update.panel, true);
        update.summary_detail =
            report_detail(&update.report, &update.preferences, &update.panel, false);
    }
    pub fn panel(&mut self, report: Report, time: f64) -> Panel {
        self.panel_for(report, time, &Preferences::default())
    }
    pub fn panel_for(&mut self, report: Report, time: f64, preferences: &Preferences) -> Panel {
        self.panel_at(report, time, time, preferences)
    }
    fn panel_at(
        &mut self,
        report: Report,
        time: f64,
        observed_at: f64,
        preferences: &Preferences,
    ) -> Panel {
        if self
            .preferences
            .as_ref()
            .is_none_or(|p| !p.same_sources(preferences))
        {
            *self = Self::default();
            if preferences.history_samples > 0 {
                self.history.clear();
            }
        }
        self.history.resize(preferences.history_capacity());
        self.preferences = Some(preferences.clone());
        let mut detail = vec!["Token totals cover locally retained logs/database rows, not account billing. Graph: observed token-counter change per second, sampled every 5 s; log writes may arrive in bursts. Costs are shown only when recorded by the source.".to_owned()];
        detail.push(history_description(preferences));
        let mut readout = crate::dashboard::Readout::default();
        readout
            .top
            .push(crate::dashboard::Row::new("AI tokens", "tok/s"));
        let mut count = 0;
        let mut rate = 0u64;
        let mut total = 0u64;
        let mut overflow = false;
        for (index, ((name, reading), counter)) in ["Claude", "Codex", "Gemini", "Hermes"]
            .into_iter()
            .zip(report.providers)
            .zip(&mut self.counters)
            .enumerate()
        {
            if !preferences.enabled[index] {
                detail.push(format!("{name}: disabled in preferences"));
                continue;
            }
            match reading {
                Ok(reading) => {
                    count += 1;
                    let source = (reading.source.clone(), reading.continuity);
                    if counter.source.as_ref() != Some(&source) {
                        counter.rates = Rates::new();
                        counter.source = Some(source);
                    }
                    let (_, current) = counter.rates.sample(0, reading.usage.total, time);
                    readout
                        .top
                        .push(crate::dashboard::Row::new(name, compact(current as u64)));
                    rate += current as u64;
                    if let Some(sum) = total.checked_add(reading.usage.total) {
                        total = sum;
                    } else {
                        overflow = true;
                    }
                    let cost = reading
                        .cost
                        .map(|v| format!(" · source cost ${v:.4}"))
                        .unwrap_or_else(|| " · cost unavailable".into());
                    detail.push(format!(
                        "{name}: {} tokens · {current} tok/s{cost}\n{}",
                        reading.usage.total, reading.source
                    ));
                    counter.previous = Some(reading);
                }
                Err(error) => {
                    readout.top.push(crate::dashboard::Row::new(name, "n/a"));
                    counter.rates = Rates::new();
                    let last = counter
                        .previous
                        .as_ref()
                        .map(|v| format!(" · last complete total {} (stale)", v.usage.total))
                        .unwrap_or_default();
                    detail.push(format!("{name}: unavailable{last}\n{error}"));
                }
            }
        }
        detail.push(report.ollama);
        let enabled = preferences.enabled.iter().filter(|v| **v).count();
        let label = if enabled == 0 {
            "AI token monitoring disabled".into()
        } else if count == 0 {
            "No readable AI usage sources".into()
        } else {
            self.history.append(rate as f64);
            format!(
                "{} tok/s · {} · {count}/{enabled} sources",
                compact(rate),
                if overflow {
                    "total overflow".into()
                } else {
                    format!("{} tokens", compact(total))
                }
            )
        };
        self.timed_history.append(
            observed_at,
            &[if count > 0 { rate as f64 } else { f64::NAN }],
        );
        Panel {
            title: "AI tokens",
            label,
            series: if count == 0 {
                Vec::new()
            } else {
                vec![self.visible_history(preferences)]
            },
            scale: Scale::Automatic,
            temperature_text: None,
            weather_plot: None,
            readout,
            detail: detail.join("\n\n"),
        }
    }
}
enum Wake {
    Refresh,
    Stop,
}
#[derive(Default)]
struct ControlState {
    preferences: Option<Preferences>,
    session: bool,
    daily: bool,
    revision: u64,
    collection_revision: u64,
    last_preferences: Option<Preferences>,
    wake: Option<mpsc::Sender<Wake>>,
    wake_pending: bool,
}
#[derive(Clone, Default)]
pub struct Control(Arc<Mutex<ControlState>>);
impl ControlState {
    fn signal(&mut self, collection: bool) {
        self.revision = self.revision.wrapping_add(1);
        if collection {
            self.collection_revision = self.collection_revision.wrapping_add(1);
        }
        if !self.wake_pending {
            if let Some(wake) = &self.wake {
                let _ = wake.send(Wake::Refresh);
            }
            self.wake_pending = true;
        }
    }
}
impl Control {
    pub fn set(&self, preferences: Preferences) -> Result<(), String> {
        preferences.validate()?;
        let mut state = self.0.lock().unwrap();
        let history_only = state.last_preferences.as_ref().is_some_and(|previous| {
            (previous.history_samples != preferences.history_samples
                || previous.history_minutes != preferences.history_minutes)
                && previous.same_collection(&preferences)
        });
        state.last_preferences = Some(preferences.clone());
        state.preferences = Some(preferences);
        state.signal(!history_only);
        Ok(())
    }
    pub fn reset_session(&self) {
        let mut state = self.0.lock().unwrap();
        state.session = true;
        state.signal(true);
    }
    pub fn reset_daily(&self) {
        let mut state = self.0.lock().unwrap();
        state.daily = true;
        state.signal(true);
    }
    pub fn revision(&self) -> u64 {
        self.0.lock().unwrap().revision
    }
    fn collection_revision(&self) -> u64 {
        self.0.lock().unwrap().collection_revision
    }
}
#[derive(Clone, Debug)]
pub struct Update {
    pub preferences: Preferences,
    pub graph_generation: u64,
    pub control_revision: u64,
    pub accounting: accounting::Snapshot,
    pub panel: Panel,
    pub report: Arc<Report>,
    pub detail: String,
    summary_detail: String,
}
impl Update {
    pub fn new(preferences: Preferences, panel: Panel, report: Report) -> Self {
        let detail = report_detail(&report, &preferences, &panel, true);
        let summary_detail = report_detail(&report, &preferences, &panel, false);
        Self {
            preferences,
            graph_generation: 0,
            control_revision: 0,
            accounting: accounting::Snapshot::default(),
            panel,
            detail,
            summary_detail,
            report: Arc::new(report),
        }
    }
    pub fn detail_for(&self, show_models: bool) -> &str {
        if show_models {
            &self.detail
        } else {
            &self.summary_detail
        }
    }
}
fn report_detail(
    report: &Report,
    preferences: &Preferences,
    panel: &Panel,
    show_models: bool,
) -> String {
    let mut text = vec![panel.detail.clone()];
    for (index, name) in ["Claude", "Codex", "Gemini", "Hermes"].iter().enumerate() {
        if !show_models || !preferences.enabled[index] {
            continue;
        }
        let Ok(reading) = &report.providers[index] else {
            continue;
        };
        match &reading.models {
            None => text.push(format!(
                "{name}: per-model token attribution unavailable for this source."
            )),
            Some(rows) => {
                let mut lines = vec![format!("{name} token totals by model ({}):", rows.len())];
                if rows.is_empty() {
                    lines.push("No recorded model usage.".into());
                }
                if index == 1 {
                    lines.push(
                        "Attributed to recorded turn models; ambiguous usage remains unattributed."
                            .into(),
                    );
                }
                for row in rows.iter().take(128) {
                    let name = row
                        .model
                        .as_ref()
                        .map(|m| format!("{m:?}"))
                        .unwrap_or_else(|| {
                            if index == 1 {
                                "Unattributed (ambiguous or missing model evidence)".into()
                            } else {
                                "Unattributed (model not recorded or invalid)".into()
                            }
                        });
                    let cost = row
                        .cost
                        .map(|v| format!("source cost ${v:.4}"))
                        .unwrap_or_else(|| "cost unavailable".into());
                    if index == 1 {
                        lines.push(format!(
                            "{name}: {} total · input/output attribution unavailable · {cost}",
                            row.usage.total
                        ));
                    } else {
                        lines.push(format!(
                            "{name}: {} total · {} input · {} output · {cost}",
                            row.usage.total, row.usage.input, row.usage.output
                        ));
                    }
                }
                if rows.len() > 128 {
                    lines.push(format!(
                        "Additional model rows omitted: {}. Provider totals include all models.",
                        rows.len() - 128
                    ));
                }
                text.push(lines.join("\n"));
            }
        }
    }
    if preferences.ollama {
        for (title, models) in [
            ("Installed Ollama models", &report.models.installed),
            ("Loaded Ollama models", &report.models.running),
        ] {
            match models {
                Ok(names) => text.push(format!(
                    "{title} ({}):\n{}",
                    names.len(),
                    if names.is_empty() {
                        "none".into()
                    } else {
                        names
                            .iter()
                            .take(128)
                            .map(|s| s.chars().take(256).collect::<String>())
                            .collect::<Vec<_>>()
                            .join("\n")
                    }
                )),
                Err(error) => text.push(format!("{title}: unavailable\n{error}")),
            }
        }
        text.push("Model lists are inventories, not inference counts or per-model token usage. At most 128 names per list are displayed.".into());
    }
    text.join("\n\n")
}
fn compact(value: u64) -> String {
    for (unit, divisor) in [
        ("E", 1e18),
        ("P", 1e15),
        ("T", 1e12),
        ("G", 1e9),
        ("M", 1e6),
        ("k", 1e3),
    ] {
        if value as f64 >= divisor {
            return format!("{:.1}{unit}", value as f64 / divisor);
        }
    }
    value.to_string()
}
pub fn waiting() -> Panel {
    Panel {
        title: "AI tokens",
        label: "Waiting for AI sources".into(),
        series: Vec::new(),
        scale: Scale::Automatic,
        temperature_text: None,
        weather_plot: None,
        readout: Default::default(),
        detail: "AI usage collection runs independently of system collection.".into(),
    }
}
pub struct Worker {
    pub latest: Arc<Mutex<Option<Update>>>,
    graph_generation: Arc<std::sync::atomic::AtomicU64>,
    stop: Option<mpsc::Sender<Wake>>,
    join: Option<thread::JoinHandle<()>>,
}
impl Worker {
    pub fn clear_graph(&self) -> u64 {
        self.graph_generation
            .fetch_add(1, std::sync::atomic::Ordering::AcqRel)
            .wrapping_add(1)
    }
    pub fn start(config: Config) -> Self {
        Self::with_api(config, CurlApi::default())
    }
    fn with_api(config: Config, api: impl LocalApi + Send + 'static) -> Self {
        Self::controlled_with_api(config, Preferences::default(), Control::default(), api)
    }
    pub fn controlled(config: Config, preferences: Preferences, control: Control) -> Self {
        Self::controlled_impl(
            config,
            preferences,
            control,
            CurlApi::default(),
            accounting::state_path(),
            desktop_alert::send,
        )
    }
    fn controlled_with_api(
        config: Config,
        preferences: Preferences,
        control: Control,
        api: impl LocalApi + Send + 'static,
    ) -> Self {
        Self::controlled_impl(config, preferences, control, api, None, |_| Ok(()))
    }
    fn controlled_impl(
        config: Config,
        mut preferences: Preferences,
        control: Control,
        mut api: impl LocalApi + Send + 'static,
        state_path: Option<PathBuf>,
        mut notify: impl FnMut(f64) -> Result<(), String> + Send + 'static,
    ) -> Self {
        preferences.validate().expect("Validated AI preferences");
        let latest = Arc::new(Mutex::new(None));
        let output = latest.clone();
        let graph_generation = Arc::new(std::sync::atomic::AtomicU64::new(0));
        let graph_updates = graph_generation.clone();
        let (stop, receiver) = mpsc::channel();
        {
            let mut state = control.0.lock().unwrap();
            state.wake = Some(stop.clone());
            state
                .last_preferences
                .get_or_insert_with(|| preferences.clone());
        }
        let join = thread::spawn(move || {
            let mut collector = Collector::configured(config.clone(), preferences.clone())
                .expect("Validated AI preferences");
            let mut display = Display::default();
            let start = Instant::now();
            let mut generation = 0;
            let mut accountant: Option<accounting::Accountant> = None;
            let mut cached: Option<Update> = None;
            let mut last_collection_revision = 0;
            let mut next = Instant::now();
            loop {
                let (
                    requested_preferences,
                    session_reset,
                    daily_reset,
                    revision,
                    collection_revision,
                ) = {
                    let mut state = control.0.lock().unwrap();
                    while let Ok(message) = receiver.try_recv() {
                        if matches!(message, Wake::Stop) {
                            return;
                        }
                    }
                    state.wake_pending = false;
                    (
                        state.preferences.take(),
                        std::mem::take(&mut state.session),
                        std::mem::take(&mut state.daily),
                        state.revision,
                        state.collection_revision,
                    )
                };
                let presentation_update = requested_preferences.is_some();
                if let Some(next) = requested_preferences {
                    if !preferences.same_sources(&next) {
                        collector = Collector::configured(config.clone(), next.clone())
                            .expect("Validated AI update");
                        display = Display::default();
                    }
                    preferences = next;
                }
                if collection_revision == last_collection_revision
                    && !session_reset
                    && !daily_reset
                    && Instant::now() < next
                    && let Some(update) = cached.as_mut()
                {
                    if presentation_update {
                        let requested = graph_updates.load(std::sync::atomic::Ordering::Acquire);
                        if requested != generation {
                            display.clear_graph();
                            generation = requested;
                        }
                        display.resize_cached(update, preferences.clone(), revision);
                        update.graph_generation = generation;
                        if control.revision() == revision {
                            *output.lock().unwrap() = Some(update.clone());
                        }
                    }
                    // Presentation wakes keep the original sample deadline.
                    match receiver.recv_timeout(next.saturating_duration_since(Instant::now())) {
                        Ok(Wake::Refresh) | Err(mpsc::RecvTimeoutError::Timeout) => continue,
                        _ => break,
                    }
                }
                next = Instant::now() + Duration::from_millis(shared::ai_sampling_milliseconds());
                let day = accounting::local_day();
                if (preferences.accounting.enabled || session_reset || daily_reset)
                    && accountant.is_none()
                    && let Ok(day) = &day
                {
                    accountant = Some(accounting::Accountant::open(
                        state_path.clone(),
                        preferences.clone(),
                        day,
                    ));
                }
                if let Some(a) = &mut accountant {
                    a.configure(&preferences);
                    if let Ok(day) = &day {
                        a.reset(session_reset, daily_reset, day);
                    }
                }
                let report = collector.sample(&mut api);
                // Source/accounting changes and resets invalidate an in-flight scan.
                // History edits keep that observation and only resize its cached result.
                if control.collection_revision() != collection_revision {
                    continue;
                }
                let mut counters = accounting::Snapshot::default();
                if let Some(a) = &mut accountant {
                    match accounting::local_day() {
                        Ok(day) => {
                            if let Some(percent) = a.observe(&report, &day)
                                && control.collection_revision() == collection_revision
                            {
                                a.set_notification_status(notify(percent));
                            }
                        }
                        Err(error) => a.break_continuity(error),
                    }
                    counters = a.snapshot();
                } else if preferences.accounting.enabled {
                    counters.enabled = true;
                    counters.persistence_error = day.err();
                }
                let requested = graph_updates.load(std::sync::atomic::Ordering::Acquire);
                if requested != generation {
                    display.clear_graph();
                    generation = requested;
                }
                let observed_at = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|v| v.as_secs_f64())
                    .unwrap_or(f64::NAN);
                let mut panel = display.panel_at(
                    report.clone(),
                    start.elapsed().as_secs_f64(),
                    observed_at,
                    &preferences,
                );
                panel.detail.push_str("\n\n");
                panel
                    .detail
                    .push_str(&counters.detail(&preferences.accounting));
                if counters.enabled {
                    panel.readout.bottom.push(crate::dashboard::Row::new(
                        "Session",
                        compact(counters.session.total()),
                    ));
                    panel.readout.bottom.push(crate::dashboard::Row::new(
                        "Daily",
                        compact(counters.daily.total()),
                    ));
                }
                let mut update = Update::new(preferences.clone(), panel, report);
                update.graph_generation = generation;
                update.control_revision = revision;
                update.accounting = counters;
                last_collection_revision = collection_revision;
                cached = Some(update.clone());
                if control.revision() == revision {
                    *output.lock().unwrap() = Some(update);
                }
                match receiver.recv_timeout(next.saturating_duration_since(Instant::now())) {
                    Ok(Wake::Refresh) | Err(mpsc::RecvTimeoutError::Timeout) => (),
                    _ => break,
                }
            }
        });
        Self {
            latest,
            graph_generation,
            stop: Some(stop),
            join: Some(join),
        }
    }
}
impl Drop for Worker {
    fn drop(&mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(Wake::Stop);
        }
        if let Some(join) = self.join.take() {
            join.join().expect("AI worker panicked");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(all(test, unix))] // Only the bounded-subprocess tests use these.
    use std::{
        io::{Read, Write},
        net::TcpListener,
    };
    #[test]
    #[cfg(all(test, unix))] // Exercises the Unix bounded subprocess runner.
    fn local_http_reader_handles_chunking_and_rejects_error_status() {
        for (response, expected) in [
            (
                "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n3\r\nabc\r\n0\r\n\r\n",
                Some(b"abc".to_vec()),
            ),
            (
                "HTTP/1.1 503 Unavailable\r\nContent-Length: 3\r\nConnection: close\r\n\r\nabc",
                None,
            ),
        ] {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            listener.set_nonblocking(true).unwrap();
            let address = listener.local_addr().unwrap();
            let server = thread::spawn(move || {
                let deadline = Instant::now() + Duration::from_secs(2);
                loop {
                    match listener.accept() {
                        Ok((mut stream, _)) => {
                            stream
                                .set_read_timeout(Some(Duration::from_secs(1)))
                                .unwrap();
                            let mut request = [0; 4096];
                            let _ = stream.read(&mut request);
                            stream.write_all(response.as_bytes()).unwrap();
                            break;
                        }
                        Err(e)
                            if e.kind() == std::io::ErrorKind::WouldBlock
                                && Instant::now() < deadline =>
                        {
                            thread::sleep(Duration::from_millis(5))
                        }
                        Err(e) => panic!("Fixture server accept: {e}"),
                    }
                }
            });
            let result = CurlApi::default().fetch(&format!("http://{address}/fixture"));
            server.join().unwrap();
            assert_eq!(result.ok(), expected);
        }
    }

    #[test]
    fn ai_worker_publishes_fixture_data_and_stop_interrupts_poll_wait() {
        struct FixtureApi;
        impl LocalApi for FixtureApi {
            fn get(&mut self, endpoint: Endpoint) -> Result<Vec<u8>, String> {
                Ok(match endpoint {
                    Endpoint::Metrics => {
                        b"claude_code_token_usage_total{type=\"input\"} 7".to_vec()
                    }
                    _ => br#"{"models":[]}"#.to_vec(),
                })
            }
        }
        let home = std::env::temp_dir().join(format!(
            "xrg-ai-worker-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir(&home).unwrap();
        let worker = Worker::with_api(Config { home: home.clone() }, FixtureApi);
        let deadline = Instant::now() + Duration::from_secs(2);
        let panel = loop {
            if let Some(panel) = worker.latest.lock().unwrap().take() {
                break panel;
            }
            assert!(Instant::now() < deadline, "AI worker did not publish");
            thread::sleep(Duration::from_millis(5));
        };
        assert!(panel.panel.detail.contains("Claude: 7 tokens"));
        let generation = worker.clear_graph();
        let deadline = Instant::now() + Duration::from_secs(7);
        let cleared = loop {
            if let Some(update) = worker.latest.lock().unwrap().take()
                && update.graph_generation == generation
            {
                break update;
            }
            assert!(
                Instant::now() < deadline,
                "AI graph reset was not acknowledged"
            );
            thread::sleep(Duration::from_millis(5));
        };
        assert!(cleared.panel.series[0][..119].iter().all(|v| v.is_nan()));
        assert!(cleared.panel.detail.contains("Claude: 7 tokens"));
        let stop = Instant::now();
        drop(worker);
        assert!(stop.elapsed() < Duration::from_secs(2));
        std::fs::remove_dir_all(home).unwrap();
    }
    #[test]
    fn worker_applies_configuration_on_its_thread_and_rebaselines_same_named_sources() {
        struct FixtureApi {
            total: u64,
        }
        impl LocalApi for FixtureApi {
            fn configure(&mut self, preferences: &Preferences) -> Result<(), String> {
                preferences.validate()?;
                self.total = if preferences.metrics_url.contains("18889") {
                    1000
                } else {
                    10
                };
                Ok(())
            }
            fn get(&mut self, endpoint: Endpoint) -> Result<Vec<u8>, String> {
                assert!(matches!(endpoint, Endpoint::Metrics));
                Ok(format!(
                    "claude_code_token_usage_total{{type=\"input\"}} {}",
                    self.total
                )
                .into_bytes())
            }
        }
        let preferences = Preferences {
            enabled: [true, false, false, false],
            ollama: false,
            claude_source: ClaudeSource::Metrics,
            ..Default::default()
        };
        let control = Control::default();
        let worker = Worker::controlled_with_api(
            Config {
                home: std::env::temp_dir(),
            },
            preferences.clone(),
            control.clone(),
            FixtureApi { total: 0 },
        );
        let receive = |expected: &Preferences| {
            let deadline = Instant::now() + Duration::from_secs(8);
            loop {
                if let Some(update) = worker.latest.lock().unwrap().take()
                    && &update.preferences == expected
                {
                    break update;
                }
                assert!(Instant::now() < deadline, "AI configuration did not arrive");
                thread::sleep(Duration::from_millis(10));
            }
        };
        assert_eq!(
            receive(&preferences).report.providers[0]
                .as_ref()
                .unwrap()
                .usage
                .total,
            10
        );
        let mut invalid = preferences.clone();
        invalid.metrics_url = "http://remote.example/metrics".into();
        assert!(control.set(invalid).is_err());
        let next = Preferences {
            metrics_url: "http://127.0.0.1:18889/metrics".into(),
            ..preferences
        };
        control.set(next.clone()).unwrap();
        let update = receive(&next);
        assert_eq!(
            update.report.providers[0].as_ref().unwrap().usage.total,
            1000
        );
        assert!(update.panel.series[0].iter().all(|v| *v == 0.));
        assert!(update.detail.contains("cost unavailable"));
        let stop = Instant::now();
        drop(worker);
        assert!(stop.elapsed() < Duration::from_secs(2));
    }
    #[test]
    #[cfg(all(test, unix))] // Exercises the Unix bounded subprocess runner.
    fn configured_http_endpoint_reaches_the_requested_loopback_port_and_path() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(2);
            loop {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        stream
                            .set_read_timeout(Some(Duration::from_secs(1)))
                            .unwrap();
                        let mut request = [0; 4096];
                        let n = stream.read(&mut request).unwrap();
                        assert!(
                            String::from_utf8_lossy(&request[..n])
                                .starts_with("GET /custom/metrics ")
                        );
                        stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\nabc").unwrap();
                        break;
                    }
                    Err(e)
                        if e.kind() == std::io::ErrorKind::WouldBlock
                            && Instant::now() < deadline =>
                    {
                        thread::sleep(Duration::from_millis(5))
                    }
                    Err(e) => panic!("HTTP fixture: {e}"),
                }
            }
        });
        let mut api = CurlApi::default();
        api.configure(&Preferences {
            metrics_url: format!("http://{address}/custom/metrics"),
            ..Default::default()
        })
        .unwrap();
        assert_eq!(api.get(Endpoint::Metrics).unwrap(), b"abc");
        server.join().unwrap();
    }
}

#[cfg(all(test, target_os = "linux"))]
mod worker_accounting_tests;
