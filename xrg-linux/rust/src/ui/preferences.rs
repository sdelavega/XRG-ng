// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! The Linux Aether7b settings window (0.2.3 spec §5): the shared settings
//! catalog drives an egui window with a 40 px headerbar, 12 px corners, the
//! opaque `surface_chrome_fallback` sidebar, one flat card per catalog group
//! with `//` eyebrows, instant apply through the store (the shared core is
//! the only validator), the danger rim on refused values, per-section resets
//! with confirmation, the unreadable-file banner with its Replace action,
//! theme import/export and the GTK legacy import — matching the macOS
//! window section for section.
use super::{
    App, aether7b,
    file_picker::{Action, Choice, Decision, PathField, Picker},
    settings_controls::{self, Fields, Outcome, Rendered},
    settings_style,
};
use crate::{
    legacy,
    metrics::{Inventory, SourceOption},
    settings::{
        Store, ThemeDocument,
        document::{Catalog, SetError},
    },
};
use eframe::egui;
use serde_json::{Value, json};
use std::{path::PathBuf, sync::mpsc};

#[cfg(test)]
#[path = "settings_window_tests.rs"]
mod tests;

/// Supplies the runtime options of `source` controls: sensors, network
/// interfaces, disks, GPUs — the platform's live enumeration (spec §1).
pub trait SourceProvider {
    /// The options of one source kind, in display order: `id` is the
    /// persisted choice, `label` what the user sees.
    fn options(&self, kind: &str) -> Vec<SourceOption>;
}

/// The sidebar's section titles, in catalog order (decision D7) — the same
/// eight, including Stocks, the macOS window shows.
pub const SECTION_TITLES: [(&str, &str); 8] = [
    ("general", "General"),
    ("appearance", "Appearance"),
    ("graphs", "Graphs"),
    ("sources", "Sources"),
    ("ai", "AI"),
    ("weather", "Weather"),
    ("stocks", "Stocks"),
    ("themes", "Themes & import"),
];

/// The sidebar's width, in the 12 px-corner window's canvas.
pub const SIDEBAR_WIDTH: f32 = 190.;

/// The content pane's side insets — the token gutter (fix L2): the
/// section eyebrow, title, banner and cards all sit inside it, so the
/// cards align with the eyebrow and fill the pane's width.
const PANE_GUTTER: egui::Margin = egui::Margin {
    left: aether7b::SPACE_S6 as i8,
    right: aether7b::SPACE_S6 as i8,
    top: 0,
    bottom: aether7b::SPACE_S8 as i8,
};

/// One completed asynchronous file operation: a loaded theme, a saved theme,
/// a reviewed legacy import.
enum Loaded {
    Theme(Box<ThemeDocument>),
    Legacy(Box<legacy::Import>),
    Saved,
}

/// The settings window: sidebar sections in catalog order, instant apply,
/// danger validation, resets with confirmation, unreadable-file recovery,
/// theme import/export and the legacy GTK import — all Aether7b.
pub struct SettingsWindow {
    catalog: Catalog,
    section: String,
    fields: Fields,
    rendered: Vec<Rendered>,
    message: Option<String>,
    confirm_reset: Option<String>,
    /// The file chooser (theme import/export, path choices, legacy review).
    pub(super) picker: Option<Picker>,
    pending: Option<mpsc::Receiver<Result<Loaded, String>>>,
    import: Option<legacy::Import>,
    legacy_path: PathField,
    /// The path entry a chooser is picking for.
    path_target: Option<String>,
    /// The changes made while the settings document was unreadable: kept
    /// in memory (the banner's promise), applied once the file is replaced.
    held: std::collections::BTreeMap<String, Value>,
    /// The current section's full content height, measured while rendering:
    /// the snapshot walker sizes its capture viewport from it.
    content_height: f32,
    open: bool,
    dirty: bool,
}

impl SettingsWindow {
    pub fn new(catalog: Catalog) -> Self {
        let section = catalog
            .sections
            .first()
            .cloned()
            .unwrap_or_else(|| "general".into());
        // The desktop's reduced-motion preference is read once per
        // process, here — at open, before the first frame — so a slow
        // query tool can never stall a frame.
        let _ = settings_style::reduced_motion_requested();
        Self {
            catalog,
            section,
            fields: Fields::default(),
            rendered: Vec::new(),
            message: None,
            confirm_reset: None,
            picker: None,
            pending: None,
            import: None,
            legacy_path: PathField::new(
                legacy::path_from(
                    std::env::var_os("XDG_CONFIG_HOME").as_deref(),
                    std::env::var_os("HOME").as_deref(),
                )
                .unwrap_or_default(),
            ),
            path_target: None,
            held: std::collections::BTreeMap::new(),
            content_height: 0.,
            open: true,
            dirty: false,
        }
    }

    /// The section the window shows.
    pub fn section(&self) -> &str {
        &self.section
    }

    /// Open one section; catalog names only, so the sidebar, the tests and
    /// the smoke harness all agree with the catalog.
    pub fn select_section(&mut self, section: &str) -> bool {
        if self.catalog.sections.iter().any(|name| name == section) {
            self.section = section.to_owned();
            self.fields = Fields::default();
            true
        } else {
            false
        }
    }

    /// Every control the last frame rendered, in order — the tests' walk.
    pub fn rendered(&self) -> &[Rendered] {
        &self.rendered
    }

    /// Whether the user closed the window (the ✕, Escape or the system).
    pub fn closed(&self) -> bool {
        !self.open
    }

    /// Whether the window changed the stored settings since the last ask;
    /// the App adopts the store's view when it did (lesson h).
    pub fn take_dirty(&mut self) -> bool {
        std::mem::take(&mut self.dirty)
    }

    /// The window's one-line status message, if any.
    pub fn message(&self) -> Option<&str> {
        self.message.as_deref()
    }

    /// Whether a file operation is still running.
    pub fn busy(&self) -> bool {
        self.pending.is_some()
    }

    /// Whether a reviewed legacy import is waiting for its accept.
    pub fn import_ready(&self) -> bool {
        self.import.is_some()
    }

