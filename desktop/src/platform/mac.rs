//! The terminal's child surface on a Mac, and the window frame fix.
//!
//! The surface is a `CAMetalLayer` added as a sublayer of GPUI's own layer.
//! A layer takes no events, so keys and the pointer still reach GPUI, and
//! the layer sits above GPUI's drawing only inside the terminal rect, which
//! the chrome leaves empty.

use objc2::rc::Retained;
use objc2::{MainThreadMarker, msg_send};
use objc2_app_kit::{NSApplication, NSScreen, NSView, NSWindowCollectionBehavior};
use objc2_core_foundation::{CGPoint, CGRect, CGSize};
use objc2_foundation::{NSPoint, NSRect, NSSize};
use objc2_quartz_core::{CALayer, CAMetalLayer, CATransaction};
use raw_window_handle::{HasWindowHandle, RawWindowHandle};
use tether_ui::{Chrome, Rect};

pub struct TerminalLayer {
    layer: Retained<CAMetalLayer>,
    parent: Retained<CALayer>,
}

impl TerminalLayer {
    /// Main thread only, which is where GPUI calls render.
    pub fn attach(window: &gpui::Window) -> Result<Self, String> {
        MainThreadMarker::new().ok_or("terminal layer off the main thread")?;
        let handle = HasWindowHandle::window_handle(window).map_err(|error| error.to_string())?;
        let RawWindowHandle::AppKit(appkit) = handle.as_raw() else {
            return Err("not an AppKit window".to_owned());
        };
        // SAFETY: GPUI hands out its live content view for as long as the window exists.
        let view: &NSView = unsafe { appkit.ns_view.cast().as_ref() };
        let parent = view.layer().ok_or("GPUI view has no layer")?;
        let layer = CAMetalLayer::new();
        layer.setOpaque(true);
        layer.setHidden(true);
        parent.addSublayer(&layer);
        Ok(Self { layer, parent })
    }

    /// The `CAMetalLayer` pointer `RenderSurface::from_metal_layer` takes.
    /// Retained here until this value drops, after the surface is closed.
    pub fn handle(&self) -> u64 {
        Retained::as_ptr(&self.layer) as u64
    }

    /// `rect` is in points from the top left of the content view.
    pub fn place(&self, rect: Rect, scale: f32, visible: bool) {
        let bounds = self.parent.bounds();
        let y = if self.parent.isGeometryFlipped() {
            rect.y as f64
        } else {
            bounds.size.height - (rect.y + rect.height) as f64
        };
        let frame = CGRect::new(
            CGPoint::new(rect.x as f64, y),
            CGSize::new(rect.width as f64, rect.height as f64),
        );
        CATransaction::begin();
        // A layer animates every property change by default; the terminal should not slide.
        CATransaction::setDisableActions(true);
        self.layer.setFrame(frame);
        self.layer.setContentsScale(scale as f64);
        self.layer.setHidden(!visible || rect.width <= 0.0 || rect.height <= 0.0);
        CATransaction::commit();
    }
    pub fn hide(&self) {
        CATransaction::begin();
        CATransaction::setDisableActions(true);
        self.layer.setHidden(true);
        CATransaction::commit();
    }
}

impl Drop for TerminalLayer {
    fn drop(&mut self) {
        self.layer.removeFromSuperlayer();
    }
}

