//! One terminal: its session, its child surface, and the grid that fits it.
//!
//! The order is the Swift `TerminalGPUView`'s: capture the layer on the main
//! thread, initialize the device asynchronously, then measure, fit and draw.
//! Sizes handed to the renderer are physical pixels.

use std::sync::Arc;

use tether_ffi::{FontMetricsDto, PaletteDto, RenderSurface, RgbaDto, Session};
use tether_ui::{Chrome, Rect};

use crate::platform::TerminalLayer;

/// `terminalFontSize`'s default on a Mac, in points.
const FONT_POINTS: f32 = 13.0;
const MAX_COLUMNS: f32 = 1000.0;
const MAX_ROWS: f32 = 500.0;

pub struct Pane {
    pub session: Arc<Session>,
    layer: TerminalLayer,
    surface: Option<Arc<RenderSurface>>,
    starting: bool,
    metrics: Option<FontMetricsDto>,
    pixels: (u32, u32),
    scale: f32,
    grid: (u16, u16),
    rect: Rect,
    /// Wheel travel short of a whole line, carried to the next event.
    carried: f32,
    /// The program in front of the shell, and the directory the shell
    /// reported: what the chip is named from (`refreshLabels`).
    pub command: Option<String>,
    pub directory: Option<String>,
}

impl Pane {
    pub fn new(session: Arc<Session>, layer: TerminalLayer) -> Self {
        Self {
            session,
            layer,
            surface: None,
            starting: false,
            metrics: None,
            pixels: (0, 0),
            scale: 1.0,
            grid: (0, 0),
            rect: Rect { x: 0.0, y: 0.0, width: 0.0, height: 0.0 },
            carried: 0.0,
            command: None,
            directory: None,
        }
    }

    /// Lays the surface over `rect`. Returns a surface to initialize the
    /// first time the pane has a size; the caller awaits it and hands it to
    /// [`Pane::ready`].
    pub fn place(&mut self, rect: Rect, scale: f32, visible: bool) -> Option<Arc<RenderSurface>> {
        self.layer.place(rect, scale, visible);
        self.scale = scale;
        self.rect = rect;
        let pixels = ((rect.width * scale).round() as u32, (rect.height * scale).round() as u32);
        if pixels.0 == 0 || pixels.1 == 0 {
            return None;
        }
        let resized = pixels != self.pixels;
        self.pixels = pixels;
        if let Some(surface) = &self.surface {
            if resized {
                surface.resize(pixels.0, pixels.1);
                self.fit();
                // Redraw at the new size now; the session's own change follows.
                self.draw();
            }
            return None;
        }
        if self.starting {
            return None;
        }
        match RenderSurface::from_metal_layer(self.layer.handle()) {
            Ok(surface) => {
                self.starting = true;
                Some(surface)
            }
            Err(error) => {
                eprintln!("tether-desktop: terminal surface: {error}");
                None
            }
        }
    }

    /// Another tab is showing. The surface keeps its size.
    pub fn hide(&self) {
        self.layer.hide();
    }

    pub fn pixels(&self) -> (u32, u32) {
        self.pixels
    }

    /// The surface finished initializing.
    pub fn ready(&mut self, surface: Arc<RenderSurface>) {
        self.starting = false;
        surface.set_grid_padding(Chrome::SPACE_INSET * self.scale);
        surface.resize(self.pixels.0, self.pixels.1);
        match surface.measure(self.font_pixels()) {
            Ok(metrics) => self.metrics = Some(metrics),
            Err(error) => eprintln!("tether-desktop: measure: {error}"),
        }
        self.surface = Some(surface);
        self.fit();
    }

    pub fn failed(&mut self) {
        self.starting = false;
    }

    /// A terminal row in points, which a precise (trackpad) delta is divided by.
    pub fn line_points(&self) -> Option<f32> {
        let line = self.metrics.as_ref()?.line_height / self.scale;
        (line > 0.0).then_some(line)
    }

    /// Wheel travel in rows, positive toward history as AppKit gives it.
    /// Whole lines only, carrying the rest, as `KeyCaptureMac.scrollWheel`;
    /// the engine sends them to the far side's mouse protocol or scrolls this
    /// side's history. `local` (Shift) always scrolls history.
    pub fn wheel(&mut self, rows: f32, x: f32, y: f32, local: bool) {
        if self.metrics.is_none() || !rows.is_finite() {
            return;
        }
        self.carried += rows;
        let lines = self.carried.trunc();
        if lines == 0.0 {
            return;
        }
        self.carried -= lines;
        let (row, column) = self.cell_at(x, y);
        // The engine's positive is toward the live screen; AppKit's is toward history.
        if let Err(error) = self.session.wheel(-(lines as i32), row, column, local) {
            eprintln!("tether-desktop: wheel: {error}");
        }
    }

