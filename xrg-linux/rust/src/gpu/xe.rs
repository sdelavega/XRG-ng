// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Opt-in Xe PMU pairs. Engine event lifetime can hold runtime-PM/forcewake refs.
mod discovery;
mod native;
use super::{Device, EngineActivity};
use std::{
    collections::{BTreeMap, BTreeSet},
    path::Path,
    time::{Duration, Instant},
};
#[derive(Clone, Copy, Debug)]
struct Reading {
    active: u64,
    total: u64,
    enabled: u64,
    running: u64,
}
trait Counter: Send {
    fn read(&mut self) -> Result<Reading, String>;
}
type Counters = Vec<(String, Box<dyn Counter>)>;
trait Open {
    fn open(&mut self, spec: &discovery::Spec) -> Result<Counters, String>;
}
fn percent(old: Reading, next: Reading) -> Result<f64, String> {
    let active = next
        .active
        .checked_sub(old.active)
        .ok_or("Xe active counter regressed")?;
    let total = next
        .total
        .checked_sub(old.total)
        .filter(|v| *v > 0)
        .ok_or("Xe total counter regressed or did not advance")?;
    let enabled = next
        .enabled
        .checked_sub(old.enabled)
        .filter(|v| *v > 0)
        .ok_or("Xe enabled time did not advance")?;
    let running = next
        .running
        .checked_sub(old.running)
        .ok_or("Xe running time regressed")?;
    if enabled != running {
        return Err("Xe perf interval incomplete or multiplexed".into());
    }
    let value = 100. * active as f64 / total as f64;
    if !value.is_finite() || value > 105. {
        return Err("Xe active ticks exceed total ticks".into());
    }
    Ok(value.min(100.))
}
struct Engine {
    name: String,
    counter: Box<dyn Counter>,
    previous: Option<Reading>,
}
struct Session {
    engines: Vec<Engine>,
    last: Option<Instant>,
}
impl Session {
    fn poll(&mut self, time: Instant) -> Result<Option<EngineActivity>, String> {
        let elapsed = self.last.and_then(|old| time.checked_duration_since(old));
        if elapsed.is_some_and(|v| v.is_zero()) {
            return Ok(None);
        }
        let valid = elapsed.is_some_and(|v| v <= Duration::from_secs(300));
        self.last = Some(time);
        let mut values = Vec::new();
        let started = Instant::now();
        for engine in &mut self.engines {
            if started.elapsed() > Duration::from_millis(100) {
                return Err("Xe PMU read budget exceeded".into());
            }
            let next = engine.counter.read()?;
            if valid && let Some(old) = engine.previous {
                values.push((engine.name.clone(), percent(old, next)?));
            }
            engine.previous = Some(next);
        }
        Ok(
            (values.len() == self.engines.len()).then(|| EngineActivity {
                percent: values.iter().map(|(_, v)| *v).fold(0., f64::max),
                engines: values,
            }),
        )
    }
}
struct State {
    spec: discovery::Spec,
    session: Option<Session>,
    retry: Instant,
    error: String,
}
struct Backend<O> {
    open: O,
    states: BTreeMap<String, State>,
}
fn eligible(d: &Device) -> bool {
    d.vendor == "0x8086" && d.gpu.driver == "xe" && !d.suspended
}
impl<O: Open> Backend<O> {
    fn stop(&mut self) {
        self.states.clear();
    }
    fn collect(&mut self, sys: &Path, devices: &mut [Device], time: Instant) {
        self.states
            .retain(|id, _| devices.iter().any(|d| d.gpu.id == *id && eligible(d)));
        let started = Instant::now();
        for device in devices.iter_mut().filter(|d| eligible(d)) {
            let id = device.gpu.id.clone();
            let result = if started.elapsed() > Duration::from_millis(100) {
                Err("Xe PMU acquisition budget exceeded".into())
            } else {
                discovery::describe(sys, device)
            };
            let spec = match result {
                Ok(s) => s,
                Err(e) => {
                    self.states.remove(&id);
                    device.gpu.notes.push(format!("Xe PMU unavailable: {e}"));
                    continue;
                }
            };
            if self
                .states
                .get(&id)
                .is_some_and(|s| s.spec != spec || s.session.is_none() && time >= s.retry)
            {
                self.states.remove(&id);
            }
            if !self.states.contains_key(&id) {
                let used: usize = self
                    .states
                    .values()
                    .filter_map(|s| s.session.as_ref())
                    .map(|s| s.engines.len() * 2)
                    .sum();
                // Reserve a full bounded adapter before opening any events.
                let result = if used + 128 > 256 {
                    Err("Xe PMU handle budget exceeded".into())
                } else {
                    self.open.open(&spec).and_then(|counters| {
                        if counters.is_empty()
                            || counters.len() > 64
                            || counters
                                .iter()
                                .map(|(n, _)| n)
                                .collect::<BTreeSet<_>>()
                                .len()
                                != counters.len()
                        {
                            return Err("Invalid Xe engine group set".into());
                        }
                        spec.verify()?;
                        Ok(Session {
                            engines: counters
                                .into_iter()
                                .map(|(name, counter)| Engine {
                                    name,
                                    counter,
                                    previous: None,
                                })
                                .collect(),
                            last: None,
                        })
                    })
                };
                let (session, error) = match result {
                    Ok(s) => (Some(s), String::new()),
                    Err(e) => (None, e),
                };
                self.states.insert(
                    id.clone(),
                    State {
                        spec,
                        session,
                        error,
                        retry: time + Duration::from_secs(30),
                    },
                );
            }
            let state = self.states.get_mut(&id).unwrap();
            if let Some(session) = &mut state.session {
                match session.poll(time).and_then(|value| {
                    state.spec.verify()?;
                    Ok(value)
                }) {
                    Ok(Some(value)) => device.gpu.engine_activity = Some(value),
                    Ok(None) => device
                        .gpu
                        .notes
                        .push("Xe PMU waiting for a valid engine interval".into()),
                    Err(error) => {
                        state.session = None;
                        state.error = error;
                        state.retry = time + Duration::from_secs(30);
                        device
                            .gpu
                            .notes
                            .push(format!("Xe PMU unavailable: {}", state.error));
                    }
                }
            } else {
                device
                    .gpu
                    .notes
                    .push(format!("Xe PMU unavailable: {}", state.error));
            }
        }
    }
}
pub(super) struct Collector {
    enabled: bool,
    allowed: bool,
    backend: Backend<native::Native>,
}
impl Collector {
    pub fn new(sys: &Path) -> Self {
        Self {
            enabled: false,
            allowed: cfg!(any(target_arch = "x86_64", target_arch = "aarch64"))
                && super::intel::perf::available(sys),
            backend: Backend {
                open: native::Native,
                states: BTreeMap::new(),
            },
        }
    }
    pub fn clear(&mut self) {
        self.backend.stop();
    }
    pub fn set_enabled(&mut self, enabled: bool) {
        if !enabled {
            self.clear();
        }
        self.enabled = enabled;
    }
    pub fn collect(&mut self, sys: &Path, devices: &mut [Device], time: Instant) {
        if !self.enabled {
            return;
        }
        if self.allowed {
            for d in devices.iter_mut().filter(|d| eligible(d)) {
                d.gpu.notes.push(
                    "Xe PMU opt-in enabled: open engine events can keep the GPU awake".into(),
                );
            }
            self.backend.collect(sys, devices, time);
        } else {
            for d in devices.iter_mut().filter(|d| eligible(d)) {
                d.gpu
                    .notes
                    .push("Xe PMU disabled for custom sysfs roots or unsupported targets".into());
            }
        }
    }
}
#[cfg(test)]
mod tests;
