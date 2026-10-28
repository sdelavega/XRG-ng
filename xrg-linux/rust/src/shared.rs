// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use std::{ffi::c_void, marker::PhantomData, ptr::NonNull, rc::Rc};

unsafe extern "C" {
    fn xrg_provider_details_parse(
        bytes: *const u8,
        length: u32,
        kind: u32,
        output: *mut u8,
        capacity: u32,
    ) -> i32;
    fn xrg_shared_abi_version() -> u32;
    fn xrg_metar_station(bytes: *const u8, length: u32, output: *mut u8, capacity: u32) -> i32;
    fn xrg_metar_latest_parse(
        bytes: *const u8,
        length: u32,
        station: *const u8,
        station_length: u32,
        reference: i64,
        values: *mut f64,
        capacity: u32,
        flags: *mut u32,
        raw: *mut u8,
        raw_capacity: u32,
    ) -> i32;
    fn xrg_history_create(capacity: u32) -> *mut c_void;
    fn xrg_history_free(handle: *mut c_void);
    fn xrg_history_append(handle: *mut c_void, value: f64) -> i32;
    fn xrg_history_copy(handle: *mut c_void, output: *mut f64, capacity: u32) -> i32;
    fn xrg_rate_create() -> *mut c_void;
    fn xrg_rate_free(handle: *mut c_void);
    fn xrg_rate_sample(
        handle: *mut c_void,
        key: u32,
        counter: u64,
        time: f64,
        delta: *mut u64,
    ) -> u32;
    fn xrg_theme_count() -> u32;
    fn xrg_theme_name(index: u32, output: *mut u8, capacity: u32) -> i32;
    fn xrg_theme_colors(index: u32, output: *mut f64, capacity: u32) -> i32;
    fn xrg_metrics_parse(bytes: *const u8, length: u32, tokens: *mut u64, cost: *mut f64) -> i32;
    fn xrg_provider_usage_parse(
        bytes: *const u8,
        length: u32,
        kind: u32,
        input: *mut u64,
        output: *mut u64,
        total: *mut u64,
        identity: *mut u8,
        capacity: u32,
    ) -> i32;
    fn xrg_model_names_parse(bytes: *const u8, length: u32, output: *mut u8, capacity: u32) -> i32;
    fn xrg_metrics_sample_parse(
        bytes: *const u8,
        length: u32,
        tokens: *mut u64,
        cost: *mut f64,
    ) -> i32;
    fn xrg_codex_record_parse(bytes: *const u8, length: u32, tokens: *mut u64) -> i32;
}

pub fn check_abi() {
    assert_eq!(
        unsafe { xrg_shared_abi_version() },
        1,
        "Incompatible Swift core"
    );
}
pub fn metar_station(text: &str) -> Option<String> {
    let length = u32::try_from(text.len()).ok()?;
    let mut output = [0u8; 4];
    let count = unsafe { xrg_metar_station(text.as_ptr(), length, output.as_mut_ptr(), 4) };
    (count == 4).then(|| String::from_utf8_lossy(&output).into_owned())
}
#[derive(Clone, Debug, PartialEq)]
pub struct Metar {
    pub station: String,
    pub observed_at: i64,
    pub temperature_c: Option<f64>,
    pub dewpoint_c: Option<f64>,
    pub humidity: Option<f64>,
    pub wind_degrees: Option<f64>,
    pub wind_knots: Option<f64>,
    pub gust_knots: Option<f64>,
    pub visibility_miles: Option<f64>,
    pub visibility_qualifier: &'static str,
    pub pressure_hpa: Option<f64>,
    pub pressure_in: Option<f64>,
    pub raw: String,
}
pub fn metar_latest(bytes: &[u8], station: &str, reference: i64) -> Option<Metar> {
    let length = u32::try_from(bytes.len()).ok()?;
    let station = metar_station(station)?;
    let mut values = [0.; 10];
    let mut flags = 0;
    let mut raw = [0u8; 8192];
    let count = unsafe {
        xrg_metar_latest_parse(
            bytes.as_ptr(),
            length,
            station.as_ptr(),
            4,
            reference,
            values.as_mut_ptr(),
            10,
            &mut flags,
            raw.as_mut_ptr(),
            raw.len() as u32,
        )
    };
    if !(0..=8192).contains(&count) {
        return None;
    }
    let value = |index: usize| (flags & (1 << index) != 0).then_some(values[index + 1]);
    Some(Metar {
        station,
        observed_at: values[0] as i64,
        temperature_c: value(0),
        dewpoint_c: value(1),
        humidity: value(2),
        wind_degrees: value(3),
        wind_knots: value(4),
        gust_knots: value(5),
        visibility_miles: value(6),
        visibility_qualifier: if flags & (1 << 16) != 0 {
            "<"
        } else if flags & (1 << 17) != 0 {
            ">"
        } else if flags & (1 << 18) != 0 {
            "≥"
        } else {
            ""
        },
        pressure_hpa: value(7),
        pressure_in: value(8),
        raw: std::str::from_utf8(&raw[..count as usize]).ok()?.to_owned(),
    })
}

