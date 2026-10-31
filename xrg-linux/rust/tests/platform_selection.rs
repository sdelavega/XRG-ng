// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Review Focus 4: after the Windows compile seams, every Linux collector is
//! still the real implementation. A cfg mistake must not silently swap in a
//! stub on Linux, and a stub must never report itself as "linux".
#![cfg(target_os = "linux")]

use xrg_ng_linux::platform::{PLATFORM, Platform};

#[test]
fn linux_platform_selected() {
    assert_eq!(PLATFORM, Platform::Linux);
}

#[test]
fn linux_collectors_are_real_not_stubs() {
    let gated: &[(&str, &str)] = &[
        ("system_file", xrg_ng_linux::system_file::IMPLEMENTATION),
        ("drm_clients", xrg_ng_linux::drm_clients::IMPLEMENTATION),
        ("gpu", xrg_ng_linux::gpu::IMPLEMENTATION),
        ("hardware", xrg_ng_linux::hardware::IMPLEMENTATION),
        (
            "process::control",
            xrg_ng_linux::process::control::IMPLEMENTATION,
        ),
        (
            "ai::desktop_alert",
            xrg_ng_linux::ai::desktop_alert::IMPLEMENTATION,
        ),
        ("notification", xrg_ng_linux::notification::IMPLEMENTATION),
    ];
    for &(module, implementation) in gated {
        assert_eq!(
            implementation, "linux",
            "{module} must be the real Linux implementation, not a stub"
        );
    }
    // The fade compositor is a listed Linux-only module; it only exists when
    // the desktop UI feature that hosts it is enabled.
    #[cfg(feature = "egui-ui")]
    assert_eq!(
        xrg_ng_linux::ui::compositor::IMPLEMENTATION,
        "linux",
        "ui::compositor must be the real Linux implementation, not a stub"
    );
}