    /// The danger reason one entry currently shows, if any.
    pub fn error(&self, id: &str) -> Option<&str> {
        self.fields.error(id)
    }

    /// Accept the reviewed legacy import: the imported view is saved whole,
    /// exactly the document the old draft-then-Apply flow produced, and it
    /// applies immediately (decision D9 — no draft).
    pub fn accept_import(&mut self, store: &mut Store) -> Result<(), String> {
        let Some(import) = self.import.take() else {
            return Ok(());
        };
        store.save(&import.settings)?;
        self.dirty = true;
        for entry in &self.catalog.entries {
            self.fields.bump(&entry.id);
        }
        Ok(())
    }

    /// Select a built-in theme preset, the Themes picker's action: the
    /// preset's palette and name follow through the store (lesson f).
    pub fn choose_preset(&mut self, name: &str, store: &mut Store) -> Result<(), String> {
        apply_preset(store, name)
            .map_err(|error| settings_controls::refusal_reason(&error, self.preset_entry()))?;
        self.dirty = true;
        self.fields.bump("themes.name");
        Ok(())
    }

    fn preset_entry(&self) -> &crate::settings::document::CatalogEntry {
        self.catalog
            .entries
            .iter()
            .find(|entry| entry.id == "themes.preset")
            .expect("the shared catalog defines the theme preset")
    }

    /// Open the file chooser on one action, seeded at a path — the smoke
    /// harness's way in, and the path fields' "Browse…" buttons.
    pub(super) fn choose_at(&mut self, action: Action, path: PathBuf, ctx: &egui::Context) {
        self.select_section("themes");
        self.picker = Some(Picker::new(action, path, ctx));
    }

    /// Render the window into its viewport for one frame. The 40 px
    /// headerbar, the 12 px corners and the opaque sidebar are drawn here
    /// (egui has no backdrop blur); the sections and their controls come
    /// from the catalog.
    pub fn show(&mut self, ctx: &egui::Context, store: &mut Store, sources: &dyn SourceProvider) {
        let builder = egui::ViewportBuilder::default()
            .with_title("XRG-ng Settings")
            .with_inner_size(self.viewport_size(store, sources))
            .with_decorations(false)
            .with_transparent(true);
        ctx.show_viewport_immediate(
            egui::ViewportId::from_hash_of("preferences"),
            builder,
            |ui, _| self.render(ui, store, sources),
        );
    }

    /// The viewport's inner size. The production window is a fixed 760×620
    /// with a scrolling pane; the snapshot walker (which sets
    /// XRG_SMOKE_SETTINGS_SNAPSHOT_DIR) instead captures one PNG per
    /// section, and a section taller than the pane would be cut at the
    /// scroll fold — so its viewport first measures the section with a
    /// headless pass through the very renderer the tests use, then grows
    /// to fit the whole section. The production size is untouched.
    fn viewport_size(&mut self, store: &mut Store, sources: &dyn SourceProvider) -> egui::Vec2 {
        const PRODUCTION: egui::Vec2 = egui::Vec2::new(760., 620.);
        if !snapshot_walk() {
            return PRODUCTION;
        }
        let headless = egui::Context::default();
        let mut measured = headless.run_ui(
            egui::RawInput {
                screen_rect: Some(egui::Rect::from_min_size(egui::Pos2::ZERO, PRODUCTION)),
                ..Default::default()
            },
            |ui| self.render(ui, store, sources),
        );
        measured.textures_delta.clear();
        let headerbar = 40.;
        egui::Vec2::new(
            PRODUCTION.x,
            (headerbar + self.content_height).clamp(PRODUCTION.y, 8000.),
        )
    }

    /// Render the window's whole frame into one ui — the same layout the
    /// real viewport shows, with the Aether7b style applied for the pass.
    /// `show` drives this inside the window's viewport; the tests drive it
    /// directly into a full-size ui (the embedded fallback headless contexts
    /// use auto-sizes the floating window, which would clip the frame).
    pub fn render(&mut self, ui: &mut egui::Ui, store: &mut Store, sources: &dyn SourceProvider) {
        let dark = settings_style::dark(ui.ctx());
        let theme = ui.ctx().theme();
        let previous = ui.ctx().global_style();
        let style = settings_style::style(dark);
        ui.ctx().set_style_of(theme, style.clone());
        // The host ui's style snapshot was taken when the ui was created,
        // before this call: every widget the frame builds reads that
        // snapshot — including egui's own chrome — so it must carry the
        // token style too, or egui's defaults would bleed through.
        ui.set_style(style);
        self.frame(ui, dark, store, sources);
        ui.ctx().set_style_of(theme, previous);
    }

    /// Run one file operation on its own thread, reporting through the
    /// channel the next frame polls — the production pattern the old
    /// preferences used and the smoke gate drives.
    fn start(
        &mut self,
        ctx: &egui::Context,
        task: impl FnOnce() -> Result<Loaded, String> + Send + 'static,
    ) {
        let (sender, receiver) = mpsc::channel();
        self.pending = Some(receiver);
        self.message = Some("Working…".into());
        let ctx = ctx.clone();
        std::thread::spawn(move || {
            let _ = sender.send(task());
            ctx.request_repaint();
        });
    }

    fn poll(&mut self, store: &mut Store) {
        let Some(receiver) = &self.pending else {
            return;
        };
        match receiver.try_recv() {
            Ok(Ok(loaded)) => {
                self.pending = None;
                match loaded {
                    Loaded::Theme(theme) => self.store_theme(store, *theme),
                    Loaded::Legacy(import) => {
                        self.import = Some(*import);
                        self.message = None;
                    }
                    Loaded::Saved => self.message = Some("Theme saved.".into()),
                }
            }
            Ok(Err(error)) => {
                self.pending = None;
                self.message = Some(error);
            }
            Err(mpsc::TryRecvError::Disconnected) => {
                self.pending = None;
                self.message = Some("File operation stopped before returning a result.".into());
            }
            Err(mpsc::TryRecvError::Empty) => (),
        }
    }

