// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Real native event-loop, GPU paint, worker and persistence gate (20 seconds).
use super::{App, file_picker_smoke, preferences};
use crate::settings::{GraphStyle, Layout, Module, Store};
use eframe::egui;
#[cfg(target_os = "linux")]
use std::os::unix::fs::DirBuilderExt;
use std::{
    fs,
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    time::{Duration, Instant},
};
pub(super) struct Harness {
    directory: PathBuf,
    started: Instant,
    stage: u8,
    waiting: bool,
    wake: Option<(u64, Instant)>,
    sender: mpsc::Sender<Result<(), String>>,
    receiver: mpsc::Receiver<Result<(), String>>,
    pub success: Arc<AtomicBool>,
    pub draws: [u32; 13],
    picker: Option<file_picker_smoke::Harness>,
    clipboard_expected: Option<String>,
    graph_reset_expected: Option<[u64; 13]>,
}
impl Harness {
    pub fn new() -> Result<Self, String> {
        let directory = std::env::temp_dir().join(format!(
            "xrg-egui-smoke-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_err(|e| e.to_string())?
                .as_nanos()
        ));
        #[cfg(target_os = "linux")]
        {
            fs::DirBuilder::new()
                .mode(0o700)
                .create(&directory)
                .map_err(|e| e.to_string())?;
        }
        #[cfg(not(target_os = "linux"))]
        {
            fs::DirBuilder::new()
                .create(&directory)
                .map_err(|e| e.to_string())?;
        }
        let (sender, receiver) = mpsc::channel();
        Ok(Self {
            directory,
            started: Instant::now(),
            stage: 0,
            waiting: false,
            wake: None,
            sender,
            receiver,
            success: Arc::new(AtomicBool::new(false)),
            draws: [0; 13],
            picker: std::env::var_os("XRG_SMOKE_FILE_PICKER")
                .map(|_| file_picker_smoke::Harness::default()),
            clipboard_expected: None,
            graph_reset_expected: None,
        })
    }
    pub fn path(&self) -> PathBuf {
        self.directory.join("settings.conf")
    }
    fn capture(&mut self, ctx: &egui::Context, viewport: egui::ViewportId, variable: &str) {
        let Some(path) = std::env::var_os(variable).map(PathBuf::from) else {
            return;
        };
        self.waiting = true;
        if viewport != egui::ViewportId::ROOT {
            ctx.data_mut(|data| {
                data.insert_temp(
                    egui::Id::unique(("xrg-smoke-capture", viewport)),
                    Some(Capture {
                        path,
                        sender: self.sender.clone(),
                    }),
                )
            });
            ctx.request_repaint_of(egui::ViewportId::ROOT);
            return;
        }
        let sender = self.sender.clone();
        let check_opacity = variable == "XRG_SMOKE_LAYOUT_IMAGE";
        let repaint = ctx.clone();
        ctx.send_viewport_cmd_to(
            viewport,
            egui::ViewportCommand::Screenshot(egui::ScreenshotCallback::new(move |image| {
                let result = (|| {
                    if check_opacity {
                        let maximum=image.pixels.iter().map(|p|p.a()).max().unwrap_or(0);
                        let border=image.pixels.get(image.width()+1).map_or(0,|p|p.a());
                        if !image.pixels.iter().any(|p| {
                            let rgba=p.to_srgba_unmultiplied();
                            rgba[..3].iter().all(|v|*v>=250)&&(177..=181).contains(&rgba[3])
                        }) {return Err("Compositing changed opaque white text instead of only its opacity".into());}
                        if !(177..=181).contains(&maximum)||!(177..=181).contains(&border) {
                            return Err(format!("Whole-window opacity compounded or lost its opaque theme base: max={maximum} border={border}"));
                        }
                    }
                    let file = fs::File::create(path).map_err(|e| e.to_string())?;
                    let mut encoder =
                        png::Encoder::new(file, image.width() as u32, image.height() as u32);
                    encoder.set_color(png::ColorType::Rgba);
                    encoder.set_depth(png::BitDepth::Eight);
                    let mut writer = encoder.write_header().map_err(|e| e.to_string())?;
                    let bytes: Vec<_> = image.pixels.iter().flat_map(|p| p.to_srgba_unmultiplied()).collect();
                    writer.write_image_data(&bytes).map_err(|e| e.to_string())
                })();
                let _ = sender.send(result);
                repaint.request_repaint();
            })),
        );
    }
    fn fail(&self, ctx: &egui::Context, error: &str) {
        eprintln!("EGUI_SMOKE_FAILED stage={} {error}", self.stage);
        ctx.send_viewport_cmd_to(egui::ViewportId::ROOT, egui::ViewportCommand::Close);
    }
    pub fn tick(&mut self, app: &mut App, ctx: &egui::Context) {
        ctx.request_repaint_after(Duration::from_millis(100));
        if let Some(error) = app.compositor.lock().unwrap().error.as_ref() {
            self.fail(ctx, error);
            return;
        }
        if self.started.elapsed() > Duration::from_secs(20) {
            self.fail(ctx, "20-second deadline exceeded");
            return;
        }
        if self.waiting {
            match self.receiver.try_recv() {
                Ok(Ok(())) => self.waiting = false,
                Ok(Err(e)) => {
                    self.fail(ctx, &e);
                    return;
                }
                Err(_) => return,
            }
        }
        let Some(snapshot) = app.snapshot.as_ref().filter(|s| s.valid && s.sequence >= 3) else {
            return;
        };
        if !app
            .settings
            .modules
            .iter()
            .filter(|m| m.visible)
            .all(|m| self.draws[m.id.index()] >= 3)
        {
            return;
        }
        let sequence = snapshot.sequence;
        let graph_generations = snapshot.graph_generations;
        let sensors = snapshot.sensors.clone();
        if let Some(mut picker) = self.picker.take() {
            match picker.tick(app, ctx, &self.directory) {
                Ok(file_picker_smoke::Step::Capture(variable)) => {
                    self.capture(ctx, egui::ViewportId::from_hash_of("preferences"), variable)
                }
                Ok(file_picker_smoke::Step::Done) => {
                    if !self.success.swap(true, Ordering::Relaxed) {
                        println!(
                            "EGUI_FILE_PICKER_SMOKE_OK samples={sequence} xtf=loaded json=saved replace=confirmed cancel=preserved legacy=reviewed invalid=rejected"
                        );
                    }
                    ctx.send_viewport_cmd_to(egui::ViewportId::ROOT, egui::ViewportCommand::Close);
                }
                Ok(file_picker_smoke::Step::Pending) => (),
                Err(error) => self.fail(ctx, &error),
            }
            self.picker = Some(picker);
            return;
        }

        if self.stage == 5
            && self.wake.is_some_and(|(before, t)| {
                (sequence <= before
                    || app.snapshot.as_ref().is_none_or(|s| {
                        s.selection.cpu_history_samples != 300
                            || s.selection.cpu_history_minutes != 1
                            || !s.panels.iter().find(|p| p.title == "CPU").is_some_and(|p| {
                                p.series.len() == 3 && p.series.iter().all(|v| v.len() == 301)
                            })
                    }))
                    && t.elapsed() > Duration::from_secs(3)
            })
        {
            self.fail(
                ctx,
                "Applying the shorter sampling interval did not wake the worker within 3 seconds",
            );
            return;
        }
        let result = (|| -> Result<(), String> {
            match self.stage {
                0 => {
                    self.capture(ctx, egui::ViewportId::ROOT, "XRG_SMOKE_IMAGE");
                    self.stage = 1;
                }
                1 if std::env::var_os("XRG_SMOKE_STYLE").is_none() => {
                    app.preferences();
                    if std::env::var_os("XRG_SMOKE_AI_PREFS").is_some()
                        && let Some(editor) = &mut app.preferences
                    {
                        editor.tab = 3;
                    }
                    if let Some(editor) = &mut app.preferences {
                        match std::env::var("XRG_SMOKE_PREFS_TAB").as_deref() {
                            Ok("weather") => {
                                editor.tab = 4;
                                editor.draft.weather.temperature_units =
                                    Some(crate::weather::Units::Us);
                                editor.draft.weather.distance_units =
                                    Some(crate::weather::Units::Metric);
                                editor.draft.weather.pressure_units =
                                    Some(crate::weather::Units::Metric);
                                editor.draft.weather.wind_units =
                                    Some(crate::weather::WindUnits::Knots);
                            }
                            Ok("graphs") => editor.tab = 1,
                            Ok("sources") => editor.tab = 2,
                            Ok("sources-time") => {
                                editor.tab = 2;
                                editor.draft.metrics.cpu_history_minutes = 1;
                                editor
                                    .draft
                                    .metrics
                                    .history_minutes
                                    .insert(Module::Memory, 4);
                                editor
                                    .draft
                                    .metrics
                                    .history_minutes
                                    .insert(Module::Network, 2);
                                editor.draft.metrics.history_minutes.insert(Module::Disk, 3);
                                editor.draft.metrics.history_minutes.insert(Module::Gpu, 5);
                                editor.draft.metrics.history_minutes.insert(Module::Tpu, 6);
                                editor
                                    .draft
                                    .metrics
                                    .history_minutes
                                    .insert(Module::GpuMemory, 7);
                                editor.draft.metrics.history_minutes.insert(Module::Fans, 8);
                                editor
                                    .draft
                                    .metrics
                                    .history_minutes
                                    .insert(Module::Temperature, 9);
                                editor
                                    .draft
                                    .metrics
                                    .history_minutes
                                    .insert(Module::Battery, 10);
                            }
                            Ok("ai-time") => {
                                editor.tab = 3;
                                editor.draft.ai.history_minutes = 10;
                            }
                            _ => (),
                        }
                    }
                    app.show_processes = true;
                    app.show_sensors = true;
                    app.show_ai = true;
                    app.show_weather = true;
                    app.details.insert(Module::Cpu);
                    self.stage = 2;
                }
                2 => {
                    self.capture(
                        ctx,
                        egui::ViewportId::from_hash_of("preferences"),
                        "XRG_SMOKE_PREFS_IMAGE",
                    );
                    self.stage = 8;
                }
                8 => {
                    // Enabled only by isolated X11 CI. Check an external clipboard
                    // consumer so egui's internal fallback cannot pass this gate.
                    if std::env::var_os("XRG_SMOKE_SENSOR_CLIPBOARD").is_some() {
                        let text = sensors.text(app.settings.temperature_units);
                        ctx.copy_text(text.clone());
                        self.clipboard_expected = Some(text);
                    }
                    self.capture(
                        ctx,
                        egui::ViewportId::from_hash_of("sensors"),
                        "XRG_SMOKE_SENSOR_IMAGE",
                    );
                    self.stage = 3;
                }
                3 => {
                    if let Some(expected) = self.clipboard_expected.take() {
                        self.waiting = true;
                        let sender = self.sender.clone();
                        std::thread::spawn(move || {
                            let result = crate::command::BoundedCommand::default()
                                .output(
                                    std::path::Path::new("/usr/bin/xclip"),
                                    &["-selection", "clipboard", "-out"],
                                    Duration::from_secs(2),
                                    expected.len() + 1,
                                )
                                .and_then(|bytes| {
                                    if bytes == expected.as_bytes() {
                                        Ok(())
                                    } else {
                                        Err("Sensor report did not reach the native clipboard"
                                            .into())
                                    }
                                });
                            if result.is_ok() {
                                println!(
                                    "SENSOR_CLIPBOARD_SMOKE_OK external X11 consumer matched report"
                                );
                            }
                            let _ = sender.send(result);
                        });
                        return Ok(());
                    }
                    // Cancel preserves the complete saved model. Defaults are draft-only.
                    let before = app.settings.clone();
                    let mut draft = preferences::Editor::new(before.clone());
                    draft.restore_defaults();
                    drop(draft);
                    if app.settings != before {
                        return Err("Cancelled draft changed active settings".into());
                    }
                    let mut next = app.settings.clone();
                    next.sampling_interval_ms = 10_000;
                    app.apply(next, ctx)?;
                    self.stage = 4;
                }
                4 if app.saved_revision == app.revision => {
                    let mut next = app.settings.clone();
                    next.sampling_interval_ms = 200;
                    next.ai.history_samples = 1440;
                    next.ai.history_minutes = 30;
                    next.metrics.cpu_history_samples = 300;
                    next.metrics.cpu_history_minutes = 1;
                    next.metrics.history_samples.insert(Module::Memory, 360);
                    next.metrics.history_minutes.insert(Module::Memory, 4);
                    next.metrics.history_samples.insert(Module::Network, 480);
                    next.metrics.history_minutes.insert(Module::Network, 2);
                    next.metrics.history_minutes.insert(Module::Disk, 3);
                    next.metrics.history_samples.insert(Module::Disk, 600);
                    next.metrics.history_samples.insert(Module::Gpu, 720);
                    next.metrics.history_minutes.insert(Module::Gpu, 5);
                    next.metrics.history_samples.insert(Module::Tpu, 840);
                    next.metrics.history_minutes.insert(Module::Tpu, 6);
                    next.metrics.history_samples.insert(Module::GpuMemory, 960);
                    next.metrics.history_minutes.insert(Module::GpuMemory, 7);
                    next.metrics
                        .history_samples
                        .insert(Module::Temperature, 1080);
                    next.metrics.history_minutes.insert(Module::Temperature, 9);
                    next.metrics.history_samples.insert(Module::Fans, 1200);
                    next.metrics.history_minutes.insert(Module::Fans, 8);
                    next.metrics.history_samples.insert(Module::Battery, 1320);
                    next.metrics.history_minutes.insert(Module::Battery, 10);
                    next.network_min_scale = 65_536;
                    next.graph_width = 180;
                    next.layout = Layout::Horizontal;
                    next.window_opacity = 0.7;
                    next.activity_bars.visible = true;
                    let mut theme = crate::settings::ThemeDocument::new(&next.theme.palette()?);
                    theme.colors[0][3] = 0.;
                    next.theme = crate::settings::ThemeChoice::Custom {
                        theme: Box::new(theme),
                    };
                    for (i, m) in next.modules.iter_mut().enumerate() {
                        m.style = GraphStyle::ALL[i % 4];
                        m.height = Some(100 + i as u32);
                    }
                    next.modules[0].colors.background = Some([0.02, 0.03, 0.1, 0.25]);
                    app.apply(next, ctx)?;
                    self.wake = Some((sequence, Instant::now()));
                    app.preferences = None;
                    self.stage = 5;
                }
                5 if app.saved_revision == app.revision
                    && self.wake.is_some_and(|(before, _)| sequence > before)
                    && app.snapshot.as_ref().is_some_and(|s| {
                        s.selection.cpu_history_samples == 300
                            && s.selection.cpu_history_minutes == 1
                            && s.panels.iter().find(|p| p.title == "CPU").is_some_and(|p| {
                                p.series.len() == 3 && p.series.iter().all(|v| v.len() == 301)
                            })
                    }) =>
                {
                    if !app.snapshot.as_ref().is_some_and(|s| {
                        s.panels.iter().find(|p| p.title == "CPU").is_some_and(|p| {
                            p.series.len() == 3 && p.series.iter().all(|v| v.len() == 301)
                        })
                    }) {
                        return Err(
                            "Applied CPU history capacity did not reach the live worker".into()
                        );
                    }
                    println!(
                        "CPU_HISTORY_SMOKE_OK 1 minute, 301 positions at 200 ms, 300 fallback samples, live worker acknowledged"
                    );
                    let snapshot = app.snapshot.as_ref().unwrap();
                    for (module, title, count) in [
                        (Module::Memory, "Memory", 360),
                        (Module::Network, "Network", 480),
                        (Module::Disk, "Disk", 600),
                        (Module::Gpu, "GPU", 720),
                        (Module::Tpu, "TPU / NPU", 840),
                        (Module::GpuMemory, "VRAM", 960),
                        (Module::Temperature, "Temperature", 1080),
                        (Module::Fans, "Fans", 1200),
                        (Module::Battery, "Battery", 1320),
                    ] {
                        let (minutes, positions) = match module {
                            Module::Battery => (10, 3001),
                            Module::Temperature => (9, 2701),
                            Module::Fans => (8, 2401),
                            Module::GpuMemory => (7, 2101),
                            Module::Tpu => (6, 1801),
                            Module::Gpu => (5, 1501),
                            Module::Memory => (4, 1201),
                            Module::Network => (2, 601),
                            Module::Disk => (3, 901),
                            _ => (0, count),
                        };
                        if snapshot.selection.retained_minutes(module) != minutes
                            || snapshot.selection.retained_samples(module) != count
                            || !snapshot
                                .panels
                                .iter()
                                .find(|p| p.title == title)
                                .is_some_and(|p| {
                                    p.series.iter().all(|v| v.len() == positions as usize)
                                })
                        {
                            return Err(format!(
                                "Applied {title} history capacity did not reach the live worker"
                            ));
                        }
                    }
                    println!(
                        "SYSTEM_HISTORY_SMOKE_OK Memory=4min/1201positions (360 fallback) Network=2min/601positions Disk=3min/901positions at 200ms, 480/600 fallback samples, live worker acknowledged"
                    );
                    println!(
                        "GRAPHICS_HISTORY_SMOKE_OK GPU=5min/1501positions (720 fallback) NPU=6min/1801positions (840 fallback) VRAM=7min/2101positions (960 fallback), capacities applied; unavailable inputs remain unavailable"
                    );
                    println!(
                        "SENSOR_HISTORY_SMOKE_OK Temperature=9min/2701positions (1080 fallback) Fans=8min/2401positions (1200 fallback) Battery=10min/3001positions (1320 fallback), capacities applied; unavailable inputs remain unavailable"
                    );
                    let (_, saved, error) = Store::open(Some(self.path()));
                    if saved.ai.history_samples != 1440 || saved.ai.history_minutes != 30 {
                        return Err("AI history preference did not survive save/reopen".into());
                    }
                    println!(
                        "AI_HISTORY_PREFS_SMOKE_OK 1440 fallback samples and 30 minute window persisted; live AI collection remains disabled in desktop smoke"
                    );
                    if error.is_some() || saved != app.settings {
                        return Err(format!("Settings reopen mismatch: {error:?}"));
                    }
                    // Export and reimport use the same bounded portable formats as Preferences.
                    let palette = app.settings.theme.palette()?;
                    let theme = crate::settings::ThemeDocument::new(&palette);
                    let path = self.directory.join("roundtrip.json");
                    theme.save(&path)?;
                    if crate::settings::ThemeDocument::load(&path)? != theme {
                        return Err("Theme round trip changed palette".into());
                    }
                    self.capture(ctx, egui::ViewportId::ROOT, "XRG_SMOKE_LAYOUT_IMAGE");
                    self.stage = 6;
                }
                6 => {
                    self.graph_reset_expected = Some(graph_generations.map(|g| g.wrapping_add(1)));
                    app.worker.graph_control().clear_all()?;
                    self.stage = 9;
                }
                1 | 9
                    if self.stage == 1 || self.graph_reset_expected == Some(graph_generations) =>
                {
                    if self.stage == 9 {
                        println!("GRAPH_RESET_SMOKE_OK all 13 worker histories acknowledged");
                    }
                    println!(
                        "EGUI_SMOKE_OK samples={sequence} draws={} mode={} renderer=glow",
                        self.draws.iter().sum::<u32>(),
                        if self.stage == 1 {
                            "style"
                        } else {
                            "settings-theme-roundtrip"
                        }
                    );
                    self.success.store(true, Ordering::Relaxed);
                    self.stage = 7;
                    ctx.send_viewport_cmd_to(egui::ViewportId::ROOT, egui::ViewportCommand::Close);
                }
                _ => (),
            }
            Ok(())
        })();
        if let Err(e) = result {
            self.fail(ctx, &e);
        }
    }
}
impl Drop for Harness {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.directory);
    }
}

