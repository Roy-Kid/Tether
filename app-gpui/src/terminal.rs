//! The native viewport for one local shell.
//!
//! GPUI does not paint the terminal. The focused pane's canvas is a child
//! window, and [`tether_ffi::RenderSurface`] draws into it. On Windows that
//! child is an HWND with extended style 0: `WS_EX_NOREDIRECTIONBITMAP` makes
//! the GL fallback present nowhere. The child is hidden while a GPUI overlay
//! is open, because a child HWND is composited above the GPUI window.

use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::sync::{Arc, Mutex, mpsc};

use gpui::{Bounds, Pixels, Window};
use tether_ffi::{
    KeyModifiers, KeyPress, LocalShell, MouseTracking, OverlayDto, PaletteDto, PointerButton,
    PointerPhase, RenderSurface, RgbaDto, SelectionDto, TerminalInput, open_local,
};

use crate::workspace::Command;

/// A chord the child window handles because it, not GPUI, has the keyboard.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum HostCommand {
    Workspace(Command),
    Palette,
}

/// A workspace chord the child window has to honour itself. While it has
/// keyboard focus, GPUI does not see the key.
pub(crate) fn shortcut_for(vk: u32, control: bool, shift: bool, alt: bool) -> Option<HostCommand> {
    let plain = control && !shift && !alt;
    let shifted = control && shift && !alt;
    match (vk, plain, shifted, alt && shift && !control) {
        (0x54, _, true, _) => Some(HostCommand::Workspace(Command::NewTab)), // Ctrl+Shift+T
        (0x4E, true, _, _) => Some(HostCommand::Workspace(Command::NewTab)), // Ctrl+N
        (0x57, _, true, _) => Some(HostCommand::Workspace(Command::CloseTab)), // Ctrl+Shift+W
        (0x57, true, _, _) => Some(HostCommand::Workspace(Command::CloseTab)), // Ctrl+W
        (0x73, true, _, _) => Some(HostCommand::Workspace(Command::CloseTab)), // Ctrl+F4
        (0x50, _, true, _) => Some(HostCommand::Palette),                    // Ctrl+Shift+P
        (0x50, _, _, true) => Some(HostCommand::Palette),                    // Alt+Shift+P
        (0x44, _, true, _) => Some(HostCommand::Workspace(Command::SplitRight)), // Ctrl+Shift+D
        (0x45, _, true, _) => Some(HostCommand::Workspace(Command::SplitDown)), // Ctrl+Shift+E
        (0x21, true, _, _) => Some(HostCommand::Workspace(Command::PreviousTab)), // Ctrl+PageUp
        (0x22, true, _, _) => Some(HostCommand::Workspace(Command::NextTab)), // Ctrl+PageDown
        _ => None,
    }
}

pub(crate) fn take_commands() -> Vec<HostCommand> {
    COMMANDS.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).drain(..).collect()
}

fn enqueue(command: HostCommand) {
    COMMANDS.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).push(command);
}

static COMMANDS: Mutex<Vec<HostCommand>> = Mutex::new(Vec::new());

/// One child viewport. Cloning shares it with the canvas callback.
#[derive(Clone)]
pub(crate) struct TerminalHost {
    inner: Rc<Engine>,
}

struct Engine {
    #[cfg(windows)]
    child: RefCell<Option<WinChild>>,
    /// Last size sent to the renderer, so a repaint does not wake the shell loop.
    #[cfg(windows)]
    placed: Cell<(i32, i32, bool)>,
    /// Last physical rectangle. A one-pixel oscillation at 150% DPI is the same place.
    #[cfg(windows)]
    edges: Cell<(i32, i32, i32, i32)>,
    /// Local tabs that already have a shell, and the one currently drawn.
    #[cfg(windows)]
    opened: RefCell<std::collections::HashSet<u64>>,
    #[cfg(windows)]
    focused_shell: Cell<Option<u64>>,
}

pub(crate) fn host() -> TerminalHost {
    TerminalHost {
        inner: Rc::new(Engine {
            #[cfg(windows)]
            child: RefCell::new(None),
            #[cfg(windows)]
            placed: Cell::new((-1, -1, false)),
            #[cfg(windows)]
            edges: Cell::new((-1, -1, -1, -1)),
            #[cfg(windows)]
            opened: RefCell::new(std::collections::HashSet::new()),
            #[cfg(windows)]
            focused_shell: Cell::new(None),
        }),
    }
}