    /// A loaded theme file becomes the current theme: its palette and name
    /// are written through the store, and the preset is marked Custom when
    /// the palette no longer matches the selected built-in (lesson f).
    fn store_theme(&mut self, store: &mut Store, theme: ThemeDocument) {
        for (index, id) in settings_controls::PALETTE_IDS.iter().enumerate() {
            if let Err(error) = store.set(id, json!(theme.colors[index])) {
                let reason = settings_controls::refusal_reason(&error, self.palette_entry(id));
                self.message = Some(reason);
                return;
            }
        }
        let _ = store.set("themes.name", json!(theme.name));
        mark_custom_preset(store, &self.catalog);
        self.dirty = true;
        for id in settings_controls::PALETTE_IDS {
            self.fields.bump(id);
        }
        self.fields.bump("themes.name");
        self.fields.bump("themes.preset");
        self.message = Some("Theme imported.".into());
    }

    fn palette_entry(&self, id: &str) -> &crate::settings::document::CatalogEntry {
        self.catalog
            .entries
            .iter()
            .find(|entry| entry.id == id)
            .expect("the shared catalog defines every palette colour")
    }

    fn load_theme(&mut self, path: PathBuf, ctx: &egui::Context) {
        self.start(ctx, move || {
            Ok(Loaded::Theme(Box::new(ThemeDocument::load(&path)?)))
        });
    }

    fn save_theme(&mut self, path: PathBuf, replace: bool, store: &mut Store, ctx: &egui::Context) {
        let document = match store.settings().theme.palette() {
            Ok(palette) => ThemeDocument::new(&palette),
            Err(error) => {
                self.message = Some(error);
                return;
            }
        };
        let preferences = crate::settings::preferences_path();
        self.start(ctx, move || {
            if let Some(preferences) = &preferences
                && (path == *preferences
                    || path
                        .canonicalize()
                        .ok()
                        .zip(preferences.canonicalize().ok())
                        .is_some_and(|(a, b)| a == b))
            {
                return Err("Export a theme separately from application preferences.".into());
            }
            if replace {
                document.save(&path)?;
            } else {
                document.save_new(&path)?;
            }
            Ok(Loaded::Saved)
        });
    }

    fn review_legacy(&mut self, path: PathBuf, store: &mut Store, ctx: &egui::Context) {
        let base = store.settings().clone();
        self.start(ctx, move || {
            Ok(Loaded::Legacy(Box::new(legacy::load(&path, &base)?)))
        });
    }

    /// Save edits a repair could not persist. Successes leave the held map;
    /// a failure stays held, still shown, with its reason — the same
    /// retention the repair uses, so the user can retry again.
    fn retry_unpersisted(&mut self, store: &mut Store) {
        let pending = std::mem::take(&mut self.held);
        let mut failures: Vec<(String, Value, SetError)> = Vec::new();
        for (id, value) in pending {
            match store.set(&id, value.clone()) {
                Ok(()) => {
                    self.dirty = true;
                    // Reconcile with the entry's edit buffer before
                    // clearing it: a newer, unsaved edit survives the
                    // retry (fix round 3, review rr2 finding 1).
                    self.fields.retry_saved(&id, &value);
                }
                Err(error) => failures.push((id, value, error)),
            }
        }
        for (id, value, error) in failures {
            let reason = self
                .catalog
                .entries
                .iter()
                .find(|entry| entry.id == id)
                .map(|entry| settings_controls::refusal_reason(&error, entry))
                .unwrap_or_else(|| "The value could not be saved.".into());
            self.fields.refuse(&id, reason.clone());
            self.message = Some(reason);
            self.held.insert(id, value);
        }
        if self.held.is_empty() {
            self.message = Some("The changes that could not be saved were saved.".into());
        }
    }