/// Puts the window on the menu-bar display at the workspace size.
///
/// GPUI's first server window for an unbundled binary is a ~100pt sliver,
/// and `setFrame` updates `NSWindow.frame` without replacing it. Ordering
/// out drops the server window; the next order-front makes one from the
/// frame set here. AppKit applies the saved sliver again at the end of
/// finish-launching, so the caller runs this after launch as well.
pub fn place_window(title: &str) {
    let Some(marker) = MainThreadMarker::new() else {
        return;
    };
    let screens = NSScreen::screens(marker);
    if screens.count() == 0 {
        return;
    }
    // `NSScreen.screens` starts with the menu-bar display; `mainScreen` follows the key window.
    let visible = screens.objectAtIndex(0).visibleFrame();
    let width = Chrome::WINDOW_WIDTH as f64;
    let height = Chrome::WINDOW_HEIGHT as f64;
    let frame = NSRect::new(
        NSPoint::new(
            visible.origin.x + (visible.size.width - width).max(0.0) / 2.0,
            visible.origin.y + (visible.size.height - height).max(0.0) / 2.0,
        ),
        NSSize::new(width, height),
    );
    let app = NSApplication::sharedApplication(marker);
    for window in app.windows().iter() {
        if window.title().to_string() != title {
            continue;
        }
        window.setRestorable(false);
        window.orderOut(None);
        window.setFrame_display(frame, true);
        // Open on the Space the person is looking at, a full-screen one
        // included, and only once the frame is the workspace size: joining
        // first left the window off that Space. GPUI draws nothing for a
        // window on another Space, so a window left there shows no terminal.
        window.setCollectionBehavior(
            NSWindowCollectionBehavior::MoveToActiveSpace
                | NSWindowCollectionBehavior::FullScreenAuxiliary,
        );
        // KNOWN ISSUE: with another app's full-screen Space on one display
        // and the last real mouse event on the other, the window server
        // bounces an activating window to the other display, clamps it to a
        // ~100pt sliver, and does not tell AppKit (`frame` still reads the
        // workspace size; only CGWindowList sees it). The Mac app beat the
        // same rule with a non-activating `NSPanel` (`WorkspaceWindow`).
        // GPUI makes its own NSWindow, so until P6 brings the panel here the
        // floating level is what keeps the window where it was put, and the
        // window floats. Going back to the normal level re-bounces it.
        window.setLevel(objc2_app_kit::NSFloatingWindowLevel);
        window.setFrame_display(frame, true);
        window.makeKeyAndOrderFront(None);
    }
    app.unhideWithoutActivation();
    // `activateIgnoringOtherApps` is ignored from macOS 14; `activate` still
    // brings an unbundled window forward.
    let _: () = unsafe { msg_send![&app, activate] };
}

/// The program in front of a local shell (`LocalForeground.command`).
/// `None` while the prompt waits, or when the process table cannot say.
pub fn foreground_command(shell: Option<u32>) -> Option<String> {
    let shell_pid = shell?;
    let info = process(shell_pid)?;
    let group = if info.pbi_pgid == 0 { shell_pid } else { info.pbi_pgid };
    let leader = process(info.e_tpgid).map(|leader| name(&leader));
    tether_desktop::foreground::picked(group, info.e_tpgid, leader.as_deref())
}

fn process(pid: u32) -> Option<libc::proc_bsdinfo> {
    if pid == 0 {
        return None;
    }
    let mut info = std::mem::MaybeUninit::<libc::proc_bsdinfo>::zeroed();
    let size = std::mem::size_of::<libc::proc_bsdinfo>() as i32;
    // SAFETY: `info` is a writable buffer of exactly `size` bytes.
    let wrote = unsafe {
        libc::proc_pidinfo(pid as i32, libc::PROC_PIDTBSDINFO, 0, info.as_mut_ptr().cast(), size)
    };
    // SAFETY: a full-size write initialised the struct.
    (wrote == size).then(|| unsafe { info.assume_init() })
}

/// The registered name, or the command name when there is none.
fn name(info: &libc::proc_bsdinfo) -> String {
    let text = |bytes: &[libc::c_char]| {
        let bytes: Vec<u8> = bytes.iter().take_while(|&&c| c != 0).map(|&c| c as u8).collect();
        String::from_utf8_lossy(&bytes).into_owned()
    };
    let registered = text(&info.pbi_name);
    if registered.is_empty() { text(&info.pbi_comm) } else { registered }
}