impl TerminalHost {
    /// Moves the viewport onto `bounds` (window coordinates, in logical
    /// pixels). `visible` is false while a palette, dialog, or host picker
    /// covers the canvas.
    /// Opens a shell for each local tab, closes one that went away, and draws
    /// `focused`. A non-local tab passes `None` and the view hides the child.
    pub fn sync(&self, locals: &[u64], focused: Option<u64>) {
        #[cfg(windows)]
        sync_win(&self.inner, locals, focused);
        #[cfg(not(windows))]
        {
            let _ = (locals, focused, &self.inner);
        }
    }

    pub fn place(&self, window: &mut Window, bounds: Bounds<Pixels>, visible: bool, dark: bool) {
        #[cfg(windows)]
        place_win(&self.inner, window, bounds, visible, dark);
        #[cfg(not(windows))]
        {
            let _ = (window, bounds, visible, dark, &self.inner);
        }
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        #[cfg(windows)]
        {
            if let Some(child) = self.child.borrow_mut().take() {
                child.shutdown();
            }
        }
    }
}

fn palette(dark: bool) -> PaletteDto {
    let (background, foreground, cursor) =
        if dark { (0x0c0c0c, 0xf3f3f3, 0x0078d4) } else { (0xffffff, 0x1a1a1a, 0x005fb8) };
    PaletteDto {
        background: rgba(background, 1.0),
        foreground: rgba(foreground, 1.0),
        cursor: rgba(cursor, 1.0),
        ansi: ANSI.into_iter().map(|color| rgba(color, 1.0)).collect(),
    }
}

fn rgba(hex: u32, alpha: f32) -> RgbaDto {
    RgbaDto {
        red: ((hex >> 16) & 0xff) as f32 / 255.0,
        green: ((hex >> 8) & 0xff) as f32 / 255.0,
        blue: (hex & 0xff) as f32 / 255.0,
        alpha,
    }
}

const ANSI: [u32; 16] = [
    0x000000, 0xcd3131, 0x0dbc79, 0xe5e510, 0x2472c8, 0xbc3fbc, 0x11a8cd, 0xe5e5e5, 0x666666,
    0xf14c4c, 0x23d18b, 0xf5f543, 0x3b8eea, 0xd670d6, 0x29b8db, 0xffffff,
];

#[cfg(windows)]
struct WinChild {
    hwnd: isize,
    tx: tokio::sync::mpsc::UnboundedSender<Note>,
    done: mpsc::Receiver<()>,
}

#[cfg(windows)]
enum Note {
    Open { id: u64 },
    Focus { id: u64 },
    Close { id: u64 },
    Resize { width: u32, height: u32, font: f32, dark: bool },
    Paint,
    Stop,
}

#[cfg(windows)]
struct Grid {
    cell_w: f32,
    cell_h: f32,
    columns: u16,
    rows: u16,
    mouse: MouseTracking,
    dark: bool,
    selection: Option<SelectionDto>,
    anchor: Option<(u16, u16)>,
}

#[cfg(windows)]
struct Live {
    session: Option<std::sync::Arc<tether_ffi::Session>>,
    grid: Grid,
    tx: Option<tokio::sync::mpsc::UnboundedSender<Note>>,
}

#[cfg(windows)]
fn sync_win(engine: &Engine, locals: &[u64], focused: Option<u64>) {
    let child = engine.child.borrow();
    let Some(child) = child.as_ref() else { return };
    let mut opened = engine.opened.borrow_mut();
    for id in locals {
        if opened.insert(*id) {
            let _ = child.tx.send(Note::Open { id: *id });
        }
    }
    let stale: Vec<u64> = opened.iter().copied().filter(|id| !locals.contains(id)).collect();
    for id in stale {
        opened.remove(&id);
        let _ = child.tx.send(Note::Close { id });
    }
    if engine.focused_shell.get() != focused {
        engine.focused_shell.set(focused);
        if let Some(id) = focused {
            let _ = child.tx.send(Note::Focus { id });
        }
    }
}