    /// The window's one frame.
    fn frame(
        &mut self,
        ui: &mut egui::Ui,
        dark: bool,
        store: &mut Store,
        sources: &dyn SourceProvider,
    ) {
        self.poll(store);
        self.rendered.clear();
        // Close affordances: Escape belongs to the modal, the chooser and
        // the colour pickers first; each of them consumes it before the
        // window sees it.
        if ui.input(|input| input.viewport().close_requested())
            || (self.picker.is_none()
                && self.confirm_reset.is_none()
                && self.fields.color_popups_open() == 0
                && ui
                    .input_mut(|input| input.consume_key(egui::Modifiers::NONE, egui::Key::Escape)))
        {
            self.open = false;
        }
        // The canvas: 12 px rounded corners on the token canvas, the aurora
        // wash above-left, the corners left transparent for the desktop.
        let canvas = ui.max_rect();
        ui.painter().rect_filled(
            canvas,
            egui::CornerRadius::same(aether7b::RADIUS_LG as u8),
            aether7b::bg_canvas(dark),
        );
        settings_style::aurora_wash(ui.painter(), canvas, dark);
        let header =
            egui::Rect::from_min_max(canvas.min, egui::pos2(canvas.max.x, canvas.min.y + 40.));
        ui.painter().rect_filled(
            header,
            egui::CornerRadius {
                nw: aether7b::RADIUS_LG as u8,
                ne: aether7b::RADIUS_LG as u8,
                sw: 0,
                se: 0,
            },
            aether7b::surface_chrome_fallback(dark),
        );
        ui.painter().hline(
            header.left()..=header.right(),
            header.bottom(),
            egui::Stroke::new(1., aether7b::border(dark)),
        );
        let title = ui.painter().layout_no_wrap(
            "Settings".to_owned(),
            settings_style::sans(aether7b::TYPE_SM.0),
            aether7b::text_main(dark),
        );
        ui.painter().add(egui::epaint::TextShape::new(
            egui::pos2(
                header.center().x - title.size().x / 2.,
                header.center().y - title.size().y / 2.,
            ),
            title,
            aether7b::text_main(dark),
        ));
        let body = egui::Rect::from_min_max(egui::pos2(canvas.min.x, header.max.y), canvas.max);
        let sidebar =
            egui::Rect::from_min_max(body.min, egui::pos2(body.min.x + SIDEBAR_WIDTH, body.max.y));
        // The sidebar reaches the window's bottom-left corner, so it
        // rounds that one like the canvas: the 12 px corner the desktop
        // shows through stays transparent.
        ui.painter().rect_filled(
            sidebar,
            egui::CornerRadius {
                nw: 0,
                ne: 0,
                sw: aether7b::RADIUS_LG as u8,
                se: 0,
            },
            aether7b::surface_chrome_fallback(dark),
        );
        ui.painter().vline(
            sidebar.right(),
            sidebar.top()..=sidebar.bottom(),
            egui::Stroke::new(1., aether7b::border(dark)),
        );

        // Everything the frame collects while rendering, resolved once the
        // entries' exclusive store borrow ends.
        let mut actions = Actions::default();
        let section = self.section.clone();
        let mut values = store.values();
        // The held changes while the document was unreadable show in their
        // controls and land in the file once the user replaces it.
        for (id, value) in &self.held {
            values.insert(id.clone(), value.clone());
        }
        let problem = store.load_problem().map(str::to_owned);
        let blocked = store.blocked();
        {
            let mut dirty = false;
            let mut side_effect = None;
            // The catalog is cloned, and the held changes taken out of
            // `self`, so the apply closure owns its own state and never
            // borrows `self` — the scroll body below needs the window's
            // other fields.
            let catalog = self.catalog.clone();
            let mut held = std::mem::take(&mut self.held);
            // Captured before the apply closure borrows `held`: a retained
            // failure from a previous frame offers Retry. This frame's own
            // saves only remove entries, so the flag cannot go stale.
            let show_retry = !blocked && !held.is_empty();
            let mut set = |id: &str, value: Value| -> Result<(), SetError> {
                if store.blocked() {
                    // The document cannot take the change, so the window
                    // holds it in memory — the banner's promise, kept
                    // until the user replaces the file — but only once
                    // the shared core has validated it (the only
                    // validator, review issue 2): a refused edit shows
                    // its reason and is held for nothing.
                    return match store.validate_held(&held, id, &value) {
                        Ok(()) => {
                            held.insert(id.to_owned(), value);
                            Ok(())
                        }
                        Err(error) => Err(error),
                    };
                }
                let result = store.set(id, value.clone());
                if result.is_ok() {
                    // A successful save clears any retained failure for this
                    // entry. Otherwise a width held from a failed repair
                    // keeps overlaying the value that just saved (review
                    // round 2, retained failures).
                    held.remove(id);
                    dirty = true;
                    if id == "themes.preset"
                        && value.as_str().is_some_and(|name| {
                            crate::shared::themes()
                                .into_iter()
                                .any(|theme| theme.name == name)
                        })
                    {
                        let name = value.as_str().expect("just checked").to_owned();
                        if let Err(error) = apply_preset(store, &name)
                            && let Some(preset) = catalog
                                .entries
                                .iter()
                                .find(|entry| entry.id == "themes.preset")
                        {
                            side_effect = Some(settings_controls::refusal_reason(&error, preset));
                        }
                    } else if id.starts_with("appearance.") && id.ends_with(".color") {
                        mark_custom_preset(store, &catalog);
                    }
                } else if matches!(result, Err(SetError::Transport)) {
                    // The core accepted the value and only the write
                    // failed: retain the latest failed value for Retry,
                    // replacing any older retained one — a retry must
                    // never save a value older than the newest edit
                    // (fix round 3, review rr2 finding 1).
                    held.insert(id.to_owned(), value);
                }
                result
            };
            let mut sidebar_ui = ui.new_child(
                egui::UiBuilder::new()
                    .id_salt("settings-sidebar")
                    .max_rect(sidebar.shrink2(egui::vec2(aether7b::SPACE_S2, aether7b::SPACE_S2)))
                    .layout(egui::Layout::top_down(egui::Align::LEFT)),
            );
            for (name, label) in SECTION_TITLES {
                let selected = name == section;
                let response = nav_button(&mut sidebar_ui, name, label, selected, dark);
                if response.clicked() {
                    self.section = name.to_owned();
                    self.fields = Fields::default();
                }
            }
            let content = egui::Rect::from_min_max(egui::pos2(sidebar.max.x, body.min.y), body.max);
            let mut content_ui = ui.new_child(
                egui::UiBuilder::new()
                    .id_salt("settings-content")
                    .max_rect(content),
            );
            // The full height of the section's cards, measured for the
            // snapshot walker's auto-sized capture viewport.
            let mut content_height = 0.;
            // The content pane scrolls in the production window. The
            // snapshot walker's auto-fitted viewport has nothing to
            // scroll, and a reserved scroll bar would make the measuring
            // pass and the capture disagree about the content's layout.
            let mut area = egui::ScrollArea::vertical()
                .id_salt(self.section.clone())
                .auto_shrink([false, false]);
            if snapshot_walk() {
                area = area.scroll_bar_visibility(
                    egui::containers::scroll_area::ScrollBarVisibility::AlwaysHidden,
                );
            }
            area.show(&mut content_ui, |ui| {
                ui.add_space(aether7b::SPACE_S12);
                // The pane's token gutter (fix L2): everything — eyebrow,
                // title, banner, message, cards — sits inside it, so the
                // cards align with the eyebrow's left edge and fill the
                // pane's width, exactly the macOS pane's side insets.
                egui::Frame::new().outer_margin(PANE_GUTTER).show(ui, |ui| {
                    ui.set_min_width(ui.available_width());
                    settings_style::eyebrow(ui, &self.section, dark);
                    ui.label(
                        egui::RichText::new(section_title(&section))
                            .font(settings_style::sans(aether7b::TYPE_XL.0))
                            .color(aether7b::text_main(dark))
                            .strong(),
                    );
                    ui.add_space(aether7b::SPACE_S2);
                    if let Some(problem) = &problem {
                        banner(ui, dark, problem, blocked, &mut actions);
                    }
                    if let Some(message) = &self.message {
                        ui.label(
                            egui::RichText::new(message)
                                .font(settings_style::sans(aether7b::TYPE_XS.0))
                                .color(aether7b::status_warning(dark)),
                        );
                        ui.add_space(aether7b::SPACE_S2);
                    }
                    // A persistence failure after the document was repaired
                    // leaves the edit held and shown. Retry is the defined
                    // path that saves it without the user retyping; reset
                    // (below) discards it. Neither is offered while the
                    // document is still blocked — Replace is that path.
                    if show_retry {
                        ui.label(
                            egui::RichText::new("Changes that could not be saved are still shown.")
                                .font(settings_style::sans(aether7b::TYPE_XS.0))
                                .color(aether7b::status_warning(dark)),
                        );
                        let retry = settings_style::ghost_button(
                            ui,
                            "retry-unpersisted",
                            "Retry saving changes that did not persist",
                            true,
                            dark,
                        );
                        if retry.clicked() {
                            actions.retry_held = true;
                        }
                        ui.add_space(aether7b::SPACE_S2);
                    }
                    let entries: Vec<_> = self
                        .catalog
                        .entries
                        .iter()
                        .filter(|entry| {
                            entry.section == section
                                && entry.platforms.iter().any(|platform| platform == "linux")
                                && entry.shown
                        })
                        .collect();
                    let mut groups: Vec<(&str, Vec<&crate::settings::document::CatalogEntry>)> =
                        Vec::new();
                    for entry in entries {
                        match groups.last_mut() {
                            Some((group, list)) if *group == entry.group => list.push(entry),
                            _ => groups.push((entry.group.as_str(), vec![entry])),
                        }
                    }
                    for (group, entries) in groups {
                        // Every control this card renders, for its rect.
                        let before = self.rendered.len();
                        let card = settings_style::card(dark)
                            .outer_margin(egui::Margin {
                                left: 0,
                                right: 0,
                                top: 0,
                                bottom: aether7b::SPACE_S3 as i8,
                            })
                            .show(ui, |ui| {
                                ui.set_min_width(ui.available_width());
                                settings_style::eyebrow(ui, group, dark);
                                ui.add_space(aether7b::SPACE_S2);
                                for entry in entries {
                                    let value = settings_controls::entry_value(&values, entry);
                                    let enabled = settings_controls::depends_holds(
                                        &values,
                                        &self.catalog.entries,
                                        entry,
                                    );
                                    let (rendered, outcome) = settings_controls::entry_row(
                                        ui,
                                        dark,
                                        entry,
                                        &value,
                                        enabled,
                                        &mut self.fields,
                                        sources,
                                        &mut set,
                                    );
                                    self.rendered.push(rendered);
                                    match outcome {
                                        Outcome::None => (),
                                        Outcome::Reset(section) => {
                                            actions.confirm_reset = Some(section);
                                        }
                                        Outcome::ImportTheme => actions.import_theme = true,
                                        Outcome::ExportTheme => actions.export_theme = true,
                                        Outcome::ChoosePath(id) => {
                                            actions.choose_path = Some(id);
                                        }
                                    }
                                }
                                if section == "themes" && group == "Import and export" {
                                    legacy_block(
                                        ui,
                                        dark,
                                        &mut self.legacy_path,
                                        self.import.as_ref(),
                                        &mut actions,
                                    );
                                }
                            });
                        // The card every entry of this group rendered in —
                        // the tests' containment and column checks (fix L1).
                        let rect = card.response.rect;
                        for rendered in &mut self.rendered[before..] {
                            rendered.card_rect = rect;
                        }
                    }
                    ui.add_space(aether7b::SPACE_S2);
                });
                // The full height of the section's cards, measured for the
                // snapshot walker's auto-sized capture viewport.
                content_height = ui.min_rect().height();
            });
            self.content_height = content_height;
            drop(set);
            if dirty {
                self.dirty = true;
            }
            if let Some(reason) = side_effect.take() {
                self.message = Some(reason);
            }
            self.held = held;
        }
        if let Some(section) = actions.confirm_reset.take() {
            self.confirm_reset = Some(section);
        }
        if actions.import_theme {
            self.picker = Some(Picker::new(Action::LoadTheme, PathBuf::new(), ui.ctx()));
        }
        if actions.export_theme {
            self.picker = Some(Picker::new(Action::SaveTheme, PathBuf::new(), ui.ctx()));
        }
        if let Some(id) = actions.choose_path.take() {
            let seed = values
                .get(&id)
                .and_then(Value::as_str)
                .map(PathBuf::from)
                .unwrap_or_default();
            self.path_target = Some(id);
            self.picker = Some(Picker::new(Action::ChoosePath, seed, ui.ctx()));
        }
        if let Some(path) = actions.review_pasted.take() {
            self.review_legacy(path, store, ui.ctx());
        }
        if actions.browse_legacy {
            self.picker = Some(Picker::new(
                Action::ImportLegacy,
                self.legacy_path.path(),
                ui.ctx(),
            ));
        }
        if actions.accept_import
            && let Err(error) = self.accept_import(store)
        {
            self.message = Some(error);
        }
        if actions.cancel_import {
            self.import = None;
        }
        if actions.retry_held {
            self.retry_unpersisted(store);
        }
        if actions.replace_requested {
            match store.replace_unreadable() {
                Ok(()) => {
                    self.dirty = true;
                    self.message = Some("The settings document was replaced.".into());
                    // The held changes — the banner's in-memory promise —
                    // land in the fresh document. One the core refuses now
                    // stays held with its reason on the row, reported
                    // instead of silently disappearing (review issue 2).
                    let held = std::mem::take(&mut self.held);
                    let mut failures: Vec<(String, Value, SetError)> = Vec::new();
                    for (id, value) in held {
                        match store.set(&id, value.clone()) {
                            Ok(()) => (),
                            Err(error) => failures.push((id, value, error)),
                        }
                    }
                    for entry in &self.catalog.entries {
                        if !failures.iter().any(|(id, _, _)| *id == entry.id) {
                            self.fields.bump(&entry.id);
                        }
                    }
                    for (id, value, error) in failures {
                        let reason = self
                            .catalog
                            .entries
                            .iter()
                            .find(|entry| entry.id == id)
                            .map(|entry| settings_controls::refusal_reason(&error, entry))
                            .unwrap_or_else(|| "The value could not be saved.".into());
                        self.fields.refuse(&id, reason.clone());
                        self.message = Some(reason);
                        // Retained: the refused edit stays held, so it
                        // still presents and survives a later repair.
                        self.held.insert(id, value);
                    }
                }
                Err(error) => self.message = Some(error),
            }
        }
        if let Some(section) = self.confirm_reset.clone() {
            let mut modal = Actions::default();
            let should_close = reset_modal(ui, dark, &section, &mut modal);
            if modal.reset_confirmed {
                self.confirm_reset = None;
                match store.reset_section(&section) {
                    Ok(()) => {
                        self.dirty = true;
                        for entry in self
                            .catalog
                            .entries
                            .iter()
                            .filter(|entry| entry.section == section)
                        {
                            // A successful reset discards retained failures
                            // for the section, so they cannot keep overlaying
                            // the restored defaults.
                            self.held.remove(&entry.id);
                            self.fields.bump(&entry.id);
                        }
                    }
                    Err(error) => self.message = Some(error),
                }
            }
            if modal.cancelled || should_close {
                self.confirm_reset = None;
            }
        }
        if let Some(mut picker) = self.picker.take() {
            match picker.show(ui) {
                Some(Decision::Chosen(choice)) => self.chosen(choice, store, ui.ctx()),
                Some(Decision::Cancelled) => {
                    self.message = None;
                    self.path_target = None;
                }
                None => self.picker = Some(picker),
            }
        }
        // The close button renders last so the focus walk starts with the
        // sidebar, then the section's controls (lesson d).
        let close = close_button(ui, dark, header);
        if close.clicked() {
            self.open = false;
        }
        // Forward Tab out of a colour editor asked for the next control
        // after its well (fix round 3). The section's rows are built now,
        // so the walk's next stop is known: the next enabled entry's
        // leading widget — its Inherit button on a colour row — or, past
        // the section's last one, the close button, where the walk ends
        // anyway.
        if let Some(exit_id) = self.fields.take_color_exit() {
            let next = self
                .rendered
                .iter()
                .skip_while(|rendered| rendered.id != exit_id)
                .skip(1)
                .find(|rendered| rendered.enabled)
                .map(|rendered| {
                    rendered
                        .alternate_focus
                        .clone()
                        .unwrap_or_else(|| rendered.response.clone())
                });
            if let Some(next) = next {
                next.request_focus();
            } else {
                close.request_focus();
            }
        }
        // Dragging the headerbar moves the window, like any headerbar.
        let grip =
            egui::Rect::from_min_max(header.min, egui::pos2(header.max.x - 40., header.max.y));
        let grip = ui.interact(
            grip,
            ui.scope_id().with("headerbar-grip"),
            // Dragging moves the window, like any headerbar — but the
            // grip is no keyboard stop; the focus walk belongs to the
            // sidebar, the controls and the close button (lesson d).
            egui::Sense::DRAG,
        );
        if grip.drag_started() {
            ui.ctx().send_viewport_cmd(egui::ViewportCommand::StartDrag);
        }
        super::smoke::paint_capture(ui);
    }

