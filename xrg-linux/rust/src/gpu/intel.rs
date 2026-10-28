// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Kernel i915 PMU engine activity. Custom roots never open host perf events.
mod discovery;
mod perf;
use super::{Device, EngineActivity, pci_id};
use discovery::Spec;
use perf::{Counter, Open, Reading};
use std::{
    collections::BTreeMap,
    path::Path,
    time::{Duration, Instant},
};
struct Engine {
    name: String,
    handle: Box<dyn Counter>,
    previous: Option<Reading>,
}
struct Session {
    engines: Vec<Engine>,
    last: Option<Instant>,
}
impl Session {
    fn open(spec: &Spec, open: &mut impl Open) -> Result<Self, String> {
        let mut engines = Vec::new();
        for event in &spec.events {
            engines.push(Engine {
                name: event.name.clone(),
                handle: open.open(spec, event)?,
                previous: None,
            });
        }
        Ok(Self {
            engines,
            last: None,
        })
    }
    fn poll(&mut self, time: Instant) -> Result<Option<EngineActivity>, String> {
        let elapsed = self.last.and_then(|old| time.checked_duration_since(old));
        if self.last.is_some() && elapsed.is_some_and(|v| v.is_zero()) {
            return Ok(None);
        }
        let valid = elapsed.is_some_and(|d| d <= Duration::from_secs(300));
        self.last = Some(time);
        let mut values = Vec::new();
        for engine in &mut self.engines {
            let next = engine.handle.read()?;
            if valid && let Some(old) = engine.previous {
                values.push((engine.name.clone(), perf::percent(old, next)?));
            }
            engine.previous = Some(next);
        }
        if values.len() != self.engines.len() {
            return Ok(None);
        }
        let percent = values.iter().map(|(_, v)| *v).fold(0., f64::max);
        Ok(Some(EngineActivity {
            percent,
            engines: values,
        }))
    }
}
struct State {
    spec: Spec,
    session: Option<Session>,
    retry_at: Instant,
    error: String,
}
struct Backend<O> {
    open: O,
    states: BTreeMap<String, State>,
}
impl<O: Open> Backend<O> {
    fn collect(&mut self, sys: &Path, devices: &mut [Device], time: Instant) {
        self.states
            .retain(|id, _| devices.iter().any(|d| d.gpu.id == *id && eligible(d)));
        if !devices.iter().any(eligible) {
            return;
        }
        let global = discovery::global_owner(sys);
        let start = Instant::now();
        for device in devices.iter_mut().filter(|d| eligible(d)) {
            let id = device.gpu.id.clone();
            if start.elapsed() > Duration::from_millis(100) {
                self.states.remove(&id);
                device
                    .gpu
                    .notes
                    .push("i915 PMU acquisition budget exceeded".into());
                continue;
            }
            let spec = match discovery::describe(sys, device, &global) {
                Ok(spec) => spec,
                Err(error) => {
                    self.states.remove(&id);
                    device
                        .gpu
                        .notes
                        .push(format!("i915 PMU unavailable: {error}"));
                    continue;
                }
            };
            if self.states.get(&id).is_some_and(|state| {
                state.spec != spec || state.session.is_none() && time >= state.retry_at
            }) {
                self.states.remove(&id);
            }
            if !self.states.contains_key(&id) {
                let count: usize = self
                    .states
                    .values()
                    .filter_map(|s| s.session.as_ref())
                    .map(|s| s.engines.len())
                    .sum();
                let result = if count + spec.events.len() > 256 {
                    Err("i915 PMU handle limit exceeded".into())
                } else {
                    Session::open(&spec, &mut self.open).and_then(|session| {
                        spec.verify(device)?;
                        Ok(session)
                    })
                };
                let (session, error) = match result {
                    Ok(session) => (Some(session), String::new()),
                    Err(error) => (None, error),
                };
                self.states.insert(
                    id.clone(),
                    State {
                        spec,
                        session,
                        retry_at: time + Duration::from_secs(30),
                        error,
                    },
                );
            }
            let state = self.states.get_mut(&id).unwrap();
            if state.session.is_none() {
                device.gpu.notes.push(state.error.clone());
                continue;
            }
            let result = state
                .session
                .as_mut()
                .unwrap()
                .poll(time)
                .and_then(|activity| {
                    state.spec.verify(device)?;
                    Ok(activity)
                });
            match result {
                Ok(Some(activity)) => device.gpu.engine_activity = Some(activity),
                Ok(None) => device
                    .gpu
                    .notes
                    .push("i915 PMU waiting for a valid engine interval".into()),
                Err(error) => {
                    state.session = None;
                    state.error = format!("i915 PMU unavailable: {error}");
                    state.retry_at = time + Duration::from_secs(30);
                    device.gpu.notes.push(state.error.clone());
                }
            }
        }
    }
}
fn eligible(device: &Device) -> bool {
    device.gpu.driver == "i915"
        && device.vendor == "0x8086"
        && !device.suspended
        && pci_id(&device.gpu.id).is_some()
}
pub(super) struct Collector {
    allowed: bool,
    backend: Backend<perf::Native>,
}
impl Collector {
    pub fn new(sys: &Path) -> Self {
        Self {
            allowed: perf::available(sys),
            backend: Backend {
                open: perf::Native,
                states: BTreeMap::new(),
            },
        }
    }
    pub fn clear(&mut self) {
        self.backend.states.clear();
    }
    pub fn collect(&mut self, sys: &Path, devices: &mut [Device], time: Instant) {
        if self.allowed {
            self.backend.collect(sys, devices, time);
        }
    }
}
#[cfg(test)]
mod tests;