#[derive(Clone)]
struct Capture {
    path: PathBuf,
    sender: mpsc::Sender<Result<(), String>>,
}
/// eframe's Glow immediate-viewport path doesn't drain Screenshot commands.
/// Capture its actual framebuffer after the final child-window paint instead.
pub(super) fn paint_capture(ui: &mut egui::Ui) {
    let viewport = ui.ctx().viewport_id();
    let key = egui::Id::unique(("xrg-smoke-capture", viewport));
    let Some(capture) = ui
        .ctx()
        .data_mut(|data| data.remove_temp::<Option<Capture>>(key).flatten())
    else {
        return;
    };
    let done = AtomicBool::new(false);
    let ctx = ui.ctx().clone();
    let callback = eframe::egui_glow::CallbackFn::new(move |info, painter| {
        if done.swap(true, Ordering::Relaxed) {
            return;
        }
        let image = painter.read_screen_rgba(info.screen_size_px);
        let result = (|| {
            let file = fs::File::create(&capture.path).map_err(|e| e.to_string())?;
            let mut encoder = png::Encoder::new(file, image.width() as u32, image.height() as u32);
            encoder.set_color(png::ColorType::Rgba);
            encoder.set_depth(png::BitDepth::Eight);
            let mut writer = encoder.write_header().map_err(|e| e.to_string())?;
            let bytes: Vec<_> = image
                .pixels
                .iter()
                .flat_map(|p| p.to_srgba_unmultiplied())
                .collect();
            writer.write_image_data(&bytes).map_err(|e| e.to_string())
        })();
        let _ = capture.sender.send(result);
        ctx.request_repaint_of(egui::ViewportId::ROOT);
    });
    ui.ctx()
        .layer_painter(egui::LayerId::new(egui::Order::Debug, key))
        .add(egui::epaint::PaintCallback {
            rect: ui.max_rect(),
            callback: Arc::new(callback),
        });
}