    fn chosen(&mut self, choice: Choice, store: &mut Store, ctx: &egui::Context) {
        match choice.action {
            Action::LoadTheme => self.load_theme(choice.path, ctx),
            Action::SaveTheme => self.save_theme(choice.path, choice.replace, store, ctx),
            Action::ImportLegacy => {
                self.legacy_path.set(choice.path.clone());
                self.review_legacy(choice.path, store, ctx);
            }
            Action::ChoosePath => {
                let Some(target) = self.path_target.take() else {
                    return;
                };
                if let Err(error) = store.set(&target, json!(choice.path.display().to_string())) {
                    let reason = self
                        .catalog
                        .entries
                        .iter()
                        .find(|entry| entry.id == target)
                        .map(|entry| settings_controls::refusal_reason(&error, entry))
                        .unwrap_or_else(|| "The value could not be saved.".into());
                    self.message = Some(reason);
                } else {
                    self.dirty = true;
                    self.fields.bump(&target);
                }
            }
        }
    }
}

/// Whether this run is the snapshot walker's (Tools/settings-snapshots-linux.sh).
fn snapshot_walk() -> bool {
    static SNAPSHOT: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *SNAPSHOT.get_or_init(|| std::env::var_os("XRG_SMOKE_SETTINGS_SNAPSHOT_DIR").is_some())
}