fn place_win(
    engine: &Engine,
    window: &mut Window,
    bounds: Bounds<Pixels>,
    visible: bool,
    dark: bool,
) {
    use raw_window_handle::{HasWindowHandle, RawWindowHandle};
    let scale = window.scale_factor();
    let origin_x = bounds.origin.x.as_f32();
    let origin_y = bounds.origin.y.as_f32();
    let x = snap(origin_x, scale);
    let y = snap(origin_y, scale);
    let width = (snap(origin_x + bounds.size.width.as_f32(), scale) - x).max(1);
    let height = (snap(origin_y + bounds.size.height.as_f32(), scale) - y).max(1);
    let (x, y, width, height) = hold_edges(engine, x, y, width, height);
    if engine.child.borrow().is_none()
        && let Ok(handle) = window.window_handle()
        && let RawWindowHandle::Win32(raw) = handle.as_raw()
    {
        let parent = raw.hwnd.get();
        if let Some(child) = WinChild::open(parent, width as u32, height as u32) {
            *engine.child.borrow_mut() = Some(child);
        }
    }
    let child = engine.child.borrow();
    let Some(child) = child.as_ref() else { return };
    unsafe {
        set_window_pos(
            child.hwnd,
            x,
            y,
            width,
            height,
            SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOREDRAW | SWP_NOCOPYBITS,
        );
        show_window(child.hwnd, if visible { SW_SHOWNA } else { SW_HIDE });
        // Focus follows visibility, and only while this window is in front.
        // A settings window is another GPUI window; stealing focus from it
        // every frame would make it impossible to type there.
        let parent = get_parent(child.hwnd);
        let foreground = get_foreground_window();
        if visible && foreground == parent {
            set_focus(child.hwnd);
        } else if !visible && (foreground == child.hwnd || foreground == parent) && parent != 0 {
            set_focus(parent);
        }
    }
    let key = (width, height, dark);
    if engine.placed.get() != key {
        engine.placed.set(key);
        let _ = child.tx.send(Note::Resize {
            width: width as u32,
            height: height as u32,
            font: 13.0 * scale,
            dark,
        });
    }
}

#[cfg(windows)]
fn snap(logical: f32, scale: f32) -> i32 {
    (logical * scale).round() as i32
}

/// Keeps a rectangle that moved by at most one physical pixel. At 150% DPI the
/// snapped edges flip by one pixel between frames, and following that flip
/// resizes the shell.
fn hold_edges(engine: &Engine, x: i32, y: i32, width: i32, height: i32) -> (i32, i32, i32, i32) {
    let (px, py, pw, ph) = engine.edges.get();
    if px >= 0
        && (x - px).abs() <= 1
        && (y - py).abs() <= 1
        && (width - pw).abs() <= 1
        && (height - ph).abs() <= 1
    {
        return (px, py, pw, ph);
    }
    engine.edges.set((x, y, width, height));
    (x, y, width, height)
}

#[cfg(windows)]
impl WinChild {
    fn open(parent: isize, width: u32, height: u32) -> Option<Self> {
        let hwnd = unsafe { create_child(parent, width, height) }?;
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        let (done_tx, done) = mpsc::channel();
        let live = Arc::new(Mutex::new(Live {
            session: None,
            grid: Grid {
                cell_w: 8.0,
                cell_h: 16.0,
                columns: 80,
                rows: 24,
                mouse: MouseTracking::Off,
                dark: true,
                selection: None,
                anchor: None,
            },
            tx: Some(tx.clone()),
        }));
        CHILDREN
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .insert(hwnd, Arc::clone(&live));
        std::thread::Builder::new()
            .name("tether-terminal".into())
            .spawn(move || {
                let runtime = tokio::runtime::Builder::new_multi_thread()
                    .enable_all()
                    .build()
                    .expect("terminal runtime");
                runtime.block_on(pump(hwnd as u64, width, height, rx, live));
                let _ = done_tx.send(());
            })
            .expect("terminal thread");
        Some(Self { hwnd, tx, done })
    }

    fn shutdown(self) {
        let _ = self.tx.send(Note::Stop);
        let _ = self.done.recv_timeout(std::time::Duration::from_secs(2));
        CHILDREN.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).remove(&self.hwnd);
        unsafe { destroy_window(self.hwnd) };
    }
}