    /// The cell under a window point, clamped to the grid. The renderer
    /// centres the grid across the width and rests it on the bottom edge.
    fn cell_at(&self, x: f32, y: f32) -> (u16, u16) {
        let Some(metrics) = &self.metrics else { return (0, 0) };
        let (columns, rows) = self.grid;
        let left = (self.pixels.0 as f32 - f32::from(columns) * metrics.cell_width) / 2.0;
        let top = self.pixels.1 as f32 - f32::from(rows) * metrics.line_height;
        let px = (x - self.rect.x) * self.scale - left;
        let py = (y - self.rect.y) * self.scale - top;
        let column = (px / metrics.cell_width).floor().clamp(0.0, f32::from(columns.max(1) - 1));
        let row = (py / metrics.line_height).floor().clamp(0.0, f32::from(rows.max(1) - 1));
        (row as u16, column as u16)
    }

    /// Reads what the chip is named from. True when it changed.
    pub fn refresh_labels(&mut self) -> bool {
        let command = crate::platform::foreground_command(self.session.local_process_id());
        let directory = self.session.working_directory();
        let changed = command != self.command || directory != self.directory;
        self.command = command;
        self.directory = directory;
        changed
    }

    /// Draws the session's current screen.
    pub fn draw(&mut self) {
        let Some(surface) = self.surface.as_ref() else { return };
        let frame = self.session.frame();
        match surface.draw_update(frame, soft_dark(), None, self.font_pixels(), None) {
            // A skipped acquire keeps nothing back: the next change draws the whole screen.
            Ok(_) => {}
            Err(error) => eprintln!("tether-desktop: draw: {error}"),
        }
    }

    pub fn close(&mut self) {
        if let Some(surface) = self.surface.take() {
            surface.close();
        }
        self.session.close();
    }

    fn font_pixels(&self) -> f32 {
        FONT_POINTS * self.scale
    }

    /// Columns across what the side margins leave; rows down the whole
    /// height, so the last row meets the status bar.
    fn fit(&mut self) {
        let Some(metrics) = &self.metrics else { return };
        let margin = Chrome::SPACE_INSET * self.scale * 2.0;
        let columns = fitted(self.pixels.0 as f32 - margin, metrics.cell_width, MAX_COLUMNS);
        let rows = fitted(self.pixels.1 as f32, metrics.line_height, MAX_ROWS);
        if (columns, rows) == self.grid {
            return;
        }
        self.grid = (columns, rows);
        if let Err(error) = self.session.resize(columns, rows) {
            eprintln!("tether-desktop: resize: {error}");
        }
    }
}

fn fitted(extent: f32, pitch: f32, cap: f32) -> u16 {
    if pitch <= 0.0 || !extent.is_finite() {
        return 1;
    }
    (extent / pitch).floor().clamp(1.0, cap) as u16
}

/// `Palette.softDark`, the Mac default. Settings choose a theme later.
fn soft_dark() -> PaletteDto {
    const NORMAL: [u32; 8] =
        [0x353D4B, 0xE58C91, 0xA3C99C, 0xEBCB8B, 0x8DB4E2, 0xC5A0D8, 0x88C6CA, 0xCBD3DF];
    const BRIGHT: [u32; 8] =
        [0x758298, 0xF0A5AA, 0xB9DBB3, 0xF5DAA2, 0xACCBEE, 0xDBBCE9, 0xA5DBDF, 0xEEF2F8];
    PaletteDto {
        background: srgb(0x171B22),
        foreground: srgb(0xD8DEE9),
        cursor: srgb(0xD8DEE9),
        ansi: NORMAL.iter().chain(BRIGHT.iter()).map(|&hex| srgb(hex)).collect(),
    }
}

fn srgb(hex: u32) -> RgbaDto {
    let channel = |shift: u32| ((hex >> shift) & 0xFF) as f32 / 255.0;
    RgbaDto { red: channel(16), green: channel(8), blue: channel(0), alpha: 1.0 }
}