/// What the frame collected while rendering, resolved after the entries'
/// exclusive store borrow ends.
#[derive(Default)]
struct Actions {
    replace_requested: bool,
    retry_held: bool,
    confirm_reset: Option<String>,
    reset_confirmed: bool,
    cancelled: bool,
    import_theme: bool,
    export_theme: bool,
    choose_path: Option<String>,
    review_pasted: Option<PathBuf>,
    browse_legacy: bool,
    accept_import: bool,
    cancel_import: bool,
}

fn section_title(section: &str) -> &str {
    SECTION_TITLES
        .iter()
        .find(|(name, _)| *name == section)
        .map(|(_, title)| *title)
        .unwrap_or(section)
}

/// One sidebar section button: the selected one on the accent tint with
/// accent text, the rest muted — the mockup's `.nav`.
fn nav_button(
    ui: &mut egui::Ui,
    section: &str,
    label: &str,
    selected: bool,
    dark: bool,
) -> egui::Response {
    let _ = section;
    let width = ui.available_width() - aether7b::SPACE_S1;
    let font = settings_style::sans(aether7b::TYPE_SM.0);
    let text = if selected {
        aether7b::accent_active(dark)
    } else {
        aether7b::text_muted(dark)
    };
    let galley = ui.painter().layout_no_wrap(label.to_owned(), font, text);
    let (rect, response) = ui
        .push_id(section, |ui| {
            ui.allocate_exact_size(egui::vec2(width, 26.), egui::Sense::click())
        })
        .inner;
    let corner = egui::CornerRadius::same(aether7b::RADIUS_SM as u8);
    if selected || response.hovered() {
        ui.painter()
            .rect_filled(rect, corner, aether7b::accent_tint(dark));
    }
    if response.has_focus() {
        ui.painter().rect_stroke(
            rect,
            corner,
            settings_style::rim_stroke(dark, false, true),
            egui::StrokeKind::Middle,
        );
        settings_style::paint_focus_halo(ui.painter(), rect, aether7b::RADIUS_SM as u8);
    }
    ui.painter().add(egui::epaint::TextShape::new(
        egui::pos2(
            rect.min.x + aether7b::SPACE_S3,
            rect.center().y - galley.size().y / 2.,
        ),
        galley,
        text,
    ));
    response.widget_info(|| egui::WidgetInfo::labeled(egui::accesskit::Role::Button, true, label));
    response
}

