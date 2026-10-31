// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Observed usage, independent of graph histories and historical provider totals.
use super::{Report, models};
use crate::shared::{TokenLedger, Usage};
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    fs::File,
    path::{Path, PathBuf},
};
#[cfg(target_os = "linux")]
use std::{
    fs::OpenOptions,
    os::{fd::AsRawFd, unix::fs::OpenOptionsExt},
};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Preferences {
    pub enabled: bool,
    pub auto_reset: bool,
    pub daily_budget: u64,
    pub notify_percent: u8,
    pub notifications: bool,
    pub by_model: bool,
    pub by_provider: bool,
}
impl Default for Preferences {
    fn default() -> Self {
        Self {
            enabled: false,
            auto_reset: true,
            daily_budget: 0,
            notify_percent: 80,
            notifications: false,
            by_model: true,
            by_provider: false,
        }
    }
}
impl Preferences {
    pub fn validate(&self) -> Result<(), String> {
        if !(1..=100).contains(&self.notify_percent) {
            return Err("AI budget threshold must be 1–100 percent".into());
        }
        Ok(())
    }
}
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Totals {
    pub input: u64,
    pub output: u64,
    pub unclassified: u64,
    pub saturated: bool,
}
impl Totals {
    pub fn total(&self) -> u64 {
        self.input
            .saturating_add(self.output)
            .saturating_add(self.unclassified)
    }
    fn add(&mut self, u: Usage) {
        for (dst, value) in [
            (&mut self.input, u.input),
            (&mut self.output, u.output),
            (&mut self.unclassified, u.total - u.input - u.output),
        ] {
            let next = dst.checked_add(value);
            self.saturated |= next.is_none();
            *dst = next.unwrap_or(u64::MAX);
        }
        self.saturated |= self
            .input
            .checked_add(self.output)
            .and_then(|n| n.checked_add(self.unclassified))
            .is_none();
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Daily {
    version: u32,
    day: String,
    totals: Totals,
    models: BTreeMap<String, u64>,
    providers: BTreeMap<String, u64>,
    truncated_models: bool,
    notified_day: Option<String>,
}
impl Daily {
    fn new(day: &str) -> Self {
        Self {
            version: 1,
            day: day.into(),
            totals: Totals::default(),
            models: BTreeMap::new(),
            providers: BTreeMap::new(),
            truncated_models: false,
            notified_day: None,
        }
    }
    fn validate(&self) -> Result<(), String> {
        let valid_day = |s: &str| {
            if s.len() != 10
                || s.as_bytes()[4] != b'-'
                || s.as_bytes()[7] != b'-'
                || !s
                    .bytes()
                    .enumerate()
                    .all(|(i, b)| i == 4 || i == 7 || b.is_ascii_digit())
            {
                return false;
            }
            let year = s[..4].parse::<u32>().unwrap_or(0);
            let month = s[5..7].parse::<usize>().unwrap_or(0);
            let day = s[8..].parse::<u32>().unwrap_or(0);
            if year == 0 || !(1..=12).contains(&month) {
                return false;
            }
            let leap =
                year.is_multiple_of(4) && (!year.is_multiple_of(100) || year.is_multiple_of(400));
            let days = [
                31,
                if leap { 29 } else { 28 },
                31,
                30,
                31,
                30,
                31,
                31,
                30,
                31,
                30,
                31,
            ];
            (1..=days[month - 1]).contains(&day)
        };
        let total = self.totals.total();
        let known = self.totals.input as u128
            + self.totals.output as u128
            + self.totals.unclassified as u128;
        let invalid_totals = if self.totals.saturated {
            total != u64::MAX
        } else {
            known > u64::MAX as u128
                || self.models.values().map(|n| *n as u128).sum::<u128>() > total as u128
                || self.providers.values().map(|n| *n as u128).sum::<u128>() > total as u128
        };
        if invalid_totals
            || self.version != 1
            || !valid_day(&self.day)
            || self.notified_day.as_deref().is_some_and(|d| !valid_day(d))
            || self.models.len() > 256
            || self.providers.len() > 4
            || self
                .models
                .keys()
                .any(|n| models::model_name(Some(n.clone())).is_none())
            || self
                .providers
                .keys()
                .any(|n| !["Claude", "Codex", "Gemini", "Hermes"].contains(&n.as_str()))
        {
            return Err("Unsupported or invalid AI daily state; original file preserved".into());
        }
        Ok(())
    }
}
#[derive(Clone, Debug, Default)]
pub struct Snapshot {
    pub enabled: bool,
    pub session: Totals,
    pub daily: Totals,
    pub day: String,
    pub models: BTreeMap<String, u64>,
    pub providers: BTreeMap<String, u64>,
    pub truncated_models: bool,
    pub persistence_error: Option<String>,
    pub notification_status: String,
}
impl Snapshot {
    pub fn detail(&self, preferences: &Preferences) -> String {
        if self.day.is_empty() {
            return if self.enabled {
                format!(
                    "Observed accounting unavailable: {}",
                    self.persistence_error
                        .as_deref()
                        .unwrap_or("Waiting for a local calendar day")
                )
            } else {
                "Observed session/daily accounting disabled. Enable it in AI preferences.".into()
            };
        }
        let mut lines = vec![
            format!(
                "Observed session: {} total · {} input · {} output · {} unknown split",
                self.session.total(),
                self.session.input,
                self.session.output,
                self.session.unclassified
            ),
            format!(
                "Daily ({}): {} total · {} input · {} output · {} unknown split",
                self.day,
                self.daily.total(),
                self.daily.input,
                self.daily.output,
                self.daily.unclassified
            ),
        ];
        if !self.enabled {
            lines.insert(
                0,
                "Observed accounting paused; existing counters are retained.".into(),
            );
        }
        if preferences.daily_budget > 0 {
            lines.push(format!(
                "Daily token budget: {} / {} ({:.1}%)",
                self.daily.total(),
                preferences.daily_budget,
                self.daily.total() as f64 / preferences.daily_budget as f64 * 100.
            ));
        }
        if self.daily.saturated || self.session.saturated {
            lines.push("Counters saturated: totals are lower bounds.".into());
        }
        if preferences.by_provider {
            for (name, count) in &self.providers {
                lines.push(format!("Observed provider {name}: {count}"));
            }
        }
        if preferences.by_model {
            for (name, count) in &self.models {
                lines.push(format!("Observed model {name:?}: {count}"));
            }
        }
        if self.truncated_models {
            lines.push("Daily model breakdown limited to 256 names; provider totals still include all tokens.".into());
        }
        if let Some(error) = &self.persistence_error {
            lines.push(format!("Daily state unavailable: {error}. Counters are in memory; desktop alerts suppressed."));
        }
        lines.push(self.notification_status.clone());
        lines.push("Initial history excluded. Tokens belong to the day observed, not event timestamps; gaps/edits can undercount. These are not billing records. Graph resets preserve these counters.".into());
        lines.join("\n")
    }
}

pub fn state_path() -> Option<PathBuf> {
    let state = std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute());
    let root = state.or_else(|| {
        std::env::var_os("HOME")
            .map(PathBuf::from)
            .filter(|p| p.is_absolute())
            .map(|p| p.join(".local/state"))
    })?;
    Some(root.join("xrg-ng/ai-usage.json"))
}
pub fn local_day() -> Result<String, String> {
    #[cfg(target_os = "linux")]
    {
        let time = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|e| e.to_string())?
            .as_secs();
        let time = libc::time_t::try_from(time).map_err(|_| "Clock out of range")?;
        let mut tm = std::mem::MaybeUninit::<libc::tm>::uninit();
        // localtime_r owns no shared static result; TZ is read, never changed.
        if unsafe { libc::localtime_r(&time, tm.as_mut_ptr()) }.is_null() {
            return Err("Local calendar unavailable".into());
        }
        let tm = unsafe { tm.assume_init() };
        Ok(format!(
            "{:04}-{:02}-{:02}",
            tm.tm_year + 1900,
            tm.tm_mon + 1,
            tm.tm_mday
        ))
    }
    #[cfg(not(target_os = "linux"))]
    {
        // No libc localtime_r off Linux; report the existing "local calendar
        // unavailable" value rather than guessing a time zone.
        Err("Local calendar unavailable".into())
    }
}
struct Store {
    path: Option<PathBuf>,
    expected: Option<Vec<u8>>,
    blocked: Option<String>,
    _lock: Option<File>,
}
impl Store {
    // Off Linux the lock stub returns before the shared state-parsing tail,
    // which reads as unreachable there; on Linux the whole body is reachable.
    #[allow(unreachable_code)]
    fn open(path: Option<PathBuf>, day: &str) -> (Self, Daily) {
        let mut store = Self {
            path,
            expected: None,
            blocked: None,
            _lock: None,
        };
        let loaded = (|| {
            let path = store.path.as_ref().ok_or("No state directory available")?;
            let parent = path.parent().ok_or("Invalid state path")?;
            std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
            #[cfg(target_os = "linux")]
            {
                let lock = OpenOptions::new()
                    .read(true)
                    .write(true)
                    .create(true)
                    .truncate(false)
                    .mode(0o600)
                    .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
                    .open(parent.join("ai-usage.lock"))
                    .map_err(|e| e.to_string())?;
                if !lock.metadata().map_err(|e| e.to_string())?.is_file()
                    || unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0
                {
                    return Err(
                        "Another instance owns AI accounting, or the state lock is invalid".into(),
                    );
                }
                store._lock = Some(lock);
            }
            #[cfg(not(target_os = "linux"))]
            {
                // No O_NOFOLLOW/O_NONBLOCK/flock discipline exists off Linux;
                // report the store's existing "blocked by another instance"
                // value instead of writing unprotected shared state.
                let _ = parent;
                return Err(
                    "Another instance owns AI accounting, or the state lock is invalid".into(),
                );
            }
            store.expected = read_state(path)?;
            match &store.expected {
                Some(bytes) => {
                    let daily: Daily = serde_json::from_slice(bytes)
                        .map_err(|e| format!("Invalid AI daily state: {e}"))?;
                    daily.validate()?;
                    Ok(daily)
                }
                None => Ok(Daily::new(day)),
            }
        })();
        let daily = match loaded {
            Ok(d) => d,
            Err(e) => {
                store.blocked = Some(e);
                Daily::new(day)
            }
        };
        (store, daily)
    }
    fn save(&mut self, daily: &Daily) -> Result<(), String> {
        if let Some(error) = &self.blocked {
            return Err(error.clone());
        }
        let path = self.path.as_ref().ok_or("No state directory available")?;
        if read_state(path)? != self.expected {
            self.blocked = Some("AI state changed on disk; reopen the app before saving".into());
            return Err(self.blocked.clone().unwrap());
        }
        let bytes = serde_json::to_vec(daily).map_err(|e| e.to_string())?;
        crate::settings::atomic_write_state(path, &bytes)?;
        self.expected = Some(bytes);
        File::open(path.parent().ok_or("Invalid state parent")?)
            .and_then(|dir| dir.sync_all())
            .map_err(|e| e.to_string())?;
        Ok(())
    }
}
fn read_state(path: &Path) -> Result<Option<Vec<u8>>, String> {
    match crate::system_file::read(path, 1_048_576) {
        Ok(bytes) => Ok(Some(bytes)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e.to_string()),
    }
}

