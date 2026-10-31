// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Transient hover/geometry state is separate from the persisted manual latch.
use crate::settings::{CollapseAnchor, Layout, WindowCollapse};
use eframe::egui::{Pos2, Vec2, vec2};
pub(super) const STRIP: f32 = 28.;
const ENTER: f64 = 0.2;
const LEAVE: f64 = 0.25;
#[derive(Clone, Copy)]
pub(super) struct Input {
    pub native: Vec2,
    pub outer: Option<Pos2>,
    pub zoom: f32,
    pub time: f64,
    pub inside: bool,
    pub blocked: bool,
    pub maximized: bool,
}
#[derive(Clone, Copy, Debug)]
pub(super) struct Geometry {
    pub size: Option<Vec2>,
    pub minimum: Vec2,
    pub position: Option<Pos2>,
    pub resizable: bool,
}
#[derive(Clone, Copy)]
struct Pending {
    target: Vec2,
    previous: Vec2,
    at: f64,
}
#[derive(Default)]
pub(super) struct State {
    config: Option<WindowCollapse>,
    layout: Option<Layout>,
    zoom: f32,
    maximized: bool,
    closed: bool,
    hover_open: bool,
    armed: bool,
    entered: Option<f64>,
    left: Option<f64>,
    restore: Option<Vec2>,
    pending: Option<Pending>,
}
fn valid(size: Vec2) -> bool {
    size.is_finite() && (100.0..=8192.0).contains(&size.x) && (100.0..=8192.0).contains(&size.y)
}
fn near(a: Vec2, b: Vec2) -> bool {
    (a - b).abs().max_elem() < 1.5
}
impl State {
    pub fn closed(&self) -> bool {
        self.closed
    }
    pub fn can_capture(&self) -> bool {
        self.config.is_none_or(|c| !c.collapsed) && self.pending.is_none()
    }
    pub fn repaint_after(&self, time: f64) -> Option<std::time::Duration> {
        self.entered
            .map(|t| t + ENTER)
            .or_else(|| self.left.map(|t| t + LEAVE))
            .map(|t| std::time::Duration::from_secs_f64((t - time).clamp(0.001, 1.)))
    }
    pub fn update(
        &mut self,
        config: WindowCollapse,
        layout: Layout,
        input: Input,
        fallback: Vec2,
        force_resize: bool,
    ) -> Option<Geometry> {
        let zoom = if input.zoom.is_finite() && input.zoom > 0. {
            input.zoom
        } else {
            1.
        };
        if let Some(pending) = self.pending
            && (near(input.native, pending.target)
                || (!self.closed && valid(input.native) && !near(input.native, pending.previous)))
        {
            self.pending = None;
        }
        if force_resize {
            self.restore = Some(fallback)
        } else if !input.maximized && !self.closed && self.can_capture() && valid(input.native) {
            self.restore = Some(input.native)
        }
        let restore = self
            .restore
            .filter(|s| valid(*s))
            .unwrap_or(fallback)
            .clamp(Vec2::splat(100.), Vec2::splat(8192.));
        self.restore = Some(restore);
        let changed = self.config.is_some_and(|c| c.collapsed != config.collapsed);
        if changed {
            self.hover_open = false;
            self.armed = false;
            self.entered = None;
            self.left = None;
        }
        if !config.collapsed || !config.expand_on_hover || input.maximized {
            self.hover_open = false;
            self.entered = None;
            self.left = None;
        } else {
            if !input.inside {
                self.armed = true;
            }
            let settling = self.pending.is_some_and(|p| input.time - p.at < 0.75);
            if input.blocked || settling {
                self.entered = None;
                self.left = None;
            } else if self.hover_open {
                self.entered = None;
                if input.inside {
                    self.left = None
                } else if input.time - *self.left.get_or_insert(input.time) >= LEAVE {
                    self.hover_open = false;
                    self.left = None;
                }
            } else {
                self.left = None;
                if !input.inside || !self.armed {
                    self.entered = None
                } else if input.time - *self.entered.get_or_insert(input.time) >= ENTER {
                    self.hover_open = true;
                    self.entered = None;
                }
            }
        }
        let closed = config.collapsed && !self.hover_open && !input.maximized;
        let dirty = changed
            || input.maximized != self.maximized
            || closed != self.closed
            || force_resize
            || self.layout.is_some_and(|old| old != layout)
            || (config.collapsed
                && (self.zoom != zoom || self.config.is_some_and(|old| old != config)));
        let anchor_change = closed != self.closed || closed;
        self.config = Some(config);
        self.layout = Some(layout);
        self.zoom = zoom;
        self.closed = closed;
        self.maximized = input.maximized;
        if !dirty {
            return None;
        }
        if input.maximized {
            self.pending = None;
            return Some(Geometry {
                size: None,
                minimum: Vec2::splat(100. / zoom),
                position: None,
                resizable: true,
            });
        }
        let size = if closed {
            match layout {
                Layout::Vertical => vec2(restore.x / zoom, STRIP),
                Layout::Horizontal => vec2(STRIP, restore.y / zoom),
            }
        } else {
            restore / zoom
        };
        let minimum = if closed {
            match layout {
                Layout::Vertical => vec2(100. / zoom, STRIP),
                Layout::Horizontal => vec2(STRIP, 100. / zoom),
            }
        } else {
            Vec2::splat(100. / zoom)
        };
        let position = if anchor_change {
            input.outer.map(|mut p| {
                if config.anchor == CollapseAnchor::End {
                    match layout {
                        Layout::Vertical => p.y += input.native.y / zoom - size.y,
                        Layout::Horizontal => p.x += input.native.x / zoom - size.x,
                    }
                }
                p
            })
        } else {
            None
        };
        self.pending = Some(Pending {
            target: size * zoom,
            previous: input.native,
            at: input.time,
        });
        Some(Geometry {
            size: Some(size),
            minimum,
            position,
            resizable: !config.collapsed,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use eframe::egui::pos2;
    const SIZE: Vec2 = vec2(220., 600.);
    fn input(time: f64, native: Vec2, inside: bool) -> Input {
        Input {
            native,
            outer: Some(pos2(40., 60.)),
            zoom: 1.,
            time,
            inside,
            blocked: false,
            maximized: false,
        }
    }
    fn config() -> WindowCollapse {
        WindowCollapse {
            collapsed: true,
            expand_on_hover: true,
            ..Default::default()
        }
    }
    fn tick(
        state: &mut State,
        config: WindowCollapse,
        time: f64,
        native: Vec2,
        inside: bool,
    ) -> Option<Geometry> {
        state.update(
            config,
            Layout::Vertical,
            input(time, native, inside),
            SIZE,
            false,
        )
    }
    #[test]
    fn idle_expanded_window_does_not_resize_or_schedule_repaints() {
        let mut s = State::default();
        for t in 0..10 {
            assert!(tick(&mut s, WindowCollapse::default(), t as f64, SIZE, false).is_none());
            assert!(s.can_capture());
            assert!(s.repaint_after(t as f64).is_none());
        }
    }
    #[test]
    fn both_layouts_restore_native_dimensions_and_anchor_at_every_zoom() {
        for layout in [Layout::Vertical, Layout::Horizontal] {
            for zoom in [1., 1.25, 1.5, 2.] {
                for anchor in [CollapseAnchor::Start, CollapseAnchor::End] {
                    let mut s = State::default();
                    let mut c = WindowCollapse { anchor, ..config() };
                    let mut i = input(0., SIZE, false);
                    i.zoom = zoom;
                    s.update(WindowCollapse::default(), layout, i, SIZE, false);
                    let g = s.update(c, layout, i, SIZE, false).unwrap();
                    let thin = match layout {
                        Layout::Vertical => vec2(SIZE.x / zoom, STRIP),
                        Layout::Horizontal => vec2(STRIP, SIZE.y / zoom),
                    };
                    assert_eq!(g.size, Some(thin));
                    let mut expected = i.outer.unwrap();
                    if anchor == CollapseAnchor::End {
                        match layout {
                            Layout::Vertical => expected.y += SIZE.y / zoom - STRIP,
                            Layout::Horizontal => expected.x += SIZE.x / zoom - STRIP,
                        }
                    }
                    assert_eq!(g.position, Some(expected));
                    assert!(!g.resizable);
                    assert!(!s.can_capture());
                    i.native = thin * zoom;
                    i.outer = g.position;
                    i.time = 1.;
                    assert!(s.update(c, layout, i, SIZE, false).is_none());
                    c.collapsed = false;
                    let g = s.update(c, layout, i, SIZE, false).unwrap();
                    assert_eq!(g.size, Some(SIZE / zoom));
                    assert_eq!(g.position, Some(pos2(40., 60.)));
                    assert!(g.resizable);
                    assert!(!s.can_capture());
                    i.native = SIZE;
                    assert!(s.update(c, layout, i, SIZE, false).is_none());
                    assert!(s.can_capture());
                }
            }
        }
    }
    #[test]
    fn hover_requires_exit_then_entry_and_respects_delays_and_blockers() {
        let mut s = State::default();
        let c = config();
        let thin = vec2(220., STRIP);
        tick(&mut s, WindowCollapse::default(), 0., SIZE, true);
        tick(&mut s, c, 0., SIZE, true).unwrap();
        assert!(tick(&mut s, c, 1., thin, true).is_none());
        assert!(s.closed());
        tick(&mut s, c, 1.1, thin, false);
        tick(&mut s, c, 1.2, thin, true);
        assert!(s.repaint_after(1.2).is_some());
        assert!(tick(&mut s, c, 1.39, thin, true).is_none());
        assert_eq!(tick(&mut s, c, 1.41, thin, true).unwrap().size, Some(SIZE));
        assert!(!s.closed());
        assert!(!s.can_capture());
        tick(&mut s, c, 2., SIZE, false);
        let mut i = input(3., SIZE, false);
        i.blocked = true;
        assert!(s.update(c, Layout::Vertical, i, SIZE, false).is_none());
        assert!(!s.closed());
        assert!(s.repaint_after(3.).is_none());
        tick(&mut s, c, 4., SIZE, false);
        assert!(tick(&mut s, c, 4.24, SIZE, false).is_none());
        assert_eq!(tick(&mut s, c, 4.26, SIZE, false).unwrap().size, Some(thin));
    }
    #[test]
    fn explicit_expansion_pins_hover_window_and_disabled_hover_stays_closed() {
        let mut s = State::default();
        let mut c = config();
        let thin = vec2(220., STRIP);
        tick(&mut s, c, 0., SIZE, false);
        tick(&mut s, c, 1., thin, true);
        tick(&mut s, c, 1.21, thin, true).unwrap();
        c.collapsed = false;
        assert!(tick(&mut s, c, 2., SIZE, true).unwrap().resizable);
        assert!(tick(&mut s, c, 3., SIZE, false).is_none());
        assert!(!s.closed());
        c.collapsed = true;
        c.expand_on_hover = false;
        tick(&mut s, c, 4., SIZE, false).unwrap();
        assert!(tick(&mut s, c, 5., thin, true).is_none());
        assert!(s.closed());
    }
    #[test]
    fn pending_sizes_and_transient_hover_cannot_replace_expanded_restore() {
        let mut s = State::default();
        let c = config();
        let thin = vec2(220., STRIP);
        tick(&mut s, c, 0., SIZE, false);
        // A compositor can defer or reject a requested size; never save the strip.
        tick(&mut s, c, 1., thin, false);
        assert_eq!(s.restore, Some(SIZE));
        tick(&mut s, c, 2., thin, true);
        tick(&mut s, c, 2.21, thin, true).unwrap();
        assert!(!s.can_capture());
        assert_eq!(s.restore, Some(SIZE));
        tick(&mut s, c, 3., vec2(400., 400.), true);
        assert_eq!(s.restore, Some(SIZE));
        let open = WindowCollapse::default();
        tick(&mut s, open, 4., vec2(400., 400.), true).unwrap();
        tick(&mut s, open, 5., SIZE, true);
        assert!(s.can_capture());
        tick(&mut s, open, 6., vec2(340., 700.), true);
        assert_eq!(s.restore, Some(vec2(340., 700.)));
    }
    #[test]
    fn wayland_never_invents_global_coordinates_and_layout_changes_keep_restore() {
        let mut s = State::default();
        let c = config();
        let mut i = input(0., SIZE, false);
        i.outer = None;
        assert_eq!(
            s.update(c, Layout::Vertical, i, SIZE, false)
                .unwrap()
                .position,
            None
        );
        i.native = vec2(220., STRIP);
        i.time = 1.;
        let g = s.update(c, Layout::Horizontal, i, SIZE, false).unwrap();
        assert_eq!(g.size, Some(vec2(STRIP, 600.)));
        assert_eq!(g.position, None);
        i.native = vec2(STRIP, 600.);
        i.zoom = 1.25;
        let g = s.update(c, Layout::Horizontal, i, SIZE, false).unwrap();
        assert_eq!(g.size, Some(vec2(STRIP, 480.)));
        assert_eq!(s.restore, Some(SIZE));
    }
    #[test]
    fn maximized_windows_keep_restore_and_reenable_native_resize() {
        let mut s = State::default();
        let c = config();
        tick(&mut s, c, 0., SIZE, false);
        let mut i = input(1., vec2(1600., 1200.), false);
        i.maximized = true;
        let g = s.update(c, Layout::Vertical, i, SIZE, false).unwrap();
        assert_eq!(g.size, None);
        assert!(g.resizable);
        assert!(!s.closed());
        assert_eq!(s.restore, Some(SIZE));
        assert!(s.update(c, Layout::Vertical, i, SIZE, false).is_none());
        i.maximized = false;
        i.native = SIZE;
        assert_eq!(
            s.update(c, Layout::Vertical, i, SIZE, false).unwrap().size,
            Some(vec2(220., STRIP))
        );
    }
    #[test]
    fn explicit_geometry_settings_update_restore_while_collapsed() {
        let mut s = State::default();
        let c = config();
        tick(&mut s, c, 0., SIZE, false);
        let replacement = vec2(320., 720.);
        let g = s
            .update(
                c,
                Layout::Vertical,
                input(1., vec2(220., STRIP), false),
                replacement,
                true,
            )
            .unwrap();
        assert_eq!(g.size, Some(vec2(320., STRIP)));
        assert_eq!(s.restore, Some(replacement));
        assert_eq!(
            tick(
                &mut s,
                WindowCollapse::default(),
                2.,
                vec2(320., STRIP),
                false
            )
            .unwrap()
            .size,
            Some(replacement)
        );
    }
}
