// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Optional AI monitoring. A separate worker prevents scans/SQLite/local APIs
//! from delaying system collection or GTK. Tests inject roots and API responses.
pub mod database;
pub mod logs;
mod preferences;
use crate::{
    command::BoundedCommand,
    engine::{Panel, Scale},
    shared::{self, History, Rates, Usage},
};
pub use preferences::{ClaudeSource, Preferences, validate_url};
use std::{
    path::{Path, PathBuf},
    sync::{Arc, Mutex, mpsc},
    thread,
    time::{Duration, Instant},
};

#[derive(Clone, Debug)]
pub struct Reading {
    pub usage: Usage,
    pub cost: Option<f64>,
    pub source: String,
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
                    usage: Usage {
                        total,
                        ..Usage::default()
                    },
                    cost,
                    source: "Claude local OTel metrics".into(),
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
        self.scans[index].scan().map(|usage| Reading {
            usage,
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
    source: String,
    previous: Option<Reading>,
}
pub struct Display {
    counters: [Counter; 4],
    history: History,
    preferences: Option<Preferences>,
}
impl Default for Display {
    fn default() -> Self {
        Self {
            counters: std::array::from_fn(|_| Counter {
                rates: Rates::new(),
                source: String::new(),
                previous: None,
            }),
            history: History::new(120),
            preferences: None,
        }
    }
}
impl Display {
    pub fn panel(&mut self, report: Report, time: f64) -> Panel {
        self.panel_for(report, time, &Preferences::default())
    }
    pub fn panel_for(&mut self, report: Report, time: f64, preferences: &Preferences) -> Panel {
        if self.preferences.as_ref() != Some(preferences) {
            *self = Self::default();
            self.preferences = Some(preferences.clone());
        }
        let mut detail = vec!["Token totals cover locally retained logs/database rows, not account billing. Graph: observed token-counter change per second, sampled every 5 s; log writes may arrive in bursts. Costs are shown only when recorded by the source.".to_owned()];
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
                    if counter.source != reading.source {
                        counter.rates = Rates::new();
                        counter.source = reading.source.clone();
                    }
                    let (_, current) = counter.rates.sample(0, reading.usage.total, time);
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
        Panel {
            title: "AI tokens",
            label,
            series: if count == 0 {
                Vec::new()
            } else {
                vec![self.history.values()]
            },
            scale: Scale::Automatic,
            detail: detail.join("\n\n"),
        }
    }
}
#[derive(Clone, Default)]
pub struct Control(Arc<Mutex<Option<Preferences>>>);
impl Control {
    pub fn set(&self, preferences: Preferences) -> Result<(), String> {
        preferences.validate()?;
        *self.0.lock().unwrap() = Some(preferences);
        Ok(())
    }
}
#[derive(Clone, Debug)]
pub struct Update {
    pub preferences: Preferences,
    pub panel: Panel,
    pub report: Arc<Report>,
    pub detail: String,
}
fn report_detail(report: &Report, preferences: &Preferences, panel: &Panel) -> String {
    let mut text = vec![panel.detail.clone()];
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
        detail: "AI usage collection runs independently of system collection.".into(),
    }
}
pub struct Worker {
    pub latest: Arc<Mutex<Option<Update>>>,
    stop: Option<mpsc::Sender<()>>,
    join: Option<thread::JoinHandle<()>>,
}
impl Worker {
    pub fn start(config: Config) -> Self {
        Self::with_api(config, CurlApi::default())
    }
    fn with_api(config: Config, api: impl LocalApi + Send + 'static) -> Self {
        Self::controlled_with_api(config, Preferences::default(), Control::default(), api)
    }
    pub fn controlled(config: Config, preferences: Preferences, control: Control) -> Self {
        Self::controlled_with_api(config, preferences, control, CurlApi::default())
    }
    fn controlled_with_api(
        config: Config,
        mut preferences: Preferences,
        control: Control,
        mut api: impl LocalApi + Send + 'static,
    ) -> Self {
        preferences.validate().expect("Validated AI preferences");
        let latest = Arc::new(Mutex::new(None));
        let output = latest.clone();
        let (stop, receiver) = mpsc::channel();
        let join = thread::spawn(move || {
            let mut collector = Collector::configured(config.clone(), preferences.clone())
                .expect("Validated AI preferences");
            let mut display = Display::default();
            let start = Instant::now();
            loop {
                let next = Instant::now() + Duration::from_secs(5);
                if let Some(next) = control.0.lock().unwrap().take() {
                    preferences = next;
                    collector = Collector::configured(config.clone(), preferences.clone())
                        .expect("Validated AI update");
                    display = Display::default();
                }
                let report = collector.sample(&mut api);
                let panel =
                    display.panel_for(report.clone(), start.elapsed().as_secs_f64(), &preferences);
                let detail = report_detail(&report, &preferences, &panel);
                *output.lock().unwrap() = Some(Update {
                    preferences: preferences.clone(),
                    panel,
                    detail,
                    report: Arc::new(report),
                });
                match receiver.recv_timeout(next.saturating_duration_since(Instant::now())) {
                    Err(mpsc::RecvTimeoutError::Timeout) => (),
                    _ => break,
                }
            }
        });
        Self {
            latest,
            stop: Some(stop),
            join: Some(join),
        }
    }
}
impl Drop for Worker {
    fn drop(&mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
        if let Some(join) = self.join.take() {
            join.join().expect("AI worker panicked");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        io::{Read, Write},
        net::TcpListener,
    };
    #[test]
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