/// The headerbar's close button: the ✕ drawn as two token-coloured
/// strokes, never a font glyph (fix L3 — the bundled fonts carry no ✕,
/// so the glyph rendered as tofu).
fn close_button(ui: &mut egui::Ui, dark: bool, header: egui::Rect) -> egui::Response {
    let rect = egui::Rect::from_min_size(
        egui::pos2(header.max.x - 12. - 18., header.center().y - 9.),
        egui::vec2(18., 18.),
    );
    let response = ui
        .push_id("close-settings", |ui| {
            ui.allocate_rect(rect, egui::Sense::click())
        })
        .inner;
    let rect = response.rect;
    let center = rect.center();
    let half = 5.;
    let stroke = egui::Stroke::new(1.5, aether7b::text_muted(dark));
    ui.painter().line_segment(
        [
            egui::pos2(center.x - half, center.y - half),
            egui::pos2(center.x + half, center.y + half),
        ],
        stroke,
    );
    ui.painter().line_segment(
        [
            egui::pos2(center.x - half, center.y + half),
            egui::pos2(center.x + half, center.y - half),
        ],
        stroke,
    );
    if response.has_focus() {
        settings_style::paint_focus_halo(ui.painter(), rect, aether7b::RADIUS_SM as u8);
    }
    response.widget_info(|| {
        egui::WidgetInfo::labeled(egui::accesskit::Role::Button, true, "Close settings")
    });
    response
}

/// The unreadable-file banner (spec §2): the file is never overwritten
/// until the user confirms replacing it, and only a blocking document
/// offers the replacement.
fn banner(ui: &mut egui::Ui, dark: bool, problem: &str, blocked: bool, actions: &mut Actions) {
    egui::Frame::new()
        .fill(aether7b::surface_card(dark))
        .stroke(egui::Stroke::new(1., aether7b::status_warning(dark)))
        .corner_radius(aether7b::RADIUS_LG)
        .outer_margin(egui::Margin {
            left: 0,
            right: 0,
            top: 0,
            bottom: aether7b::SPACE_S3 as i8,
        })
        .inner_margin(egui::Margin::same(aether7b::SPACE_S3 as i8))
        .show(ui, |ui| {
            ui.set_min_width(ui.available_width());
            ui.label(
                egui::RichText::new(format!("The settings document needs attention: {problem}."))
                    .font(settings_style::sans(aether7b::TYPE_SM.0))
                    .color(aether7b::text_main(dark)),
            );
            if blocked {
                ui.label(
                    egui::RichText::new(
                        "Changes are kept in memory and the file is left untouched.",
                    )
                    .font(settings_style::sans(aether7b::TYPE_XS.0))
                    .color(aether7b::text_muted(dark)),
                );
                let replace = settings_style::ghost_button(
                    ui,
                    "replace-unreadable-file",
                    "Replace the file with the current settings",
                    true,
                    dark,
                );
                if replace.clicked() {
                    actions.replace_requested = true;
                }
            }
        });
}

/// The reset confirmation (spec §5): each section's Reset asks first.
fn reset_modal(ui: &mut egui::Ui, dark: bool, section: &str, actions: &mut Actions) -> bool {
    let modal = egui::Modal::new(egui::Id::unique("reset-confirmation")).show(ui.ctx(), |ui| {
        egui::Frame::new()
            .fill(aether7b::surface_card(dark))
            .stroke(egui::Stroke::new(1., aether7b::border(dark)))
            .corner_radius(aether7b::RADIUS_LG)
            .inner_margin(egui::Margin::same(aether7b::SPACE_S4 as i8))
            .show(ui, |ui| {
                ui.set_width(340.);
                ui.label(
                    egui::RichText::new(format!("Reset {} to defaults?", section_title(section)))
                        .font(settings_style::sans(aether7b::TYPE_MD.0))
                        .color(aether7b::text_main(dark))
                        .strong(),
                );
                ui.label(
                    egui::RichText::new(format!(
                        "Every {} setting returns to its default. This cannot be undone.",
                        section_title(section)
                    ))
                    .font(settings_style::sans(aether7b::TYPE_SM.0))
                    .color(aether7b::text_muted(dark)),
                );
                ui.add_space(aether7b::SPACE_S2);
                ui.horizontal(|ui| {
                    let reset = settings_style::ghost_button(ui, "reset", "Reset", true, dark);
                    if reset.clicked() {
                        actions.reset_confirmed = true;
                    }
                    let cancel =
                        settings_style::ghost_button(ui, "cancel-reset", "Cancel", true, dark);
                    if cancel.clicked() {
                        actions.cancelled = true;
                    }
                });
            });
    });
    modal.should_close()
}

