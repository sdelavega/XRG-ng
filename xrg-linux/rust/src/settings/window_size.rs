// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use serde::{
    Deserialize, Deserializer, Serialize,
    de::{self, MapAccess, Visitor},
};
use std::fmt;

/// GTK logical pixels, independent of graph dimensions and desktop placement.
#[derive(Clone, Copy, Debug, Serialize, PartialEq, Eq)]
pub struct WindowSize {
    pub width: u32,
    pub height: u32,
}
impl WindowSize {
    pub fn validate(self) -> Result<(), String> {
        if !(100..=8192).contains(&self.width) || !(100..=8192).contains(&self.height) {
            return Err(
                "Dashboard window width and height must be between 100 and 8192 logical pixels"
                    .into(),
            );
        }
        Ok(())
    }
}
impl<'de> Deserialize<'de> for WindowSize {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct SizeVisitor;
        impl<'de> Visitor<'de> for SizeVisitor {
            type Value = WindowSize;
            fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
                formatter.write_str("an object with integer width and height")
            }
            fn visit_map<M: MapAccess<'de>>(self, mut map: M) -> Result<Self::Value, M::Error> {
                let mut width = None;
                let mut height = None;
                while let Some(key) = map.next_key::<String>()? {
                    match key.as_str() {
                        "width" => {
                            if width.is_some() {
                                return Err(de::Error::duplicate_field("width"));
                            }
                            width = Some(map.next_value()?);
                        }
                        "height" => {
                            if height.is_some() {
                                return Err(de::Error::duplicate_field("height"));
                            }
                            height = Some(map.next_value()?);
                        }
                        _ => return Err(de::Error::unknown_field(&key, &["width", "height"])),
                    }
                }
                Ok(WindowSize {
                    width: width.ok_or_else(|| de::Error::missing_field("width"))?,
                    height: height.ok_or_else(|| de::Error::missing_field("height"))?,
                })
            }
        }
        // The derived struct decoder also accepts a JSON tuple; settings use a
        // named object so malformed arrays must not silently become dimensions.
        deserializer.deserialize_map(SizeVisitor)
    }
}