pub struct Accountant {
    ledger: TokenLedger,
    daily: Daily,
    session: Totals,
    store: Store,
    preferences: super::Preferences,
    error: Option<String>,
    status: String,
    dirty: bool,
}
impl Accountant {
    pub fn open(path: Option<PathBuf>, preferences: super::Preferences, day: &str) -> Self {
        let (store, daily) = Store::open(path, day);
        Self {
            ledger: TokenLedger::default(),
            daily,
            session: Totals::default(),
            error: store.blocked.clone(),
            store,
            preferences,
            status: "Desktop alerts: no threshold attempt this session.".into(),
            dirty: false,
        }
    }
    pub fn break_continuity(&mut self, error: String) {
        self.ledger.reset();
        self.error = Some(error);
    }
    pub fn configure(&mut self, preferences: &super::Preferences) {
        if !self.preferences.same_sources(preferences)
            || self.preferences.accounting.enabled != preferences.accounting.enabled
        {
            self.ledger.reset();
        }
        self.preferences = preferences.clone();
    }
    pub fn reset(&mut self, session: bool, daily: bool, day: &str) {
        if session {
            self.session = Totals::default();
        }
        if daily {
            self.daily = Daily::new(day);
            self.dirty = true;
        }
        if session || daily {
            self.ledger.reset();
        }
    }
    /// Returns a threshold percentage only after saving the once-per-day marker.
    pub fn observe(&mut self, report: &Report, day: &str) -> Option<f64> {
        let prefs = self.preferences.accounting.clone();
        if !prefs.enabled {
            if self.dirty {
                self.flush();
            }
            return None;
        }
        if prefs.auto_reset && self.daily.day != day {
            self.reset(false, true, day);
        }
        let mut changed = false;
        for (index, name) in ["Claude", "Codex", "Gemini", "Hermes"]
            .into_iter()
            .enumerate()
        {
            let reading = self.preferences.enabled[index]
                .then(|| report.providers[index].as_ref().ok())
                .flatten();
            let source = reading.map(|r| r.accounting_source()).unwrap_or_default();
            let model_totals = reading
                .and_then(|r| r.models.as_ref())
                .map(|rows| {
                    rows.iter()
                        .filter_map(|row| {
                            models::model_name(row.model.clone())
                                .map(|name| (name, row.usage.total))
                        })
                        .collect()
                })
                .unwrap_or_default();
            let result = self
                .ledger
                .sample(name, &source, reading.map(|r| r.usage), &model_totals);
            let delta = match result {
                Ok(Some(d)) => d,
                Ok(None) => continue,
                Err(error) => {
                    self.error = Some(error);
                    self.ledger.reset();
                    continue;
                }
            };
            self.session.add(delta.usage);
            self.daily.totals.add(delta.usage);
            changed = true;
            if prefs.by_provider {
                let count = self.daily.providers.entry(name.into()).or_default();
                *count = count.saturating_add(delta.usage.total);
            }
            if prefs.by_model {
                for (model, value) in delta.models {
                    if self.daily.models.len() < 256 || self.daily.models.contains_key(&model) {
                        let count = self.daily.models.entry(model).or_default();
                        *count = count.saturating_add(value);
                    } else {
                        self.daily.truncated_models = true;
                    }
                }
            }
        }
        self.dirty |= changed;
        let percent = (prefs.daily_budget > 0)
            .then(|| self.daily.totals.total() as f64 / prefs.daily_budget as f64 * 100.);
        let alert = percent.filter(|p| {
            changed
                && prefs.notifications
                && *p >= prefs.notify_percent as f64
                && self.daily.notified_day.as_deref() != Some(day)
        });
        let previous_marker = self.daily.notified_day.clone();
        if alert.is_some() {
            self.daily.notified_day = Some(day.into());
            self.dirty = true;
        }
        if self.dirty {
            self.flush();
        }
        // A failed state write never consumes an unsent alert in memory. A
        // successful write followed by a transport failure keeps its marker.
        if alert.is_some() && self.error.is_some() {
            self.daily.notified_day = previous_marker;
        }
        alert.filter(|_| self.error.is_none())
    }
    fn flush(&mut self) {
        match self.store.save(&self.daily) {
            Ok(()) => {
                self.error = None;
                self.dirty = false;
            }
            Err(e) => self.error = Some(e),
        }
    }
    pub fn set_notification_status(&mut self, result: Result<(), String>) {
        self.status = match result { Ok(()) => "Desktop budget alert accepted by the notification service; presentation follows desktop settings.".into(), Err(e) => format!("Desktop budget alert failed: {e}. No retry for this day's threshold.") };
    }
    pub fn snapshot(&self) -> Snapshot {
        Snapshot {
            enabled: self.preferences.accounting.enabled,
            session: self.session.clone(),
            daily: self.daily.totals.clone(),
            day: self.daily.day.clone(),
            models: self.daily.models.clone(),
            providers: self.daily.providers.clone(),
            truncated_models: self.daily.truncated_models,
            persistence_error: self.error.clone(),
            notification_status: if !self.preferences.accounting.enabled
                || !self.preferences.accounting.notifications
            {
                "Desktop budget alerts disabled or paused.".into()
            } else {
                self.status.clone()
            },
        }
    }
}
