// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use std::{ffi::c_void, marker::PhantomData, ptr::NonNull, rc::Rc};

unsafe extern "C" {
    fn xrg_shared_abi_version() -> u32;
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
    fn xrg_codex_record_parse(bytes: *const u8, length: u32, tokens: *mut u64) -> i32;
}

pub fn check_abi() {
    assert_eq!(
        unsafe { xrg_shared_abi_version() },
        1,
        "Incompatible Swift core"
    );
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
        assert_eq!(themes[0].colors[5], [0.5, 0., 0.5, 0.4]);
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
