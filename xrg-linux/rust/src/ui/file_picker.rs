// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! An egui-only chooser. One worker coalesces navigation and never reads file contents.
use eframe::egui;
use std::{
    ffi::OsString,
    fs,
    path::{Component, Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc,
    },
    time::{Duration, Instant},
};
const ENTRY_LIMIT: usize = 4096;
const SCAN_BUDGET: Duration = Duration::from_millis(100);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Action {
    LoadTheme,
    SaveTheme,
    ImportLegacy,
}
impl Action {
    fn title(self) -> &'static str {
        match self {
            Self::LoadTheme => "Load theme",
            Self::SaveTheme => "Save JSON theme",
            Self::ImportLegacy => "Import legacy Linux settings",
        }
    }
    fn button(self) -> &'static str {
        match self {
            Self::LoadTheme => "Load into draft",
            Self::SaveTheme => "Save theme",
            Self::ImportLegacy => "Review import",
        }
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Choice {
    pub action: Action,
    pub path: PathBuf,
    pub replace: bool,
}
pub(super) enum Decision {
    Chosen(Choice),
    Cancelled,
}

/// Keep raw Unix paths authoritative until the user actually edits their text.
#[derive(Default)]
pub(super) struct PathField {
    text: String,
    raw: Option<PathBuf>,
}
impl PathField {
    pub fn new(path: PathBuf) -> Self {
        let mut field = Self::default();
        field.set(path);
        field
    }
    pub fn path(&self) -> PathBuf {
        self.raw
            .clone()
            .unwrap_or_else(|| PathBuf::from(self.text.trim()))
    }
    pub fn set(&mut self, path: PathBuf) {
        self.text = display(path.as_os_str());
        self.raw = Some(path);
    }
    pub fn edit(&mut self, ui: &mut egui::Ui) {
        if ui.text_edit_singleline(&mut self.text).changed() {
            self.raw = None;
        }
    }
}
fn display(name: &std::ffi::OsStr) -> String {
    name.to_str()
        .map(str::to_owned)
        .unwrap_or_else(|| format!("{name:?}"))
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Kind {
    Directory,
    File,
    Link,
    Other,
}
#[derive(Debug)]
struct Entry {
    name: OsString,
    label: String,
    search: String,
    kind: Kind,
}
struct Listing {
    directory: PathBuf,
    entries: Vec<Entry>,
    initial_name: Option<OsString>,
    partial: bool,
    unreadable: usize,
}
impl Entry {
    fn new(name: OsString, kind: Kind) -> Self {
        let label = display(&name);
        let search = label.to_lowercase();
        Self {
            name,
            label,
            search,
            kind,
        }
    }
    fn folder(&self) -> bool {
        matches!(self.kind, Kind::Directory | Kind::Link)
    }
    fn hidden(&self) -> bool {
        use std::os::unix::ffi::OsStrExt;
        self.name.as_os_str().as_bytes().starts_with(b".")
    }
}
enum Job {
    Browse { path: PathBuf, initial: bool },
    Check { path: PathBuf, action: Action },
}
struct Request {
    generation: u64,
    job: Job,
}
enum Outcome {
    Listing(Listing),
    Choice(Choice),
    Replace(PathBuf),
}
struct Reply {
    generation: u64,
    result: Result<Outcome, String>,
}
struct Worker {
    generation: Arc<AtomicU64>,
    stop: Arc<AtomicBool>,
    pending: Arc<Mutex<Option<Request>>>,
    latest: Arc<Mutex<Option<Reply>>>,
    wake: Option<mpsc::SyncSender<()>>,
}
impl Worker {
    fn new(ctx: egui::Context) -> Self {
        let generation = Arc::new(AtomicU64::new(0));
        let stop = Arc::new(AtomicBool::new(false));
        let pending = Arc::new(Mutex::new(None::<Request>));
        let latest = Arc::new(Mutex::new(None));
        let (wake, receiver) = mpsc::sync_channel(1);
        let (requests, output, version, done) = (
            pending.clone(),
            latest.clone(),
            generation.clone(),
            stop.clone(),
        );
        std::thread::spawn(move || {
            while receiver.recv().is_ok() && !done.load(Ordering::Relaxed) {
                let Some(request) = requests.lock().unwrap().take() else {
                    continue;
                };
                let cancelled = || {
                    done.load(Ordering::Relaxed)
                        || version.load(Ordering::Relaxed) != request.generation
                };
                let result = execute(request.job, &cancelled);
                if !cancelled() {
                    *output.lock().unwrap() = Some(Reply {
                        generation: request.generation,
                        result,
                    });
                    ctx.request_repaint_of(egui::ViewportId::ROOT);
                }
            }
        });
        Self {
            generation,
            stop,
            pending,
            latest,
            wake: Some(wake),
        }
    }
    fn request(&self, job: Job) -> u64 {
        let generation = self.generation.fetch_add(1, Ordering::Relaxed) + 1;
        *self.pending.lock().unwrap() = Some(Request { generation, job });
        let _ = self.wake.as_ref().unwrap().try_send(());
        generation
    }
}
impl Drop for Worker {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        self.wake.take();
    }
}
fn execute(job: Job, cancelled: &impl Fn() -> bool) -> Result<Outcome, String> {
    if cancelled() {
        return Err("Cancelled".into());
    }
    match job {
        Job::Browse { path, initial } => {
            let path = if path.is_absolute() {
                path
            } else {
                std::env::current_dir()
                    .map_err(|e| e.to_string())?
                    .join(path)
            };
            let (mut directory, name) = if initial && !path.is_dir() {
                (
                    path.parent()
                        .filter(|p| !p.as_os_str().is_empty())
                        .unwrap_or(Path::new("/"))
                        .to_owned(),
                    path.file_name().map(OsString::from),
                )
            } else {
                (path, None)
            };
            if initial {
                while !directory.is_dir() {
                    if cancelled() {
                        return Err("Cancelled".into());
                    }
                    let Some(parent) = directory.parent() else {
                        break;
                    };
                    directory = parent.to_owned();
                }
            }
            let mut listing = scan(&directory, ENTRY_LIMIT, SCAN_BUDGET, cancelled)?;
            listing.initial_name = name;
            Ok(Outcome::Listing(listing))
        }
        Job::Check { path, action } => match fs::symlink_metadata(&path) {
            Ok(metadata) if metadata.is_dir() => {
                scan(&path, ENTRY_LIMIT, SCAN_BUDGET, cancelled).map(Outcome::Listing)
            }
            Ok(metadata) if !metadata.is_file() => Err(
                "Choose a regular file. Symbolic-link files and special files are not supported."
                    .into(),
            ),
            Ok(_) if action == Action::SaveTheme => Ok(Outcome::Replace(path)),
            Ok(_) => Ok(Outcome::Choice(Choice {
                action,
                path,
                replace: false,
            })),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound && action == Action::SaveTheme => {
                let parent = path.parent().ok_or("Choose a destination folder")?;
                if !fs::metadata(parent).map_err(|e| e.to_string())?.is_dir() {
                    return Err("Destination folder is not a directory".into());
                }
                Ok(Outcome::Choice(Choice {
                    action,
                    path,
                    replace: false,
                }))
            }
            Err(e) => Err(format!("{}: {e}", path.display())),
        },
    }
}
fn scan(
    path: &Path,
    limit: usize,
    budget: Duration,
    cancelled: &impl Fn() -> bool,
) -> Result<Listing, String> {
    let mut directory = fs::read_dir(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let started = Instant::now();
    let mut entries = Vec::new();
    let mut unreadable = 0;
    let mut partial = false;
    loop {
        if cancelled() {
            return Err("Cancelled".into());
        }
        // Cooperative bounds; an individual filesystem syscall cannot be interrupted.
        if entries.len() + unreadable >= limit || started.elapsed() > budget {
            partial = true;
            break;
        }
        let Some(entry) = directory.next() else {
            break;
        };
        let entry = match entry {
            Ok(entry) => entry,
            Err(_) => {
                unreadable += 1;
                continue;
            }
        };
        let kind = match entry.file_type() {
            Ok(kind) if kind.is_dir() => Kind::Directory,
            Ok(kind) if kind.is_file() => Kind::File,
            Ok(kind) if kind.is_symlink() => Kind::Link,
            Ok(_) => Kind::Other,
            Err(_) => {
                unreadable += 1;
                continue;
            }
        };
        entries.push(Entry::new(entry.file_name(), kind));
    }
    entries
        .sort_by(|a, b| (!a.folder(), &a.search, &a.name).cmp(&(!b.folder(), &b.search, &b.name)));
    Ok(Listing {
        directory: path.to_owned(),
        entries,
        initial_name: None,
        partial,
        unreadable,
    })
}
fn file_name(name: &std::ffi::OsStr) -> Result<(), String> {
    let mut components = Path::new(name).components();
    if !matches!(components.next(), Some(Component::Normal(_))) || components.next().is_some() {
        return Err("Enter a filename within the selected folder".into());
    }
    use std::os::unix::ffi::OsStrExt;
    if name.as_bytes().contains(&0) || name.as_bytes().contains(&b'/') {
        return Err("Filename contains a path separator or NUL byte".into());
    }
    Ok(())
}
fn theme_file(name: &std::ffi::OsStr) -> bool {
    Path::new(name)
        .extension()
        .and_then(|e| e.to_str())
        .is_some_and(|e| e.eq_ignore_ascii_case("json") || e.eq_ignore_ascii_case("xtf"))
}

pub(super) struct Picker {
    action: Action,
    worker: Worker,
    generation: u64,
    directory: PathBuf,
    location: String,
    filename: String,
    raw_name: Option<OsString>,
    entries: Vec<Entry>,
    selected: Option<usize>,
    query: String,
    hidden: bool,
    all_files: bool,
    loading: bool,
    partial: bool,
    unreadable: usize,
    error: Option<String>,
    replace: Option<PathBuf>,
    ready: Option<Choice>,
}
impl Picker {
    pub fn new(action: Action, seed: PathBuf, ctx: &egui::Context) -> Self {
        let seed = if seed.as_os_str().is_empty() {
            home()
        } else {
            seed
        };
        let worker = Worker::new(ctx.clone());
        let generation = worker.request(Job::Browse {
            path: seed,
            initial: true,
        });
        Self {
            action,
            worker,
            generation,
            directory: home(),
            location: String::new(),
            filename: if action == Action::SaveTheme {
                "xrg-theme.json".into()
            } else {
                String::new()
            },
            raw_name: None,
            entries: Vec::new(),
            selected: None,
            query: String::new(),
            hidden: false,
            all_files: action == Action::ImportLegacy,
            loading: true,
            partial: false,
            unreadable: 0,
            error: None,
            replace: None,
            ready: None,
        }
    }
    fn browse(&mut self, path: PathBuf) {
        let path = if path.is_absolute() {
            path
        } else {
            self.directory.join(path)
        };
        self.generation = self.worker.request(Job::Browse {
            path,
            initial: false,
        });
        self.loading = true;
        self.error = None;
        self.selected = None;
        self.replace = None;
        if self.action != Action::SaveTheme {
            self.raw_name = None;
            self.filename.clear();
        }
    }
    pub(super) fn poll(&mut self) {
        let reply = self.worker.latest.lock().unwrap().take();
        let Some(reply) = reply.filter(|r| r.generation == self.generation) else {
            return;
        };
        self.loading = false;
        match reply.result {
            Ok(Outcome::Listing(listing)) => {
                self.directory = listing.directory;
                self.location = display(self.directory.as_os_str());
                self.entries = listing.entries;
                self.partial = listing.partial;
                self.unreadable = listing.unreadable;
                self.selected = None;
                self.error = None;
                if let Some(name) = listing.initial_name {
                    let name = if self.action == Action::SaveTheme
                        && Path::new(&name)
                            .extension()
                            .is_some_and(|e| e.eq_ignore_ascii_case("xtf"))
                    {
                        Path::new(&name).with_extension("json").into_os_string()
                    } else {
                        name
                    };
                    self.filename = display(&name);
                    self.raw_name = Some(name);
                }
            }
            Ok(Outcome::Choice(choice)) => self.ready = Some(choice),
            Ok(Outcome::Replace(path)) => self.replace = Some(path),
            Err(e) => {
                self.error = Some(e);
                self.location = display(self.directory.as_os_str());
            }
        }
    }
    fn select(&mut self, index: usize) {
        let entry = &self.entries[index];
        self.selected = Some(index);
        if entry.kind == Kind::File {
            self.filename = entry.label.clone();
            self.raw_name = Some(entry.name.clone());
        }
        self.error = None;
    }
    pub(super) fn accept(&mut self) {
        if self.loading {
            return;
        }
        if let Some(entry) = self
            .selected
            .map(|i| &self.entries[i])
            .filter(|e| e.folder())
        {
            self.browse(self.directory.join(&entry.name));
            return;
        }
        let mut name = self
            .raw_name
            .clone()
            .unwrap_or_else(|| OsString::from(&self.filename));
        if let Err(e) = file_name(&name) {
            self.error = Some(e);
            return;
        }
        if self.action == Action::SaveTheme && Path::new(&name).extension().is_none() {
            name.push(".json");
        }
        self.generation = self.worker.request(Job::Check {
            path: self.directory.join(name),
            action: self.action,
        });
        self.loading = true;
        self.error = None;
    }
    pub(super) fn confirm_replace(&mut self) {
        if let Some(path) = self.replace.take() {
            self.ready = Some(Choice {
                action: self.action,
                path,
                replace: true,
            });
        }
    }
    pub(super) fn is_loading(&self) -> bool {
        self.loading
    }
    pub(super) fn needs_replacement(&self) -> bool {
        self.replace.is_some()
    }
    pub(super) fn select_name(&mut self, name: &std::ffi::OsStr) -> Result<(), String> {
        let index = self
            .entries
            .iter()
            .position(|e| e.name == name)
            .ok_or("File not present in directory listing")?;
        self.select(index);
        Ok(())
    }
    pub fn show(&mut self, parent: &mut egui::Ui) -> Option<Decision> {
        if parent.input_mut(|i| i.consume_key(egui::Modifiers::NONE, egui::Key::Escape)) {
            return Some(Decision::Cancelled);
        }
        if parent.input_mut(|i| i.consume_key(egui::Modifiers::CTRL, egui::Key::H)) {
            self.hidden = !self.hidden;
        }
        if parent.input_mut(|i| i.consume_key(egui::Modifiers::CTRL, egui::Key::R)) {
            self.browse(self.directory.clone());
        }
        if parent.input_mut(|i| i.consume_key(egui::Modifiers::ALT, egui::Key::ArrowUp))
            && let Some(parent) = self.directory.parent()
        {
            self.browse(parent.to_owned());
        }
        self.poll();
        if let Some(choice) = self.ready.take() {
            return Some(Decision::Chosen(choice));
        }
        let width = (parent.max_rect().width() - 32.).clamp(240., 580.);
        let height = (parent.max_rect().height() - 240.).clamp(80., 280.);
        let ctx = parent.ctx().clone();
        let mut cancel = false;
        let modal = egui::Modal::new(egui::Id::unique("xrg-file-picker")).show(&ctx, |ui| {
            ui.set_width(width);
            ui.heading(self.action.title());
            if self.action == Action::SaveTheme {
                ui.label("A .json extension is added when the filename has no extension.");
            }
            if let Some(path) = &self.replace {
                ui.label("Replace the existing file with this JSON theme?");
                ui.label(display(path.as_os_str()));
                ui.horizontal(|ui| {
                    if ui.button("Replace file").clicked() {
                        self.confirm_replace();
                    }
                    if ui.button("Back").clicked() {
                        self.replace = None;
                    }
                    cancel = ui.button("Cancel").clicked();
                });
                return;
            }
            ui.horizontal_wrapped(|ui| {
                if ui
                    .add_enabled(self.directory.parent().is_some(), egui::Button::new("Up"))
                    .clicked()
                {
                    self.browse(self.directory.parent().unwrap().to_owned());
                }
                if ui.button("Home").clicked() {
                    self.browse(home());
                }
                if ui.button("Reload").clicked() {
                    self.browse(self.directory.clone());
                }
                ui.checkbox(&mut self.hidden, "Hidden files");
                if self.action != Action::ImportLegacy {
                    ui.checkbox(&mut self.all_files, "All files");
                }
            });
            ui.horizontal(|ui| {
                let label = ui.label("Folder");
                let response = ui
                    .add_sized(
                        [ui.available_width() - 40., 22.],
                        egui::TextEdit::singleline(&mut self.location),
                    )
                    .labelled_by(label.id);
                if ui.input_mut(|i| i.consume_key(egui::Modifiers::CTRL, egui::Key::L)) {
                    response.request_focus();
                }
                if ui.button("Go").clicked()
                    || response.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter))
                {
                    self.browse(PathBuf::from(self.location.trim()));
                }
            });
            ui.horizontal(|ui| {
                let label = ui.label("Filter");
                if ui
                    .add(egui::TextEdit::singleline(&mut self.query).char_limit(256))
                    .labelled_by(label.id)
                    .changed()
                {
                    self.selected = None;
                }
            });
            let query = self.query.to_lowercase();
            let visible: Vec<_> = self
                .entries
                .iter()
                .enumerate()
                .filter(|(_, e)| {
                    (self.hidden || !e.hidden())
                        && (self.all_files || e.folder() || theme_file(&e.name))
                        && e.search.contains(&query)
                })
                .map(|(i, _)| i)
                .collect();
            let mut click = None;
            let mut open = false;
            ui.add_enabled_ui(!self.loading, |ui| {
                egui::ScrollArea::vertical()
                    .id_salt("file-list")
                    .max_height(height)
                    .min_scrolled_height(height)
                    .show_rows(
                        ui,
                        ui.text_style_height(&egui::TextStyle::Body),
                        visible.len(),
                        |ui, rows| {
                            for row in rows {
                                let i = visible[row];
                                let entry = &self.entries[i];
                                let prefix = match entry.kind {
                                    Kind::Directory => "[folder]",
                                    Kind::Link => "[link / folder only]",
                                    Kind::File => "",
                                    Kind::Other => "[special file]",
                                };
                                let response = ui.add_enabled(
                                    entry.kind != Kind::Other,
                                    egui::Button::selectable(
                                        self.selected == Some(i),
                                        format!("{prefix} {}", entry.label),
                                    ),
                                );
                                if response.clicked() {
                                    click = Some(i);
                                }
                                if response.double_clicked() {
                                    click = Some(i);
                                    open = true;
                                }
                            }
                        },
                    );
            });
            if let Some(i) = click {
                self.select(i);
            }
            if open {
                self.accept();
            }
            ui.horizontal(|ui| {
                let label = ui.label("Filename");
                let response = ui
                    .add(egui::TextEdit::singleline(&mut self.filename))
                    .labelled_by(label.id);
                if response.changed() {
                    self.raw_name = None;
                    self.selected = None;
                    self.error = None;
                }
                if response.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter)) {
                    self.accept();
                }
            });
            if self.loading {
                ui.label("Reading folder or checking file…");
            } else {
                ui.label(format!("{} matching entries", visible.len()));
            }
            if self.partial {
                ui.label("Listing limit reached. Type a filename or open a smaller folder.");
            }
            if self.unreadable > 0 {
                ui.label(format!(
                    "{} entries could not be inspected",
                    self.unreadable
                ));
            }
            if let Some(error) = &self.error {
                ui.colored_label(egui::Color32::LIGHT_YELLOW, error);
            }
            ui.horizontal(|ui| {
                let folder = self.selected.is_some_and(|i| self.entries[i].folder());
                if ui
                    .add_enabled(
                        !self.loading
                            && self.error.is_none()
                            && (folder || !self.filename.is_empty()),
                        egui::Button::new(if folder {
                            "Open folder"
                        } else {
                            self.action.button()
                        }),
                    )
                    .clicked()
                {
                    self.accept();
                }
                cancel = ui.button("Cancel").clicked();
            });
        });
        if cancel || modal.should_close() {
            return Some(Decision::Cancelled);
        }
        self.ready.take().map(Decision::Chosen)
    }
}
fn home() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| PathBuf::from("/"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        os::unix::{ffi::OsStringExt, fs::symlink},
        thread,
    };
    static NEXT: AtomicU64 = AtomicU64::new(0);
    struct Scratch(PathBuf);
    impl Scratch {
        fn new() -> Self {
            let p = std::env::temp_dir().join(format!(
                "xrg-file-picker-test-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&p).unwrap();
            Self(p)
        }
    }
    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    fn wait(picker: &mut Picker) {
        let deadline = Instant::now() + Duration::from_secs(3);
        while picker.loading {
            picker.poll();
            assert!(Instant::now() < deadline, "Picker worker did not respond");
            thread::sleep(Duration::from_millis(2));
        }
    }
    #[test]
    fn directory_scan_is_bounded_cancellable_and_does_not_recurse_into_links() {
        let s = Scratch::new();
        fs::create_dir(s.0.join("folder")).unwrap();
        fs::write(s.0.join("a.JSON"), b"{}").unwrap();
        fs::write(s.0.join("b.xtf"), b"{}").unwrap();
        symlink(&s.0, s.0.join("loop")).unwrap();
        let list = scan(&s.0, 20, Duration::from_secs(2), &|| false).unwrap();
        assert_eq!(list.entries.len(), 4);
        assert_eq!(list.entries[0].kind, Kind::Directory);
        assert!(
            list.entries
                .iter()
                .any(|e| e.name == "loop" && e.kind == Kind::Link)
        );
        let limited = scan(&s.0, 2, Duration::from_secs(2), &|| false).unwrap();
        assert_eq!(limited.entries.len(), 2);
        assert!(limited.partial);
        assert!(scan(&s.0, 20, Duration::from_secs(2), &|| true).is_err());
        assert!(scan(&s.0.join("missing"), 20, Duration::from_secs(2), &|| false).is_err());
    }
    #[test]
    fn latest_navigation_wins_and_a_bad_folder_retains_the_last_successful_location() {
        let s = Scratch::new();
        for dir in ["first", "last"] {
            fs::create_dir(s.0.join(dir)).unwrap();
            fs::write(s.0.join(dir).join(dir), b"{}").unwrap();
        }
        let mut p = Picker::new(Action::LoadTheme, s.0.clone(), &egui::Context::default());
        p.browse(s.0.join("first"));
        p.browse(s.0.join("last"));
        wait(&mut p);
        assert_eq!(p.directory, s.0.join("last"));
        assert_eq!(p.entries[0].name, "last");
        p.browse(s.0.clone());
        wait(&mut p);
        p.browse(PathBuf::from("last"));
        wait(&mut p);
        assert_eq!(p.directory, s.0.join("last"));
        p.browse(s.0.join("missing"));
        wait(&mut p);
        assert!(p.error.is_some());
        assert_eq!(p.directory, s.0.join("last"));
    }
    #[test]
    fn replacing_a_file_requires_a_separate_confirmation_and_back_does_not_write() {
        let s = Scratch::new();
        let path = s.0.join("original.json");
        fs::write(&path, b"keep original").unwrap();
        let mut p = Picker::new(Action::SaveTheme, path.clone(), &egui::Context::default());
        wait(&mut p);
        p.accept();
        wait(&mut p);
        assert_eq!(p.replace, Some(path.clone()));
        assert!(p.ready.is_none());
        assert_eq!(fs::read(&path).unwrap(), b"keep original");
        p.replace = None;
        assert!(p.ready.is_none());
        p.accept();
        wait(&mut p);
        p.confirm_replace();
        assert_eq!(
            p.ready,
            Some(Choice {
                action: Action::SaveTheme,
                path,
                replace: true
            })
        );
    }
    #[test]
    fn saving_an_unextended_name_adds_json_but_the_chooser_never_creates_the_file() {
        let s = Scratch::new();
        let mut p = Picker::new(Action::SaveTheme, s.0.clone(), &egui::Context::default());
        wait(&mut p);
        p.filename = "theme with spaces".into();
        p.accept();
        wait(&mut p);
        let choice = p.ready.take().unwrap();
        assert_eq!(choice.path, s.0.join("theme with spaces.json"));
        assert!(!choice.replace);
        assert!(!choice.path.exists());
        for invalid in [
            "",
            ".",
            "..",
            "../theme",
            "/tmp/theme",
            "theme/",
            "theme//",
            "bad\0name",
        ] {
            assert!(file_name(std::ffi::OsStr::new(invalid)).is_err());
        }
    }
    #[test]
    fn non_utf8_names_survive_selection_and_an_unedited_path_field() {
        let s = Scratch::new();
        let name = OsString::from_vec(b"theme-\xff.JSON".to_vec());
        let path = s.0.join(&name);
        fs::write(&path, b"{}").unwrap();
        let ctx = egui::Context::default();
        let mut p = Picker::new(Action::LoadTheme, s.0.clone(), &ctx);
        wait(&mut p);
        let index = p.entries.iter().position(|e| e.name == name).unwrap();
        p.select(index);
        p.accept();
        wait(&mut p);
        assert_eq!(p.ready.take().unwrap().path, path);
        let mut field = PathField::new(path.clone());
        let mut output = ctx.run_ui(egui::RawInput::default(), |ui| field.edit(ui));
        output.textures_delta.clear();
        assert_eq!(field.path(), path);
    }
    #[test]
    fn opening_save_after_an_xtf_load_suggests_a_separate_json_file() {
        let s = Scratch::new();
        let original = s.0.join("Original.XTF");
        fs::write(&original, b"original theme").unwrap();
        let mut picker = Picker::new(
            Action::SaveTheme,
            original.clone(),
            &egui::Context::default(),
        );
        wait(&mut picker);
        picker.accept();
        wait(&mut picker);
        assert_eq!(picker.ready.unwrap().path, s.0.join("Original.json"));
        assert_eq!(fs::read(original).unwrap(), b"original theme");
        assert!(!s.0.join("Original.json").exists());
        let mut missing = Picker::new(
            Action::ImportLegacy,
            s.0.join("not-installed/settings.conf"),
            &egui::Context::default(),
        );
        wait(&mut missing);
        assert!(missing.error.is_none());
        assert_eq!(missing.directory, s.0);
        assert_eq!(missing.filename, "settings.conf");
    }
    #[test]
    fn file_links_are_rejected_and_escape_cancels_the_modal() {
        let s = Scratch::new();
        let original = s.0.join("real.json");
        fs::write(&original, b"{}").unwrap();
        let link = s.0.join("link.json");
        symlink(original, &link).unwrap();
        assert!(
            execute(
                Job::Check {
                    path: link,
                    action: Action::LoadTheme
                },
                &|| false
            )
            .is_err()
        );
        let ctx = egui::Context::default();
        let mut p = Picker::new(Action::LoadTheme, s.0.clone(), &ctx);
        let mut cancelled = false;
        let mut output = ctx.run_ui(
            egui::RawInput {
                events: vec![egui::Event::Key {
                    key: egui::Key::Escape,
                    physical_key: None,
                    pressed: true,
                    repeat: false,
                    modifiers: egui::Modifiers::NONE,
                }],
                ..Default::default()
            },
            |ui| {
                cancelled = matches!(p.show(ui), Some(Decision::Cancelled));
            },
        );
        output.textures_delta.clear();
        assert!(cancelled);
    }
}