#[cfg(windows)]
async fn pump(
    hwnd: u64,
    mut width: u32,
    mut height: u32,
    mut rx: tokio::sync::mpsc::UnboundedReceiver<Note>,
    live: Arc<Mutex<Live>>,
) {
    let surface = match RenderSurface::from_hwnd(hwnd, width.max(1), height.max(1)).await {
        Ok(surface) => surface,
        Err(error) => {
            eprintln!("terminal surface: {error}");
            return;
        }
    };
    surface.set_fonts("Cascadia Mono".into(), "Microsoft YaHei".into());
    let mut font = 13.0_f32;
    let mut dark = true;
    let mut desk = Desk::default();
    loop {
        let active = desk.current();
        tokio::select! {
            biased;
            note = rx.recv() => {
                match note {
                    Some(Note::Open { id }) => {
                        if !desk.sessions.contains_key(&id)
                            && let Some(session) = open_shell().await
                        {
                            desk.sessions.insert(id, Arc::clone(&session));
                            desk.activate(&live, id);
                            apply_size(&surface, &session, &live, width, height, font);
                            present(&surface, &session, &live, dark);
                        }
                    }
                    Some(Note::Focus { id }) => {
                        if desk.sessions.contains_key(&id) {
                            desk.activate(&live, id);
                            if let Some(session) = desk.current() {
                                apply_size(&surface, &session, &live, width, height, font);
                                present(&surface, &session, &live, dark);
                            }
                        }
                    }
                    Some(Note::Close { id }) => {
                        if let Some(session) = desk.sessions.remove(&id) {
                            session.close();
                        }
                        if desk.active == Some(id) {
                            desk.active = None;
                            show_session(&live, None);
                        }
                    }
                    Some(Note::Resize { width: next_w, height: next_h, font: next_font, dark: next_dark }) => {
                        let changed = next_w != width || next_h != height || (next_font - font).abs() > 0.5 || next_dark != dark;
                        width = next_w;
                        height = next_h;
                        font = next_font;
                        dark = next_dark;
                        if changed && let Some(session) = desk.current() {
                            apply_size(&surface, &session, &live, width, height, font);
                            present(&surface, &session, &live, dark);
                        }
                    }
                    Some(Note::Paint) => {
                        if let Some(session) = desk.current() {
                            present(&surface, &session, &live, dark);
                        }
                    }
                    Some(Note::Stop) | None => break,
                }
            }
            changed = wait_for_change(active) => {
                let Some(session) = desk.current() else { continue };
                if !changed {
                    let id = desk.active;
                    if let Some(id) = id {
                        desk.sessions.remove(&id);
                    }
                    desk.active = None;
                    show_session(&live, None);
                    continue;
                }
                present(&surface, &session, &live, dark);
            }
        }
    }
    for session in desk.sessions.values() {
        session.close();
    }
    surface.close();
}

#[cfg(windows)]
#[derive(Default)]
struct Desk {
    sessions: std::collections::HashMap<u64, Arc<tether_ffi::Session>>,
    active: Option<u64>,
}

#[cfg(windows)]
impl Desk {
    fn current(&self) -> Option<Arc<tether_ffi::Session>> {
        self.active.and_then(|id| self.sessions.get(&id).cloned())
    }

    fn activate(&mut self, live: &Mutex<Live>, id: u64) {
        let session = self.sessions.get(&id).cloned();
        self.active = session.as_ref().map(|_| id);
        show_session(live, session);
    }
}

#[cfg(windows)]
fn show_session(live: &Mutex<Live>, session: Option<Arc<tether_ffi::Session>>) {
    let mut live = live.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    live.session = session;
    live.grid.selection = None;
    live.grid.anchor = None;
}

#[cfg(windows)]
async fn open_shell() -> Option<Arc<tether_ffi::Session>> {
    match open_local(LocalShell {
        directory: None,
        term: "xterm-256color".into(),
        columns: 80,
        rows: 24,
        scrollback_lines: 10_000,
        shell: None,
        history: None,
    })
    .await
    {
        Ok(session) => Some(session),
        Err(error) => {
            eprintln!("local shell: {error}");
            None
        }
    }
}

#[cfg(windows)]
async fn wait_for_change(session: Option<Arc<tether_ffi::Session>>) -> bool {
    match session {
        Some(session) => session.await_change().await,
        None => std::future::pending().await,
    }
}

#[cfg(windows)]
fn apply_size(
    surface: &RenderSurface,
    session: &tether_ffi::Session,
    live: &Mutex<Live>,
    width: u32,
    height: u32,
    font: f32,
) {
    surface.resize(width, height);
    let metrics = surface.measure(font).ok();
    let (cell_w, cell_h) = metrics
        .map(|metrics| (metrics.cell_width.max(1.0), metrics.line_height.max(1.0)))
        .unwrap_or((8.0, 16.0));
    let columns = ((width as f32) / cell_w).floor().clamp(2.0, 500.0) as u16;
    let rows = ((height as f32) / cell_h).floor().clamp(1.0, 300.0) as u16;
    let _ = session.resize(columns, rows);
    let mut live = live.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    live.grid.cell_w = cell_w;
    live.grid.cell_h = cell_h;
    live.grid.columns = columns;
    live.grid.rows = rows;
}

