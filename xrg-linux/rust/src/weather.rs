// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Opt-in station observations; parsing stays in the shared Swift core.
mod graph;
use crate::{
    command::BoundedCommand,
    shared::{self, Metar},
};
pub use graph::{Graph, ObservationPlot, SecondaryAxis};
use serde::{Deserialize, Serialize};
use std::{
    path::Path,
    sync::{Arc, Mutex, mpsc},
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Units {
    #[default]
    Metric,
    Us,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum WindUnits {
    Knots,
    Kmh,
    Mph,
}
impl WindUnits {
    pub fn factor(self) -> f64 {
        match self {
            Self::Knots => 1.,
            Self::Kmh => 1.852,
            Self::Mph => 1.852 / 1.609344,
        }
    }
    pub fn suffix(self) -> &'static str {
        match self {
            Self::Knots => "kt",
            Self::Kmh => "km/h",
            Self::Mph => "mph",
        }
    }
}
#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Secondary {
    #[default]
    None,
    Wind,
    Humidity,
    Visibility,
    Dewpoint,
    Pressure,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default, deny_unknown_fields)]
pub struct Preferences {
    pub enabled: bool,
    pub history_hours: Option<u32>,
    pub secondary: Secondary,
    pub station: String,
    pub units: Units,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub temperature_units: Option<Units>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub distance_units: Option<Units>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pressure_units: Option<Units>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub wind_units: Option<WindUnits>,
    pub refresh_minutes: u32,
}
impl Default for Preferences {
    fn default() -> Self {
        Self {
            enabled: false,
            history_hours: None,
            secondary: Secondary::None,
            station: String::new(),
            units: Units::Metric,
            temperature_units: None,
            distance_units: None,
            pressure_units: None,
            wind_units: None,
            refresh_minutes: 15,
        }
    }
}
impl Preferences {
    pub fn wind_system(&self) -> WindUnits {
        self.wind_units
            .unwrap_or(match self.distance_units.unwrap_or(self.units) {
                Units::Metric => WindUnits::Kmh,
                Units::Us => WindUnits::Mph,
            })
    }
    pub fn validate(&self) -> Result<(), String> {
        if self
            .history_hours
            .is_some_and(|h| ![6, 12, 24].contains(&h))
        {
            return Err("Weather history must be session, 6, 12 or 24 hours".into());
        }
        if !(5..=60).contains(&self.refresh_minutes) {
            return Err("Weather refresh interval must be 5–60 minutes".into());
        }
        if (self.enabled || !self.station.trim().is_empty())
            && shared::metar_station(&self.station).is_none()
        {
            return Err("Enter a four-character ICAO station code, for example KSEA".into());
        }
        Ok(())
    }
}
pub trait Fetcher {
    fn get(&mut self, station: &str) -> Result<Vec<u8>, String>;
}
#[derive(Default)]
pub struct Https {
    command: BoundedCommand,
}
pub fn endpoint(station: &str) -> Result<String, String> {
    let station = shared::metar_station(station).ok_or("Invalid ICAO station")?;
    Ok(format!(
        "https://aviationweather.gov/api/data/metar?ids={station}&format=raw&hours=24"
    ))
}
impl Fetcher for Https {
    fn get(&mut self, station: &str) -> Result<Vec<u8>, String> {
        let url = endpoint(station)?;
        self.command.output(
            Path::new("curl"),
            &[
                "-q",
                "--silent",
                "--fail",
                "--globoff",
                "--noproxy",
                "*",
                "--proto",
                "=https",
                "--connect-timeout",
                "3",
                "--max-time",
                "5",
                "--max-filesize",
                "2097152",
                "--user-agent",
                concat!(
                    "XRG-ng/",
                    env!("CARGO_PKG_VERSION"),
                    " (Linux METAR monitor)"
                ),
                &url,
            ],
            Duration::from_millis(5500),
            2_097_152,
        )
    }
}
#[derive(Clone, Debug)]
pub struct Update {
    pub preferences: Preferences,
    pub observation: Option<Metar>,
    pub history: Vec<Metar>,
    pub reference_time: Option<i64>,
    pub summary: String,
    pub detail: String,
    pub stale: bool,
    pub cooldown_seconds: u64,
}
pub struct Collector {
    preferences: Preferences,
    last: Option<Metar>,
    history: std::collections::BTreeMap<i64, Metar>,
    last_attempt: Option<f64>,
    next_due: f64,
    last_time: Option<f64>,
    refresh_pending: bool,
    error: Option<String>,
}
impl Collector {
    pub fn new(preferences: Preferences) -> Result<Self, String> {
        preferences.validate()?;
        Ok(Self {
            preferences,
            last: None,
            history: Default::default(),
            last_attempt: None,
            next_due: 0.,
            last_time: None,
            refresh_pending: false,
            error: None,
        })
    }
    pub fn configure(&mut self, preferences: Preferences) -> Result<(), String> {
        preferences.validate()?;
        let changed = shared::metar_station(&self.preferences.station)
            != shared::metar_station(&preferences.station)
            || self.preferences.enabled != preferences.enabled;
        if changed {
            self.last = None;
            self.history.clear();
            self.error = None;
            self.next_due = 0.;
            self.refresh_pending = preferences.enabled;
        } else if self.preferences.refresh_minutes != preferences.refresh_minutes {
            self.next_due =
                self.last_attempt.unwrap_or(0.) + preferences.refresh_minutes as f64 * 60.;
        }
        self.preferences = preferences;
        Ok(())
    }
    pub fn sample(
        &mut self,
        time: f64,
        wall: i64,
        refresh: bool,
        fetcher: &mut impl Fetcher,
    ) -> Update {
        if !time.is_finite()
            || time < 0.
            || self.last_time.is_some_and(|old| time < old)
            || !(0..=253_402_300_799).contains(&wall)
        {
            return self.update(wall, 0, Some("Weather clock unavailable or regressed"));
        }
        self.last_time = Some(time);
        if !self.preferences.enabled {
            self.refresh_pending = false;
            return self.update(wall, 0, None);
        }
        self.refresh_pending |= refresh;
        let cooldown = self
            .last_attempt
            .map_or(0., |last| (last + 60. - time).max(0.));
        if (time >= self.next_due || self.refresh_pending) && cooldown == 0. {
            let station =
                shared::metar_station(&self.preferences.station).expect("Validated station");
            self.last_attempt = Some(time);
            self.next_due = time + self.preferences.refresh_minutes as f64 * 60.;
            self.refresh_pending = false;
            match fetcher.get(&station).and_then(|bytes| {
                if bytes.len() > 2_097_152 {
                    return Err("Weather response exceeds 2 MiB".into());
                }
                shared::metar_history(&bytes, &station, wall)
                    .ok_or("No matching METAR within the 36-hour observation window".into())
            }) {
                Ok(history) => {
                    let report = history.last().expect("Nonempty parsed history").clone();
                    if self
                        .last
                        .as_ref()
                        .is_some_and(|last| report.observed_at < last.observed_at)
                    {
                        self.error=Some("Source returned an older observation; cached current observation retained".into());
                    } else {
                        for row in history {
                            self.history.insert(row.observed_at, row);
                        }
                        self.history
                            .retain(|time, _| *time >= wall.saturating_sub(129600));
                        while self.history.len() > 2048 {
                            self.history.pop_first();
                        }
                        self.last = Some(report);
                        self.error = None;
                    }
                }
                Err(error) => self.error = Some(error),
            }
        }
        let cooldown = self
            .last_attempt
            .map_or(0., |last| (last + 60. - time).max(0.));
        self.update(wall, cooldown.ceil() as u64, None)
    }
    fn update(&self, wall: i64, cooldown: u64, clock_error: Option<&str>) -> Update {
        let mut update = Update { preferences: self.preferences.clone(), observation: self.last.clone(), history:self.history.values().cloned().collect(), reference_time:Some(wall), summary: "Weather disabled".into(),
            detail: "Enable weather and choose an ICAO station. No weather requests are made while disabled.".into(), stale: false, cooldown_seconds: cooldown };
        if !self.preferences.enabled {
            return update;
        }
        let station = shared::metar_station(&self.preferences.station).unwrap_or_default();
        let error = clock_error.or(self.error.as_deref());
        let age = self
            .last
            .as_ref()
            .map(|r| wall.saturating_sub(r.observed_at));
        update.stale = error.is_some() || age.is_some_and(|age| !(-300..=7200).contains(&age));
        update.summary = if self.last.is_none() {
            if self.refresh_pending && cooldown > 0 {
                format!("{station} · waiting for request cooldown ({cooldown} s)")
            } else {
                format!("{station} · observations unavailable")
            }
        } else if update.stale {
            format!("{station} · stale observation")
        } else {
            format!("{station} · latest station observation")
        };
        let mut detail = vec![update.summary.clone(), "Source: NWS Aviation Weather Center · aviationweather.gov\nMETAR station observations, not a forecast.".into()];
        if let Some(error) = error {
            detail.push(format!("Last refresh: {error}"));
        }
        if let Some(report) = &self.last {
            let age = age.unwrap_or_default();
            detail.push(format!(
                "Observed: {} UTC\n{}",
                utc(report.observed_at),
                if age < 0 {
                    format!(
                        "Observation time is {} s ahead of the local clock",
                        age.saturating_abs()
                    )
                } else {
                    format!("Observation age: {} min", age / 60)
                }
            ));
            if update.stale {
                detail.push("Cached observation; it is not current confirmation of station conditions. XRG-ng marks observations older than two hours as stale.".into());
            }
            let metric = self
                .preferences
                .temperature_units
                .unwrap_or(self.preferences.units)
                == Units::Metric;
            let distance_metric = self
                .preferences
                .distance_units
                .unwrap_or(self.preferences.units)
                == Units::Metric;
            let pressure_metric = self
                .preferences
                .pressure_units
                .unwrap_or(self.preferences.units)
                == Units::Metric;
            let wind = self.preferences.wind_system();
            let value = |n: Option<f64>, factor: f64, offset: f64, unit: &str| {
                n.map(|v| format!("{:.1} {unit}", v * factor + offset))
                    .unwrap_or_else(|| "unavailable".into())
            };
            detail.push(format!(
                "Temperature: {}\nDewpoint: {}\nHumidity: {}",
                value(
                    report.temperature_c,
                    if metric { 1. } else { 1.8 },
                    if metric { 0. } else { 32. },
                    if metric { "°C" } else { "°F" }
                ),
                value(
                    report.dewpoint_c,
                    if metric { 1. } else { 1.8 },
                    if metric { 0. } else { 32. },
                    if metric { "°C" } else { "°F" }
                ),
                value(report.humidity, 1., 0., "%")
            ));
            let direction = report
                .wind_degrees
                .map(|d| {
                    if d == -1. {
                        "variable".into()
                    } else {
                        format!("{d:.0}°")
                    }
                })
                .unwrap_or_else(|| "unavailable".into());
            detail.push(format!(
                "Wind direction: {direction}\nWind speed: {}\nGust: {}",
                value(report.wind_knots, wind.factor(), 0., wind.suffix()),
                value(report.gust_knots, wind.factor(), 0., wind.suffix())
            ));
            let visibility = report
                .visibility_miles
                .map(|v| {
                    format!(
                        "{}{:.2} {}",
                        report.visibility_qualifier,
                        v * if distance_metric { 1.609344 } else { 1. },
                        if distance_metric { "km" } else { "mi" }
                    )
                })
                .unwrap_or_else(|| "unavailable".into());
            let pressure = if pressure_metric {
                report.pressure_hpa.map(|p| format!("{p:.0} hPa"))
            } else {
                report.pressure_in.map(|p| format!("{p:.2} inHg"))
            }
            .unwrap_or_else(|| "unavailable".into());
            detail.push(format!("Visibility: {visibility}\nPressure: {pressure}"));
            detail.push(format!("Raw METAR:\n{}", report.raw));
        }
        if self.refresh_pending && cooldown > 0 {
            detail.push(format!(
                "Refresh queued; next request in at most {cooldown} s."
            ));
        }
        update.detail = detail.join("\n\n");
        update
    }
}
fn utc(timestamp: i64) -> String {
    let epoch = timestamp as libc::time_t;
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    if unsafe { libc::gmtime_r(&epoch, &mut tm) }.is_null() {
        return format!("{timestamp} Unix seconds");
    }
    format!(
        "{:04}-{:02}-{:02} {:02}:{:02}",
        tm.tm_year + 1900,
        tm.tm_mon + 1,
        tm.tm_mday,
        tm.tm_hour,
        tm.tm_min
    )
}
#[derive(Default)]
struct Pending {
    preferences: Option<Preferences>,
    refresh: bool,
}
#[derive(Clone, Default)]
pub struct Control(Arc<Mutex<Pending>>);
impl Control {
    pub fn set(&self, preferences: Preferences) -> Result<(), String> {
        preferences.validate()?;
        self.0.lock().unwrap().preferences = Some(preferences);
        Ok(())
    }
    pub fn refresh(&self) {
        self.0.lock().unwrap().refresh = true;
    }
}
pub struct Worker {
    pub latest: Arc<Mutex<Option<Update>>>,
    stop: Option<mpsc::Sender<()>>,
    join: Option<thread::JoinHandle<()>>,
}
impl Worker {
    pub fn start(preferences: Preferences, control: Control) -> Self {
        Self::with_fetcher(preferences, control, Https::default())
    }
    fn with_fetcher(
        preferences: Preferences,
        control: Control,
        mut fetcher: impl Fetcher + Send + 'static,
    ) -> Self {
        preferences
            .validate()
            .expect("Validated weather preferences");
        let latest = Arc::new(Mutex::new(None));
        let output = latest.clone();
        let (stop, receiver) = mpsc::channel();
        let join = thread::spawn(move || {
            let mut collector = Collector::new(preferences).expect("Validated weather preferences");
            let start = Instant::now();
            loop {
                let pending = std::mem::take(&mut *control.0.lock().unwrap());
                if let Some(preferences) = pending.preferences {
                    collector
                        .configure(preferences)
                        .expect("Validated weather update");
                }
                let wall = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .ok()
                    .and_then(|d| i64::try_from(d.as_secs()).ok())
                    .unwrap_or(-1);
                let update = collector.sample(
                    start.elapsed().as_secs_f64(),
                    wall,
                    pending.refresh,
                    &mut fetcher,
                );
                *output.lock().unwrap() = Some(update);
                match receiver.recv_timeout(Duration::from_secs(1)) {
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
            join.join().expect("Weather worker panicked");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    struct Fixture {
        calls: Arc<AtomicUsize>,
    }
    impl Fetcher for Fixture {
        fn get(&mut self, station: &str) -> Result<Vec<u8>, String> {
            assert_eq!(station, "KSEA");
            self.calls.fetch_add(1, Ordering::SeqCst);
            let now = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_secs() as i64;
            let date = utc(now);
            Ok(format!(
                "{station} {}{}{}Z 00000KT 10SM 00/M02 A3000",
                &date[8..10],
                &date[11..13],
                &date[14..16]
            )
            .into_bytes())
        }
    }
    #[test]
    fn worker_starts_disabled_applies_source_changes_and_stops_without_waiting_for_the_poll() {
        let calls = Arc::new(AtomicUsize::new(0));
        let control = Control::default();
        let worker = Worker::with_fetcher(
            Preferences::default(),
            control.clone(),
            Fixture {
                calls: calls.clone(),
            },
        );
        let receive = |enabled: bool| {
            let deadline = Instant::now() + Duration::from_secs(3);
            loop {
                if let Some(update) = worker.latest.lock().unwrap().take()
                    && update.preferences.enabled == enabled
                {
                    break update;
                }
                assert!(Instant::now() < deadline, "Weather worker did not publish");
                thread::sleep(Duration::from_millis(10));
            }
        };
        assert_eq!(receive(false).summary, "Weather disabled");
        assert_eq!(calls.load(Ordering::SeqCst), 0);
        control
            .set(Preferences {
                enabled: true,
                station: " ksea ".into(),
                ..Default::default()
            })
            .unwrap();
        assert_eq!(receive(true).observation.unwrap().station, "KSEA");
        control.refresh();
        let update = receive(true);
        assert!(update.detail.contains("Refresh queued"));
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        control.set(Preferences::default()).unwrap();
        assert!(receive(false).observation.is_none());
        let stop = Instant::now();
        drop(worker);
        assert!(stop.elapsed() < Duration::from_secs(2));
    }
    #[test]
    fn network_collection_never_holds_the_snapshot_lock() {
        struct Blocked {
            started: mpsc::Sender<()>,
            release: mpsc::Receiver<()>,
        }
        impl Fetcher for Blocked {
            fn get(&mut self, _: &str) -> Result<Vec<u8>, String> {
                self.started.send(()).unwrap();
                self.release.recv_timeout(Duration::from_secs(3)).unwrap();
                Err("Fixture released".into())
            }
        }
        let (started, wait) = mpsc::channel();
        let (release, gate) = mpsc::channel();
        let worker = Worker::with_fetcher(
            Preferences {
                enabled: true,
                station: "KSEA".into(),
                ..Default::default()
            },
            Control::default(),
            Blocked {
                started,
                release: gate,
            },
        );
        wait.recv_timeout(Duration::from_secs(2)).unwrap();
        let unlocked = worker.latest.try_lock().is_ok();
        release.send(()).unwrap();
        drop(worker);
        assert!(
            unlocked,
            "A weather request blocked the core worker's snapshot read"
        );
    }
}
