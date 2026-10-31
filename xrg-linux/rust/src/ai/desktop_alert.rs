// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Freedesktop notification protocol directly in Rust. No toolkit or libnotify.
/// The Linux implementation of the desktop alert.
pub const IMPLEMENTATION: &str = "linux";
use std::{collections::HashMap, time::Duration};
pub(super) fn send(percent: f64) -> Result<(), String> {
    send_on(percent, None)
}
fn send_on(percent: f64, address: Option<&str>) -> Result<(), String> {
    if !percent.is_finite() || percent <= 0. {
        return Err("Invalid budget percentage".into());
    }
    async_io::block_on(futures_lite::future::race(
        async {
            let builder = match address {
                Some(address) => zbus::connection::Builder::address(address),
                None => zbus::connection::Builder::session(),
            }
            .map_err(|e| e.to_string())?;
            let connection = builder.build().await.map_err(|e| e.to_string())?;
            let body =
                format!("Observed usage has reached {percent:.0}% of your daily token budget.");
            let mut hints: HashMap<&str, zbus::zvariant::Value<'_>> = HashMap::new();
            hints.insert(
                "desktop-entry",
                zbus::zvariant::Value::from("com.sdelavega.xrg-ng"),
            );
            let reply = connection
                .call_method(
                    Some("org.freedesktop.Notifications"),
                    "/org/freedesktop/Notifications",
                    Some("org.freedesktop.Notifications"),
                    "Notify",
                    &(
                        "XRG-ng",
                        0u32,
                        "com.sdelavega.xrg-ng",
                        "AI token budget",
                        body,
                        Vec::<&str>::new(),
                        hints,
                        -1i32,
                    ),
                )
                .await
                .map_err(|e| e.to_string())?;
            reply
                .body()
                .deserialize::<u32>()
                .map_err(|e| e.to_string())?;
            Ok(())
        },
        async {
            async_io::Timer::after(Duration::from_secs(1)).await;
            Err("Notification service timed out after one second".into())
        },
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        io::Read,
        os::fd::AsRawFd,
        process::{Command, Stdio},
        sync::{Arc, Mutex},
        time::Instant,
    };
    struct Bus {
        child: std::process::Child,
        address: String,
    }
    impl Bus {
        fn start() -> Self {
            let mut child = Command::new("dbus-daemon")
                .args(["--session", "--nofork", "--print-address=1"])
                .stdout(Stdio::piped())
                .stderr(Stdio::null())
                .spawn()
                .expect("dbus-daemon required for notification protocol tests");
            let mut stdout = child.stdout.take().unwrap();
            let fd = stdout.as_raw_fd();
            unsafe {
                let flags = libc::fcntl(fd, libc::F_GETFL);
                assert!(flags >= 0);
                assert_eq!(libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK), 0);
            }
            let end = Instant::now() + Duration::from_secs(2);
            let mut bytes = Vec::new();
            loop {
                let mut buffer = [0; 1024];
                match stdout.read(&mut buffer) {
                    Ok(n) if n > 0 => bytes.extend_from_slice(&buffer[..n]),
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => (),
                    _ => {
                        let _ = child.kill();
                        let _ = child.wait();
                        panic!("Private notification bus failed to start");
                    }
                }
                if bytes.contains(&b'\n') {
                    break;
                }
                if Instant::now() >= end {
                    let _ = child.kill();
                    let _ = child.wait();
                    panic!("Private notification bus start timed out");
                }
                std::thread::sleep(Duration::from_millis(5));
            }
            Self {
                child,
                address: String::from_utf8(bytes).unwrap().trim().into(),
            }
        }
    }
    impl Drop for Bus {
        fn drop(&mut self) {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }
    struct Service {
        bodies: Arc<Mutex<Vec<String>>>,
        mode: u8,
    }
    #[zbus::interface(name = "org.freedesktop.Notifications")]
    impl Service {
        #[allow(clippy::too_many_arguments)]
        async fn notify(
            &self,
            app_name: &str,
            replaces_id: u32,
            app_icon: &str,
            summary: &str,
            body: &str,
            actions: Vec<String>,
            hints: HashMap<String, zbus::zvariant::OwnedValue>,
            expire_timeout: i32,
        ) -> zbus::fdo::Result<u32> {
            assert_eq!(app_name, "XRG-ng");
            assert_eq!(replaces_id, 0);
            assert_eq!(app_icon, "com.sdelavega.xrg-ng");
            assert_eq!(summary, "AI token budget");
            assert!(actions.is_empty());
            assert!(hints.contains_key("desktop-entry"));
            assert_eq!(expire_timeout, -1);
            self.bodies.lock().unwrap().push(body.into());
            if self.mode == 1 {
                return Err(zbus::fdo::Error::AccessDenied("fixture denied".into()));
            }
            if self.mode == 2 {
                async_io::Timer::after(Duration::from_secs(2)).await;
            }
            Ok(42)
        }
    }
    #[test]
    fn native_protocol_success_denial_missing_service_and_deadline() {
        assert!(send_on(f64::NAN, None).is_err());
        let bus = Bus::start();
        assert!(send_on(80., Some(&bus.address)).is_err());
        for mode in 0..3 {
            let bodies = Arc::new(Mutex::new(Vec::new()));
            let server = async_io::block_on(
                zbus::connection::Builder::address(bus.address.as_str())
                    .unwrap()
                    .name("org.freedesktop.Notifications")
                    .unwrap()
                    .serve_at(
                        "/org/freedesktop/Notifications",
                        Service {
                            bodies: bodies.clone(),
                            mode,
                        },
                    )
                    .unwrap()
                    .build(),
            )
            .unwrap();
            let started = Instant::now();
            let result = send_on(80., Some(&bus.address));
            assert_eq!(result.is_ok(), mode == 0);
            assert!(started.elapsed() < Duration::from_millis(1800));
            assert_eq!(
                bodies.lock().unwrap().as_slice(),
                ["Observed usage has reached 80% of your daily token budget."]
            );
            // Release the name before the next service registers it.
            async_io::block_on(server.release_name("org.freedesktop.Notifications")).unwrap();
            drop(server);
        }
    }
}
