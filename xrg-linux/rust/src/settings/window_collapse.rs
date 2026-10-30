// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use serde::{Deserialize, Serialize};
#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CollapseAnchor {
    #[default]
    Start,
    End,
}
#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default, deny_unknown_fields)]
pub struct WindowCollapse {
    /// Manual latch only. A temporary hover expansion must never change it.
    pub collapsed: bool,
    pub expand_on_hover: bool,
    pub anchor: CollapseAnchor,
}