#[cfg(windows)]
fn present(surface: &RenderSurface, session: &tether_ffi::Session, live: &Mutex<Live>, dark: bool) {
    let frame = session.frame();
    let selection = {
        let mut live = live.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        live.grid.mouse = frame.mouse;
        live.grid.dark = dark;
        live.grid.selection
    };
    let overlay = OverlayDto {
        selection,
        link_underlines: Vec::new(),
        selection_color: rgba(if dark { 0x264f78 } else { 0xadd6ff }, 0.6),
        link_color: rgba(0x4cc2ff, 1.0),
    };
    if let Err(error) = surface.draw(frame, palette(dark), Some(overlay)) {
        eprintln!("terminal draw: {error}");
    }
}

#[cfg(windows)]
fn send_input(live: &Live, input: TerminalInput) {
    if let Some(session) = &live.session {
        let _ = session.send(input);
    }
}

#[cfg(windows)]
fn modifiers() -> KeyModifiers {
    // `GetKeyState` is the hardware state for a real key. A modifier this
    // window already saw is kept as well: the state bit is not set for a
    // key that was posted straight to the child.
    KeyModifiers {
        shift: SHIFT.load(std::sync::atomic::Ordering::Relaxed)
            || unsafe { get_key_state(0x10) } < 0,
        control: CONTROL.load(std::sync::atomic::Ordering::Relaxed)
            || unsafe { get_key_state(0x11) } < 0,
        alt: ALT.load(std::sync::atomic::Ordering::Relaxed) || unsafe { get_key_state(0x12) } < 0,
    }
}

#[cfg(windows)]
fn track_modifier(vk: u32, down: bool) {
    let flag = match vk {
        0x10 | 0xA0 | 0xA1 => &SHIFT,
        0x11 | 0xA2 | 0xA3 => &CONTROL,
        0x12 | 0xA4 | 0xA5 => &ALT,
        _ => return,
    };
    flag.store(down, std::sync::atomic::Ordering::Relaxed);
}

#[cfg(windows)]
static SHIFT: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
#[cfg(windows)]
static CONTROL: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
#[cfg(windows)]
static ALT: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

#[cfg(windows)]
fn named_key(vk: u32) -> Option<KeyPress> {
    Some(match vk {
        0x0D => KeyPress::Enter,
        0x09 => KeyPress::Tab,
        0x08 => KeyPress::Backspace,
        0x1B => KeyPress::Escape,
        0x2E => KeyPress::Delete,
        0x2D => KeyPress::Insert,
        0x26 => KeyPress::Up,
        0x28 => KeyPress::Down,
        0x25 => KeyPress::Left,
        0x27 => KeyPress::Right,
        0x24 => KeyPress::Home,
        0x23 => KeyPress::End,
        0x21 => KeyPress::PageUp,
        0x22 => KeyPress::PageDown,
        0x70..=0x7B => KeyPress::Function { number: (vk - 0x6F) as u8 },
        _ => return None,
    })
}

#[cfg(windows)]
fn on_key(hwnd: isize, vk: u32) -> bool {
    let Some(live) = child(hwnd) else { return false };
    let live = live.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let mods = modifiers();
    if let Some(command) = shortcut_for(vk, mods.control, mods.shift, mods.alt) {
        enqueue(command);
        // The command is applied on the next GPUI frame. Ask for one, so a
        // chord still lands while this window is not already painting.
        unsafe { wake(hwnd) };
        return true;
    }
    if let Some(key) = named_key(vk) {
        send_input(&live, TerminalInput::Key { key, modifiers: mods });
        return true;
    }
    if mods.control && !mods.alt && (0x41..=0x5A).contains(&vk) {
        let text = char::from(vk as u8).to_ascii_lowercase().to_string();
        send_input(&live, TerminalInput::Key { key: KeyPress::Char { text }, modifiers: mods });
        return true;
    }
    false
}

#[cfg(windows)]
fn on_char(hwnd: isize, text: String) {
    let Some(live) = child(hwnd) else { return };
    let live = live.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    if text.chars().all(|ch| ch.is_control()) {
        return;
    }
    send_input(&live, TerminalInput::Key { key: KeyPress::Char { text }, modifiers: modifiers() });
}

#[cfg(windows)]
fn cell_at(grid: &Grid, x: i32, y: i32) -> (u16, u16) {
    if grid.cell_w < 1.0 || grid.cell_h < 1.0 || grid.columns == 0 || grid.rows == 0 {
        return (0, 0);
    }
    let column = ((x as f32) / grid.cell_w).floor().max(0.0) as u16;
    let row = ((y as f32) / grid.cell_h).floor().max(0.0) as u16;
    (column.min(grid.columns - 1), row.min(grid.rows - 1))
}

