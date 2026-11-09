//! A platform this host does not attach a terminal on yet. Windows takes a
//! child HWND (`app-win/ChildHwnd.cs` is the reference); until it lands the
//! chrome runs and the terminal rect stays empty.

pub struct TerminalLayer;

impl TerminalLayer {
    pub fn attach(_window: &gpui::Window) -> Result<Self, String> {
        Err("no terminal surface on this platform yet".to_owned())
    }

    pub fn handle(&self) -> u64 {
        0
    }

    pub fn place(&self, _rect: tether_ui::Rect, _scale: f32, _visible: bool) {}
    pub fn hide(&self) {}
}

pub fn place_window(_title: &str) {}

/// No process table read here yet; a chip falls back to the directory.
pub fn foreground_command(_shell: Option<u32>) -> Option<String> {
    None
}
