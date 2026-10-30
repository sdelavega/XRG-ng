// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use serde::{Deserialize, Serialize};
use std::{
    net::{IpAddr, SocketAddr},
    path::{Path, PathBuf},
};
#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ClaudeSource {
    #[default]
    Auto,
    Logs,
    Database,
    Metrics,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default, deny_unknown_fields)]
pub struct Preferences {
    pub accounting: super::accounting::Preferences,
    /// Zero preserves the original 120-sample default; independent of accounting.
    pub history_samples: u32,
    pub enabled: [bool; 4],
    pub ollama: bool,
    pub claude_source: ClaudeSource,
    pub claude_logs: Option<PathBuf>,
    pub claude_database: Option<PathBuf>,
    pub codex_logs: Option<PathBuf>,
    pub gemini_logs: Option<PathBuf>,
    pub hermes_database: Option<PathBuf>,
    pub metrics_url: String,
    pub ollama_url: String,
}
impl Default for Preferences {
    fn default() -> Self {
        Self {
            accounting: super::accounting::Preferences::default(),
            history_samples: 0,
            enabled: [true; 4],
            ollama: true,
            claude_source: ClaudeSource::Auto,
            claude_logs: None,
            claude_database: None,
            codex_logs: None,
            gemini_logs: None,
            hermes_database: None,
            metrics_url: "http://127.0.0.1:8889/metrics".into(),
            ollama_url: "http://127.0.0.1:11434".into(),
        }
    }
}
impl Preferences {
    pub fn history_capacity(&self) -> u32 {
        if self.history_samples == 0 {
            120
        } else {
            self.history_samples
        }
    }
    pub(crate) fn same_collection(&self, other: &Self) -> bool {
        self.same_sources(other) && self.accounting == other.accounting
    }
    pub fn same_sources(&self, other: &Self) -> bool {
        let mut a = self.clone();
        let mut b = other.clone();
        a.history_samples = 0;
        b.history_samples = 0;
        a.accounting = Default::default();
        b.accounting = Default::default();
        a == b
    }
    pub fn validate(&self) -> Result<(), String> {
        self.accounting.validate()?;
        if self.history_samples > crate::shared::sampling_settings()[3] {
            return Err("AI history capacity must be 0..20000 samples".into());
        }
        for path in [
            &self.claude_logs,
            &self.claude_database,
            &self.codex_logs,
            &self.gemini_logs,
            &self.hermes_database,
        ]
        .into_iter()
        .flatten()
        {
            let value = path.to_str().ok_or("AI paths must be UTF-8")?;
            if !path.is_absolute() || value.len() > 4096 || value.chars().any(char::is_control) {
                return Err(
                    "AI paths must be absolute, at most 4096 bytes, without control characters"
                        .into(),
                );
            }
        }
        validate_url(&self.metrics_url)?;
        validate_url(&self.ollama_url)?;
        Ok(())
    }
    pub fn paths(&self, home: &Path) -> [PathBuf; 5] {
        [
            self.claude_logs
                .clone()
                .unwrap_or_else(|| home.join(".claude/projects")),
            self.claude_database
                .clone()
                .unwrap_or_else(|| home.join(".claude/monitoring/claude_usage.db")),
            self.codex_logs
                .clone()
                .unwrap_or_else(|| home.join(".codex/sessions")),
            self.gemini_logs
                .clone()
                .unwrap_or_else(|| home.join(".gemini/tmp")),
            self.hermes_database
                .clone()
                .unwrap_or_else(|| home.join(".hermes/state.db")),
        ]
    }
}
pub fn validate_url(url: &str) -> Result<(), String> {
    let fail = || {
        "Use an HTTP URL with a loopback IP (127.0.0.1 or [::1]), without credentials, query or fragment".to_owned()
    };
    if url.len() > 2048
        || !url.is_ascii()
        || url
            .chars()
            .any(|c| c.is_control() || c.is_whitespace() || matches!(c, '@' | '?' | '#' | '\\'))
    {
        return Err(fail());
    }
    let rest = url.strip_prefix("http://").ok_or_else(fail)?;
    let authority = rest.split('/').next().unwrap_or("");
    let ip = if let Ok(address) = authority.parse::<SocketAddr>() {
        if address.port() == 0 {
            return Err(fail());
        }
        address.ip()
    } else {
        authority
            .trim_start_matches('[')
            .trim_end_matches(']')
            .parse::<IpAddr>()
            .map_err(|_| fail())?
    };
    if !ip.is_loopback() {
        return Err(fail());
    }
    if ip.is_ipv4() && (authority.contains('[') || authority.contains(']')) {
        return Err(fail());
    }
    if ip.is_ipv6() && !authority.starts_with('[') {
        return Err(fail());
    }
    // Only canonical unambiguous IP authorities; curl must not reinterpret a
    // malformed bracket/port form or expand URL globbing into additional reads.
    if authority != ip.to_string()
        && authority != format!("[{ip}]")
        && authority.parse::<SocketAddr>().is_err()
    {
        return Err(fail());
    }
    Ok(())
}