#[cfg(windows)]
fn on_pointer(hwnd: isize, kind: PointerKind, x: i32, y: i32, wheel: i32) {
    let Some(live) = child(hwnd) else { return };
    let mut live = live.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let (column, row) = cell_at(&live.grid, x, y);
    let tracking = live.grid.mouse != MouseTracking::Off;
    let mods = modifiers();
    match kind {
        PointerKind::LeftDown if !tracking => {
            live.grid.anchor = Some((column, row));
            live.grid.selection = Some(selection(column, row, column, row));
            request_paint(&live);
        }
        PointerKind::Move if !tracking && live.grid.anchor.is_some() => {
            if let Some((anchor_column, anchor_row)) = live.grid.anchor {
                live.grid.selection = Some(selection(anchor_column, anchor_row, column, row));
                request_paint(&live);
            }
        }
        PointerKind::LeftUp if !tracking => live.grid.anchor = None,
        PointerKind::Wheel => {
            let lines = -wheel / 120;
            if lines != 0
                && let Some(session) = &live.session
            {
                let _ = session.wheel(lines, row, column, !tracking);
            }
        }
        PointerKind::LeftDown | PointerKind::LeftUp | PointerKind::Move if tracking => {
            let (button, phase) = match kind {
                PointerKind::LeftDown => (PointerButton::Left, PointerPhase::Press),
                PointerKind::LeftUp => (PointerButton::Left, PointerPhase::Release),
                _ => (PointerButton::None, PointerPhase::Move),
            };
            send_input(
                &live,
                TerminalInput::Pointer { button, phase, column, row, modifiers: mods },
            );
        }
        _ => {}
    }
}

#[cfg(windows)]
fn selection(
    anchor_column: u16,
    anchor_row: u16,
    focus_column: u16,
    focus_row: u16,
) -> SelectionDto {
    SelectionDto {
        anchor_column: anchor_column as u32,
        anchor_row: anchor_row as u32,
        focus_column: focus_column as u32,
        focus_row: focus_row as u32,
    }
}

#[cfg(windows)]
fn request_paint(live: &Live) {
    if let Some(tx) = &live.tx {
        let _ = tx.send(Note::Paint);
    }
}

#[cfg(windows)]
fn child(hwnd: isize) -> Option<Arc<Mutex<Live>>> {
    CHILDREN.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).get(&hwnd).cloned()
}

#[cfg(windows)]
static CHILDREN: std::sync::LazyLock<Mutex<std::collections::HashMap<isize, Arc<Mutex<Live>>>>> =
    std::sync::LazyLock::new(|| Mutex::new(std::collections::HashMap::new()));

#[cfg(windows)]
enum PointerKind {
    LeftDown,
    LeftUp,
    Move,
    Wheel,
}

#[cfg(windows)]
fn point_of(lparam: isize) -> (i32, i32) {
    let x = (lparam as i16) as i32;
    let y = ((lparam >> 16) as i16) as i32;
    (x, y)
}

#[cfg(windows)]
unsafe extern "system" fn wndproc(hwnd: isize, msg: u32, wparam: usize, lparam: isize) -> isize {
    const WM_KEYDOWN: u32 = 0x0100;
    const WM_KEYUP: u32 = 0x0101;
    const WM_CHAR: u32 = 0x0102;
    const WM_SYSKEYDOWN: u32 = 0x0104;
    const WM_SYSKEYUP: u32 = 0x0105;
    const WM_MOUSEMOVE: u32 = 0x0200;
    const WM_LBUTTONDOWN: u32 = 0x0201;
    const WM_LBUTTONUP: u32 = 0x0202;
    const WM_MOUSEWHEEL: u32 = 0x020A;
    const WM_SETFOCUS: u32 = 0x0007;
    match msg {
        WM_KEYDOWN | WM_SYSKEYDOWN => {
            let vk = (wparam & 0xFFFF) as u32;
            track_modifier(vk, true);
            if on_key(hwnd, vk) {
                SKIP_CHAR.store(true, std::sync::atomic::Ordering::Relaxed);
                return 0;
            }
            SKIP_CHAR.store(false, std::sync::atomic::Ordering::Relaxed);
        }
        WM_KEYUP | WM_SYSKEYUP => track_modifier((wparam & 0xFFFF) as u32, false),
        WM_CHAR => {
            if SKIP_CHAR.swap(false, std::sync::atomic::Ordering::Relaxed) {
                return 0;
            }
            if let Some(text) = char::from_u32(wparam as u32) {
                on_char(hwnd, text.to_string());
                return 0;
            }
        }
        WM_LBUTTONDOWN => {
            unsafe { set_capture(hwnd) };
            let (x, y) = point_of(lparam);
            on_pointer(hwnd, PointerKind::LeftDown, x, y, 0);
            return 0;
        }
        WM_LBUTTONUP => {
            unsafe { release_capture() };
            let (x, y) = point_of(lparam);
            on_pointer(hwnd, PointerKind::LeftUp, x, y, 0);
            return 0;
        }
        WM_MOUSEMOVE => {
            let (x, y) = point_of(lparam);
            on_pointer(hwnd, PointerKind::Move, x, y, 0);
            return 0;
        }
        WM_MOUSEWHEEL => {
            let mut point = Point { x: (lparam as i16) as i32, y: ((lparam >> 16) as i16) as i32 };
            unsafe { screen_to_client(hwnd, &mut point) };
            let delta = ((wparam >> 16) & 0xFFFF) as i16 as i32;
            on_pointer(hwnd, PointerKind::Wheel, point.x, point.y, delta);
            return 0;
        }
        WM_SETFOCUS => return 0,
        _ => {}
    }
    unsafe { def_window_proc(hwnd, msg, wparam, lparam) }
}