// Rc marker prevents Send/Sync: these Swift objects are confined to their creator
// thread. Only copied Rust snapshots cross the worker/UI boundary.
pub struct History {
    handle: NonNull<c_void>,
    length: u32,
    _local: PhantomData<Rc<()>>,
}
impl History {
    pub fn new(length: u32) -> Self {
        assert!((1..=86_400).contains(&length));
        Self {
            handle: NonNull::new(unsafe { xrg_history_create(length) })
                .expect("history allocation"),
            length,
            _local: PhantomData,
        }
    }
    pub fn append(&mut self, value: f64) {
        assert_eq!(
            unsafe { xrg_history_append(self.handle.as_ptr(), value) },
            0
        );
    }
    pub fn values(&self) -> Vec<f64> {
        let mut values = vec![0.0; self.length as usize];
        assert_eq!(
            unsafe { xrg_history_copy(self.handle.as_ptr(), values.as_mut_ptr(), self.length) },
            self.length as i32
        );
        values
    }
}
impl Drop for History {
    fn drop(&mut self) {
        unsafe { xrg_history_free(self.handle.as_ptr()) }
    }
}

pub struct Rates {
    handle: NonNull<c_void>,
    _local: PhantomData<Rc<()>>,
}
impl Rates {
    pub fn new() -> Self {
        Self {
            handle: NonNull::new(unsafe { xrg_rate_create() }).expect("rate allocation"),
            _local: PhantomData,
        }
    }
    pub fn sample(&mut self, key: u32, counter: u64, time: f64) -> (u64, u32) {
        let mut delta = 0;
        let rate = unsafe { xrg_rate_sample(self.handle.as_ptr(), key, counter, time, &mut delta) };
        (delta, rate)
    }
}
impl Drop for Rates {
    fn drop(&mut self) {
        unsafe { xrg_rate_free(self.handle.as_ptr()) }
    }
}

#[derive(Clone, Debug)]
pub struct Theme {
    pub name: String,
    pub colors: [[f64; 4]; 7],
}
pub fn themes() -> Vec<Theme> {
    (0..unsafe { xrg_theme_count() })
        .map(|index| {
            let mut name = [0u8; 64];
            let count = unsafe { xrg_theme_name(index, name.as_mut_ptr(), name.len() as u32) };
            assert!(count > 0 && count as usize <= name.len());
            let mut colors = [[0.0; 4]; 7];
            assert_eq!(
                unsafe { xrg_theme_colors(index, colors.as_mut_ptr().cast(), 28) },
                28
            );
            Theme {
                name: String::from_utf8(name[..count as usize].to_vec()).unwrap(),
                colors,
            }
        })
        .collect()
}

pub fn metrics(text: &str) -> Option<(u64, f64)> {
    let (mut tokens, mut cost) = (0, 0.0);
    let length = u32::try_from(text.len()).ok()?;
    (unsafe { xrg_metrics_parse(text.as_ptr(), length, &mut tokens, &mut cost) } == 0)
        .then_some((tokens, cost))
}
pub fn codex_record(bytes: &[u8]) -> Option<u64> {
    let mut tokens = 0;
    let length = u32::try_from(bytes.len()).ok()?;
    (unsafe { xrg_codex_record_parse(bytes.as_ptr(), length, &mut tokens) } == 0).then_some(tokens)
}

