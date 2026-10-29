// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Real native event-loop, GPU paint, worker and persistence gate (20 seconds).
use super::{App, preferences};
use eframe::egui;
use std::{
    fs,
    os::unix::fs::DirBuilderExt,
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    time::{Duration, Instant},
};
use xrg_ng_linux::settings::{GraphStyle, Layout, Module, Store};
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
        fs::DirBuilder::new()
            .mode(0o700)
            .create(&directory)
            .map_err(|e| e.to_string())?;
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
                    let bytes: Vec<_> = image.pixels.iter().flat_map(|p| p.to_array()).collect();
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
        if self.stage == 5
            && self.wake.is_some_and(|(before, t)| {
                sequence <= before && t.elapsed() > Duration::from_secs(3)
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
                    app.show_processes = true;
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
                    self.stage = 3;
                }
                3 => {
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
                    next.sampling_interval_ms = 250;
                    next.network_min_scale = 65_536;
                    next.graph_width = 180;
                    next.layout = Layout::Horizontal;
                    next.window_opacity = 0.7;
                    next.activity_bars.visible = true;
                    let mut theme =
                        xrg_ng_linux::settings::ThemeDocument::new(&next.theme.palette()?);
                    theme.colors[0][3] = 0.;
                    next.theme = xrg_ng_linux::settings::ThemeChoice::Custom {
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
                    && self.wake.is_some_and(|(before, _)| sequence > before) =>
                {
                    let (_, saved, error) = Store::open(Some(self.path()));
                    if error.is_some() || saved != app.settings {
                        return Err(format!("Settings reopen mismatch: {error:?}"));
                    }
                    // Export and reimport use the same bounded portable formats as Preferences.
                    let palette = app.settings.theme.palette()?;
                    let theme = xrg_ng_linux::settings::ThemeDocument::new(&palette);
                    let path = self.directory.join("roundtrip.json");
                    theme.save(&path)?;
                    if xrg_ng_linux::settings::ThemeDocument::load(&path)? != theme {
                        return Err("Theme round trip changed palette".into());
                    }
                    self.capture(ctx, egui::ViewportId::ROOT, "XRG_SMOKE_LAYOUT_IMAGE");
                    self.stage = 6;
                }
                1 | 6 => {
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
            let bytes: Vec<_> = image.pixels.iter().flat_map(|p| p.to_array()).collect();
            writer.write_image_data(&bytes).map_err(|e| e.to_string())
        })();
        let _ = capture.sender.send(result);
        ctx.request_repaint_of(egui::ViewportId::ROOT);
    });
    ui.ctx()
        .layer_painter(egui::LayerId::new(egui::Order::Foreground, key))
        .add(egui::epaint::PaintCallback {
            rect: ui.max_rect(),
            callback: Arc::new(callback),
        });
}
