// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Optional AI monitoring. A separate worker prevents scans/SQLite/local APIs
//! from delaying system collection or GTK. Tests inject roots and API responses.
pub mod database;
pub mod logs;
use crate::{
    command::BoundedCommand,
    engine::{Panel, Scale},
    shared::{self, History, Rates, Usage},
};
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
}
#[derive(Default)]
pub struct CurlApi {
    command: BoundedCommand,
}
impl LocalApi for CurlApi {
    fn get(&mut self, endpoint: Endpoint) -> Result<Vec<u8>, String> {
        let url = match endpoint {
            Endpoint::Metrics => "http://127.0.0.1:8889/metrics",
            Endpoint::Models => "http://127.0.0.1:11434/api/tags",
            Endpoint::Running => "http://127.0.0.1:11434/api/ps",
        };
        self.fetch(url)
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
    scans: [logs::LogScan; 3],
}
impl Collector {
    pub fn new(config: Config) -> Self {
        use logs::Layout;
        let scans = [
            logs::LogScan::new(config.home.join(".claude/projects"), Layout::Claude),
            logs::LogScan::new(config.home.join(".codex/sessions"), Layout::Codex),
            logs::LogScan::new(config.home.join(".gemini/tmp"), Layout::Gemini),
        ];
        Self { config, scans }
    }
    pub fn sample(&mut self, api: &mut impl LocalApi) -> Report {
        let claude_root = self.config.home.join(".claude/projects");
        let claude_db = self.config.home.join(".claude/monitoring/claude_usage.db");
        // Source priority is exclusive. Never add transcript, database and OTel
        // views of the same requests together. Errors do not silently switch sources.
        let claude = if claude_root.try_exists().unwrap_or(true) {
            self.logs(0, "Claude JSONL (includes cache input)")
        } else if claude_db.try_exists().unwrap_or(true) {
            database::snapshot(&claude_db, false)
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
        let codex = self.logs(1, "Codex cumulative session totals");
        let gemini = self.logs(2, "Gemini saved sessions");
        let hermes = database::snapshot(&self.config.home.join(".hermes/state.db"), true);
        let ollama = match api
            .get(Endpoint::Models)
            .and_then(|b| shared::model_names(&b).ok_or("Invalid model list".into()))
        {
            Err(_) => "Ollama: unavailable · no token counter exposed".into(),
            Ok(models) => match api
                .get(Endpoint::Running)
                .and_then(|b| shared::model_names(&b).ok_or("Invalid running-model list".into()))
            {
                Ok(running) => format!(
                    "Ollama: {} installed, {} loaded{} · no lifetime token counter exposed",
                    models.len(),
                    running.len(),
                    if running.is_empty() {
                        String::new()
                    } else {
                        format!(
                            " ({})",
                            running
                                .iter()
                                .take(8)
                                .map(|s| s.chars().take(80).collect::<String>())
                                .collect::<Vec<_>>()
                                .join(", ")
                        )
                    }
                ),
                Err(_) => format!(
                    "Ollama: {} installed · loaded models unavailable · no token counter exposed",
                    models.len()
                ),
            },
        };
        Report {
            providers: [claude, codex, gemini, hermes],
            ollama,
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

struct Counter {
    rates: Rates,
    source: String,
    previous: Option<Reading>,
}
pub struct Display {
    counters: [Counter; 4],
    history: History,
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
        }
    }
}
impl Display {
    pub fn panel(&mut self, report: Report, time: f64) -> Panel {
        let mut detail = vec!["Token totals cover locally retained logs/database rows, not account billing. Graph: observed token-counter change per second, sampled every 5 s; log writes may arrive in bursts. Costs are shown only when recorded by the source.".to_owned()];
        let mut count = 0;
        let mut rate = 0u64;
        let mut total = 0u64;
        let mut overflow = false;
        for ((name, reading), counter) in ["Claude", "Codex", "Gemini", "Hermes"]
            .into_iter()
            .zip(report.providers)
            .zip(&mut self.counters)
        {
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
        let label = if count == 0 {
            "No readable AI usage sources".into()
        } else {
            self.history.append(rate as f64);
            format!(
                "{} tok/s · {} · {count}/4 sources",
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
    pub latest: Arc<Mutex<Option<Panel>>>,
    stop: Option<mpsc::Sender<()>>,
    join: Option<thread::JoinHandle<()>>,
}
impl Worker {
    pub fn start(config: Config) -> Self {
        Self::with_api(config, CurlApi::default())
    }
    fn with_api(config: Config, mut api: impl LocalApi + Send + 'static) -> Self {
        let latest = Arc::new(Mutex::new(None));
        let output = latest.clone();
        let (stop, receiver) = mpsc::channel();
        let join = thread::spawn(move || {
            let mut collector = Collector::new(config);
            let mut display = Display::default();
            let start = Instant::now();
            loop {
                let next = Instant::now() + Duration::from_secs(5);
                let report = collector.sample(&mut api);
                *output.lock().unwrap() =
                    Some(display.panel(report, start.elapsed().as_secs_f64()));
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
        assert!(panel.detail.contains("Claude: 7 tokens"));
        let stop = Instant::now();
        drop(worker);
        assert!(stop.elapsed() < Duration::from_secs(2));
        std::fs::remove_dir_all(home).unwrap();
    }
}