/// The Linux-specific legacy import block, inside the Themes section's
/// "Import and export" card: the review holds the import in memory until
/// the user accepts it; accepting saves the imported view whole (the same
/// document the old draft-then-Apply flow produced).
fn legacy_block(
    ui: &mut egui::Ui,
    dark: bool,
    path: &mut PathField,
    import: Option<&legacy::Import>,
    actions: &mut Actions,
) {
    ui.add_space(aether7b::SPACE_S2);
    ui.painter().hline(
        ui.available_rect_before_wrap().x_range(),
        ui.cursor().min.y,
        egui::Stroke::new(1., aether7b::border(dark)),
    );
    ui.add_space(aether7b::SPACE_S2);
    ui.label(
        egui::RichText::new("Legacy Linux settings")
            .font(settings_style::sans(aether7b::TYPE_SM.0))
            .color(aether7b::text_main(dark)),
    );
    ui.label(
        egui::RichText::new(
            "Import the original C application's GLib key-file settings. The source file is never changed.",
        )
        .font(settings_style::sans(aether7b::TYPE_XS.0))
        .color(aether7b::text_muted(dark)),
    );
    let field = path.edit(ui);
    field.widget_info(|| {
        egui::WidgetInfo::labeled(
            egui::accesskit::Role::TextInput,
            true,
            "Legacy Linux settings path",
        )
    });
    ui.horizontal(|ui| {
        let browse = settings_style::ghost_button(
            ui,
            "browse-legacy",
            "Browse legacy settings…",
            true,
            dark,
        );
        if browse.clicked() {
            actions.browse_legacy = true;
        }
        let review =
            settings_style::ghost_button(ui, "review-legacy", "Review pasted path…", true, dark);
        if review.clicked() {
            actions.review_pasted = Some(path.path());
        }
    });
    if let Some(import) = import {
        ui.label(
            egui::RichText::new(format!(
                "{} entries ready to import; {} entries not transferred.",
                import.imported.len(),
                import.skipped.len()
            ))
            .font(settings_style::mono(aether7b::TYPE_XS.0))
            .color(aether7b::text_main(dark)),
        );
        egui::ScrollArea::vertical()
            .id_salt("legacy-summary")
            .max_height(120.)
            .show(ui, |ui| {
                for line in import.imported.iter().chain(&import.skipped) {
                    ui.label(
                        egui::RichText::new(line)
                            .font(settings_style::mono(aether7b::TYPE_XS.0))
                            .color(aether7b::text_muted(dark)),
                    );
                }
            });
        ui.horizontal(|ui| {
            let accept = settings_style::ghost_button(
                ui,
                "accept-import",
                "Import into settings",
                true,
                dark,
            );
            if accept.clicked() {
                actions.accept_import = true;
            }
            let cancel =
                settings_style::ghost_button(ui, "cancel-import", "Cancel import", true, dark);
            if cancel.clicked() {
                actions.cancel_import = true;
            }
        });
    }
}

/// Selecting a built-in preset applies its palette, its name and the
/// preset selection itself through the shared settings model (lesson f).
fn apply_preset(store: &mut Store, name: &str) -> Result<(), SetError> {
    let Some(theme) = crate::shared::themes()
        .into_iter()
        .find(|theme| theme.name == name)
    else {
        return Err(SetError::NotAnOption);
    };
    for (index, id) in settings_controls::PALETTE_IDS.iter().enumerate() {
        store.set(id, json!(theme.colors[index]))?;
    }
    store.set("themes.name", json!(name))?;
    store.set("themes.preset", json!(name))?;
    Ok(())
}

/// The catalog's documented rule: a palette that no longer matches the
/// selected built-in preset marks the theme Custom. An unset colour
/// inherits its catalog default, so the comparison reads the effective
/// colour either way. Returns whether the theme was marked.
fn mark_custom_preset(store: &mut Store, catalog: &Catalog) -> bool {
    let values = store.values();
    let preset = values
        .get("themes.preset")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .or_else(|| {
            catalog
                .entries
                .iter()
                .find(|entry| entry.id == "themes.preset")
                .and_then(|entry| entry.default.as_str())
                .map(str::to_owned)
        });
    let Some(preset) = preset else {
        return false;
    };
    let Some(theme) = crate::shared::themes()
        .into_iter()
        .find(|theme| theme.name == preset)
    else {
        return false;
    };
    let differs = settings_controls::PALETTE_IDS
        .iter()
        .enumerate()
        .any(|(index, id)| {
            let effective = values
                .get(*id)
                .cloned()
                .or_else(|| {
                    catalog
                        .entries
                        .iter()
                        .find(|entry| &entry.id == id)
                        .map(|entry| entry.default.clone())
                })
                .and_then(|value| {
                    value.as_array().map(|rgba| {
                        rgba.iter()
                            .filter_map(|part| part.as_f64())
                            .collect::<Vec<f64>>()
                    })
                });
            effective != Some(theme.colors[index].to_vec())
        });
    if differs {
        return store.set("themes.preset", json!("Custom")).is_ok();
    }
    false
}

/// The App-facing host: renders the window's viewport for one frame, keeps
/// it while it is open, and adopts the stored view whenever the window
/// changed it, so the live dashboard follows instantly (lesson h).
pub(super) fn show(app: &mut App, ctx: &egui::Context) {
    let Some(mut window) = app.settings_window.take() else {
        return;
    };
    let inventory = app
        .snapshot
        .as_ref()
        .map(|snapshot| snapshot.inventory.clone())
        .unwrap_or_default();
    let provider = InventoryProvider(&inventory);
    window.show(ctx, &mut app.store, &provider);
    let changed = window.take_dirty();
    let closed = window.closed();
    if !closed {
        app.settings_window = Some(window);
    }
    if changed {
        let settings = app.store.settings().clone();
        if let Err(error) = app.adopt(settings, ctx) {
            app.error = Some(error);
        }
    }
}

/// The production source provider: the live inventory the workers
/// published — the same enumeration the old preferences used.
pub(super) struct InventoryProvider<'a>(&'a Inventory);
impl SourceProvider for InventoryProvider<'_> {
    fn options(&self, kind: &str) -> Vec<SourceOption> {
        match kind {
            "cpu" => self
                .0
                .cpus
                .iter()
                .map(|core| SourceOption {
                    id: core.to_string(),
                    label: format!("Logical CPU {}", core + 1),
                })
                .collect(),
            "network" => self
                .0
                .networks
                .iter()
                .map(|name| SourceOption {
                    id: name.clone(),
                    label: name.clone(),
                })
                .collect(),
            "disk" => self
                .0
                .disks
                .iter()
                .map(|name| SourceOption {
                    id: name.clone(),
                    label: name.clone(),
                })
                .collect(),
            "gpu" | "gpu_memory" => self.0.gpus.clone(),
            "temperature" => self.0.temperatures.clone(),
            "fans" => self.0.fans.clone(),
            _ => Vec::new(),
        }
    }
}