#[cfg(windows)]
static SKIP_CHAR: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

#[cfg(windows)]
const SWP_NOZORDER: u32 = 0x0004;
#[cfg(windows)]
const SWP_NOREDRAW: u32 = 0x0008;
#[cfg(windows)]
const SWP_NOACTIVATE: u32 = 0x0010;
#[cfg(windows)]
const SWP_NOCOPYBITS: u32 = 0x0100;
#[cfg(windows)]
const SW_HIDE: i32 = 0;
#[cfg(windows)]
const SW_SHOWNA: i32 = 8;

#[cfg(windows)]
#[repr(C)]
struct WndClass {
    style: u32,
    wndproc: Option<unsafe extern "system" fn(isize, u32, usize, isize) -> isize>,
    class_extra: i32,
    window_extra: i32,
    instance: isize,
    icon: isize,
    cursor: isize,
    background: isize,
    menu: *const u16,
    class_name: *const u16,
}

#[cfg(windows)]
#[repr(C)]
struct Point {
    x: i32,
    y: i32,
}

#[cfg(windows)]
unsafe extern "system" {
    fn RegisterClassW(class: *const WndClass) -> u16;
    fn CreateWindowExW(
        ex: u32,
        class: *const u16,
        title: *const u16,
        style: u32,
        x: i32,
        y: i32,
        width: i32,
        height: i32,
        parent: isize,
        menu: isize,
        instance: isize,
        param: *mut core::ffi::c_void,
    ) -> isize;
    fn DefWindowProcW(hwnd: isize, msg: u32, wparam: usize, lparam: isize) -> isize;
    fn DestroyWindow(hwnd: isize) -> i32;
    fn SetWindowPos(
        hwnd: isize,
        after: isize,
        x: i32,
        y: i32,
        width: i32,
        height: i32,
        flags: u32,
    ) -> i32;
    fn ShowWindow(hwnd: isize, cmd: i32) -> i32;
    fn SetFocus(hwnd: isize) -> isize;
    fn SetCapture(hwnd: isize) -> isize;
    fn ReleaseCapture() -> i32;
    fn GetKeyState(vk: i32) -> i16;
    fn GetParent(hwnd: isize) -> isize;
    fn GetForegroundWindow() -> isize;
    fn PostMessageW(hwnd: isize, msg: u32, wparam: usize, lparam: isize) -> i32;
    fn ScreenToClient(hwnd: isize, point: *mut Point) -> i32;
    fn LoadCursorW(instance: isize, cursor: usize) -> isize;
    fn GetModuleHandleW(name: *const u16) -> isize;
}

#[cfg(windows)]
fn class_name() -> &'static [u16] {
    static NAME: std::sync::OnceLock<Vec<u16>> = std::sync::OnceLock::new();
    NAME.get_or_init(|| "TetherDesktopTerminal\0".encode_utf16().collect())
}

#[cfg(windows)]
unsafe fn create_child(parent: isize, width: u32, height: u32) -> Option<isize> {
    static REGISTERED: std::sync::Once = std::sync::Once::new();
    REGISTERED.call_once(|| {
        let class = WndClass {
            style: 0,
            wndproc: Some(wndproc),
            class_extra: 0,
            window_extra: 0,
            instance: unsafe { GetModuleHandleW(std::ptr::null()) },
            icon: 0,
            cursor: unsafe { LoadCursorW(0, 32513) },
            background: 0,
            menu: std::ptr::null(),
            class_name: class_name().as_ptr(),
        };
        unsafe { RegisterClassW(&class) };
    });
    let style = 0x4000_0000 | 0x1000_0000 | 0x0400_0000 | 0x0200_0000;
    let hwnd = unsafe {
        CreateWindowExW(
            0,
            class_name().as_ptr(),
            std::ptr::null(),
            style,
            0,
            0,
            width as i32,
            height as i32,
            parent,
            0,
            GetModuleHandleW(std::ptr::null()),
            std::ptr::null_mut(),
        )
    };
    (hwnd != 0).then_some(hwnd)
}