impl Default for Rates {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn swift_history_ownership_and_wrap() {
        check_abi();
        for _ in 0..100 {
            let mut h = History::new(3);
            for value in [1., 2., 3., 4.] {
                h.append(value);
            }
            assert_eq!(h.values(), [2., 3., 4.]);
        }
    }
    #[test]
    fn swift_rates_reset_and_elapsed_time() {
        let mut r = Rates::new();
        assert_eq!(r.sample(0, 100, 1.), (0, 0));
        assert_eq!(r.sample(0, 400, 3.), (300, 150));
        assert_eq!(r.sample(0, 1, 4.), (0, 0));
        assert_eq!(r.sample(0, 101, 5.), (100, 100));
        assert_eq!(r.sample(0, 900, 5.), (0, 0));
    }
    #[test]
    fn shared_presets_and_parsers() {
        let themes = themes();
        assert_eq!(themes.len(), 6);
        assert_eq!(themes[4].name, "Paper");
        assert_eq!(themes[0].colors[5], [0., 0., 0., 0.4]);
        assert_eq!(
            metrics("tokens_input_total 123\nrequest_cost 0.25\n"),
            Some((123, 0.25))
        );
        assert_eq!(codex_record(br#"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":42}}}}"#), Some(42));
        assert_eq!(codex_record(b"{broken"), None);
    }
    #[test]
    fn abi_rejects_invalid_buffers_without_writing() {
        let mut out = [42.0; 28];
        assert_eq!(unsafe { xrg_theme_colors(0, out.as_mut_ptr(), 27) }, -1);
        assert_eq!(out, [42.0; 28]);
        assert!(unsafe { xrg_history_create(0) }.is_null());
        assert_eq!(unsafe { xrg_history_append(std::ptr::null_mut(), 1.) }, -1);
        let h = History::new(4);
        assert_eq!(
            unsafe { xrg_history_copy(h.handle.as_ptr(), out.as_mut_ptr(), 3) },
            -1
        );
        assert_eq!(out, [42.0; 28]);
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, serde::Deserialize)]
pub struct Usage {
    pub input: u64,
    pub output: u64,
    pub total: u64,
}
impl Usage {
    pub fn checked_add(self, other: Self) -> Option<Self> {
        Some(Self {
            input: self.input.checked_add(other.input)?,
            output: self.output.checked_add(other.output)?,
            total: self.total.checked_add(other.total)?,
        })
    }
}
#[derive(serde::Deserialize)]
pub struct ProviderUsage {
    #[serde(flatten)]
    pub usage: Usage,
    pub identity: String,
    pub model: Option<String>,
}
#[derive(serde::Deserialize)]
pub struct UsageDetails {
    pub record: ProviderUsage,
    pub models: Vec<ProviderUsage>,
}
pub fn provider_details(bytes: &[u8], kind: u32) -> Option<UsageDetails> {
    let length = u32::try_from(bytes.len()).ok()?;
    let mut output = vec![0u8; 2048];
    loop {
        let count = unsafe {
            xrg_provider_details_parse(
                bytes.as_ptr(),
                length,
                kind,
                output.as_mut_ptr(),
                output.len() as u32,
            )
        };
        if count == -2 && output.len() == 2048 {
            output.resize(524_288, 0);
            continue;
        }
        if count < 0 || count as usize > output.len() {
            return None;
        }
        return serde_json::from_slice(&output[..count as usize]).ok();
    }
}
pub fn provider_usage(bytes: &[u8], kind: u32) -> Option<(Usage, String)> {
    let mut usage = Usage::default();
    let mut identity = [0u8; 1024];
    let length = u32::try_from(bytes.len()).ok()?;
    let count = unsafe {
        xrg_provider_usage_parse(
            bytes.as_ptr(),
            length,
            kind,
            &mut usage.input,
            &mut usage.output,
            &mut usage.total,
            identity.as_mut_ptr(),
            identity.len() as u32,
        )
    };
    (count >= 0).then(|| {
        (
            usage,
            String::from_utf8_lossy(&identity[..count as usize]).into_owned(),
        )
    })
}
pub fn model_names(bytes: &[u8]) -> Option<Vec<String>> {
    let mut output = vec![0u8; 1_048_576];
    let length = u32::try_from(bytes.len()).ok()?;
    let count = unsafe {
        xrg_model_names_parse(
            bytes.as_ptr(),
            length,
            output.as_mut_ptr(),
            output.len() as u32,
        )
    };
    if count < 0 {
        return None;
    }
    let text = std::str::from_utf8(&output[..count as usize]).ok()?;
    Some(if text.is_empty() {
        Vec::new()
    } else {
        text.split('\n').map(str::to_owned).collect()
    })
}

pub fn metrics_sample(text: &str) -> Option<(u64, Option<f64>)> {
    let (mut tokens, mut cost) = (0, 0.0);
    let flags = unsafe {
        xrg_metrics_sample_parse(
            text.as_ptr(),
            u32::try_from(text.len()).ok()?,
            &mut tokens,
            &mut cost,
        )
    };
    if flags < 0 || flags & 1 == 0 {
        None
    } else {
        Some((tokens, (flags & 2 != 0).then_some(cost)))
    }
}