#[cfg(windows)]
unsafe fn set_window_pos(hwnd: isize, x: i32, y: i32, width: i32, height: i32, flags: u32) {
    unsafe { SetWindowPos(hwnd, 0, x, y, width, height, flags) };
}

#[cfg(windows)]
unsafe fn show_window(hwnd: isize, cmd: i32) {
    unsafe { ShowWindow(hwnd, cmd) };
}

#[cfg(windows)]
unsafe fn set_focus(hwnd: isize) {
    unsafe { SetFocus(hwnd) };
}

#[cfg(windows)]
unsafe fn set_capture(hwnd: isize) {
    unsafe { SetCapture(hwnd) };
}

#[cfg(windows)]
unsafe fn release_capture() {
    unsafe { ReleaseCapture() };
}

#[cfg(windows)]
unsafe fn get_key_state(vk: i32) -> i16 {
    unsafe { GetKeyState(vk) }
}

#[cfg(windows)]
unsafe fn get_parent(hwnd: isize) -> isize {
    unsafe { GetParent(hwnd) }
}

#[cfg(windows)]
unsafe fn get_foreground_window() -> isize {
    unsafe { GetForegroundWindow() }
}

#[cfg(windows)]
unsafe fn wake(hwnd: isize) {
    let parent = unsafe { get_parent(hwnd) };
    if parent != 0 {
        // A paint alone does not re-run the view. F24 is not a binding;
        // delivering it makes GPUI take the queued chord.
        unsafe { PostMessageW(parent, 0x0100, 0x87, 0) };
        unsafe { PostMessageW(parent, 0x0101, 0x87, 0) };
    }
}

#[cfg(windows)]
unsafe fn screen_to_client(hwnd: isize, point: &mut Point) {
    unsafe { ScreenToClient(hwnd, point) };
}

#[cfg(windows)]
unsafe fn def_window_proc(hwnd: isize, msg: u32, wparam: usize, lparam: isize) -> isize {
    unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) }
}

#[cfg(windows)]
unsafe fn destroy_window(hwnd: isize) {
    unsafe { DestroyWindow(hwnd) };
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn workspace_chords_are_taken_before_the_shell() {
        assert_eq!(
            shortcut_for(0x54, true, true, false),
            Some(HostCommand::Workspace(Command::NewTab))
        );
        assert_eq!(
            shortcut_for(0x4E, true, false, false),
            Some(HostCommand::Workspace(Command::NewTab))
        );
        assert_eq!(
            shortcut_for(0x57, true, false, false),
            Some(HostCommand::Workspace(Command::CloseTab))
        );
        assert_eq!(
            shortcut_for(0x73, true, false, false),
            Some(HostCommand::Workspace(Command::CloseTab))
        );
        assert_eq!(shortcut_for(0x50, false, true, true), Some(HostCommand::Palette));
        assert_eq!(
            shortcut_for(0x44, true, true, false),
            Some(HostCommand::Workspace(Command::SplitRight))
        );
        assert_eq!(
            shortcut_for(0x45, true, true, false),
            Some(HostCommand::Workspace(Command::SplitDown))
        );
        assert_eq!(
            shortcut_for(0x21, true, false, false),
            Some(HostCommand::Workspace(Command::PreviousTab))
        );
        assert_eq!(
            shortcut_for(0x22, true, false, false),
            Some(HostCommand::Workspace(Command::NextTab))
        );
        assert_eq!(shortcut_for(0x21, false, false, false), None);
        assert_eq!(shortcut_for(0x43, true, false, false), None);
    }

    #[cfg(windows)]
    #[test]
    fn a_one_pixel_edge_flip_keeps_the_previous_rectangle() {
        let host = host();
        assert_eq!(hold_edges(&host.inner, 10, 20, 100, 80), (10, 20, 100, 80));
        assert_eq!(hold_edges(&host.inner, 11, 20, 99, 81), (10, 20, 100, 80));
        assert_eq!(hold_edges(&host.inner, 14, 20, 100, 80), (14, 20, 100, 80));
    }
}
