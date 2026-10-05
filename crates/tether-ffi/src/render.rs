//! The render seam, for a consumer that draws with `tether-render`.
//!
//! Feature-gated behind `render` so the Apple XCFramework stays free of a GPU
//! stack until Decisions/0006's triggers fire. A Windows host enables it and
//! gets session *and* draw out of one DLL (Decisions/0017).
//!
//! The window is a pointer-sized `hwnd`, never a UI toolkit type (spec §8).
//! The frame is the same `ScreenFrame` a session returns — one contract.

use std::sync::{Arc, Mutex};

use tether_render::{
    Cell, CellSpan, DrawList, FontMetrics, Frame, LinkUnderline, Overlay, Palette, RenderError,
    Rgba, SurfaceSize, TerminalRenderer, prepare_with_overlay,
};

use crate::screen::ScreenFrame;

/// Errors are ours: a backend error number is diagnostic context, never the
/// public API (spec §18).
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum RenderFailure {
    #[error("no suitable GPU adapter")]
    NoAdapter,
    #[error("no suitable GPU device: {cause}")]
    NoDevice { cause: String },
    #[error("surface: {cause}")]
    Surface { cause: String },
}

impl From<RenderError> for RenderFailure {
    fn from(error: RenderError) -> Self {
        match error {
            RenderError::NoAdapter => Self::NoAdapter,
            RenderError::NoDevice(cause) => Self::NoDevice { cause },
            RenderError::Surface(cause) => Self::Surface { cause },
        }
    }
}

/// A GPU terminal surface.
///
/// Toolkit-free at the boundary: it takes a window handle and a
/// [`ScreenFrame`], and paints. A consumer that wants to draw differently
/// takes [`prepare`] and does its own pass.
#[derive(uniffi::Object)]
pub struct RenderSurface {
    inner: Mutex<Option<TerminalRenderer>>,
    /// The size last asked of [`RenderSurface::measure`]. The consumer lays
    /// its grid out from that measurement, so drawing at any other size puts
    /// the caret and the pointer in different cells from the text.
    font_size: Mutex<f32>,
}

/// What a surface draws at until a consumer measures something else.
const DEFAULT_FONT_SIZE: f32 = 13.0;

#[uniffi::export]
impl RenderSurface {
    /// Creates a surface for a Win32 `HWND`.
    ///
    /// # Safety contract
    ///
    /// The window must outlive this surface. `hwnd` is what a WinUI host gets
    /// from `WindowNative.GetWindowHandle`; it is not a toolkit type here.
    #[uniffi::constructor]
    pub async fn from_hwnd(hwnd: u64, width: u32, height: u32) -> Result<Arc<Self>, RenderFailure> {
        let instance = wgpu_instance();
        let size = SurfaceSize { width, height };
        // SAFETY: the caller keeps the window alive for the surface's life.
        let renderer = unsafe { TerminalRenderer::from_hwnd(&instance, hwnd as isize, size) }
            .await
            .map_err(RenderFailure::from)?;
        Ok(Arc::new(Self {
            inner: Mutex::new(Some(renderer)),
            font_size: Mutex::new(DEFAULT_FONT_SIZE),
        }))
    }

    pub fn set_fonts(&self, primary: String, wide: String) {
        if let Ok(mut guard) = self.inner.lock() {
            if let Some(renderer) = guard.as_mut() {
                renderer.set_fonts(primary, wide);
            }
        }
    }

    pub fn resize(&self, width: u32, height: u32) {
        if let Ok(mut guard) = self.inner.lock() {
            if let Some(renderer) = guard.as_mut() {
                renderer.resize(SurfaceSize { width, height });
            }
        }
    }

    /// Measures the monospaced face this surface will draw with.
    pub fn measure(&self, size: f32) -> FontMetricsDto {
        if let Ok(mut font_size) = self.font_size.lock() {
            *font_size = size;
        }
        let mut guard = self.inner.lock().expect("renderer lock");
        let renderer = guard.as_mut().expect("renderer alive");
        let metrics = renderer.measure(size);
        let (narrow, wide) = metrics.advances();
        FontMetricsDto {
            size: metrics.size,
            cell_width: metrics.cell_width,
            line_height: metrics.line_height,
            narrow_advance: narrow,
            wide_advance: wide,
        }
    }

    /// Draws one frame with the consumer's palette and whatever the pointer
    /// is doing (selection, link underlines — spec §14, Decisions/0015).
    pub fn draw(
        &self,
        frame: ScreenFrame,
        palette: PaletteDto,
        overlay: Option<OverlayDto>,
    ) -> Result<(), RenderFailure> {
        let mut guard = self.inner.lock().expect("renderer lock");
        let renderer = guard.as_mut().expect("renderer alive");
        let size = self.font_size.lock().map(|size| *size).unwrap_or(DEFAULT_FONT_SIZE);
        let metrics = {
            let measured = renderer.measure(size);
            FontMetrics::from_advances(
                measured.size,
                measured.advances().0,
                measured.advances().1,
                measured.line_height,
            )
        };
        let overlay = overlay.map(Overlay::from).unwrap_or_default();
        let list: DrawList =
            prepare_with_overlay(&Frame::from(frame), &metrics, &Palette::from(palette), &overlay);
        renderer.render(&list).map_err(RenderFailure::from)
    }
}

/// What the pointer is doing, in the shape the frontend contract already
/// carries (spec §14: selection) plus the link underlines of Decisions/0015.
#[derive(Debug, Clone, uniffi::Record)]
pub struct OverlayDto {
    /// Anchor and focus of a drag, as `(column, row)` pairs.
    pub selection: Option<SelectionDto>,
    pub link_underlines: Vec<LinkUnderlineDto>,
    /// What to tint a selected cell with. `TetherUI` uses accent at 0.12.
    pub selection_color: RgbaDto,
    /// What to underline a link with.
    pub link_color: RgbaDto,
}

#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct SelectionDto {
    pub anchor_column: u32,
    pub anchor_row: u32,
    pub focus_column: u32,
    pub focus_row: u32,
}

/// One underline under a hovered link. A wrapped link is several of these
/// (Decisions/0015).
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct LinkUnderlineDto {
    pub row: u32,
    /// First column, inclusive.
    pub start: u32,
    /// One past the last column.
    pub end: u32,
    /// Solid once the host says the thing exists; dotted while it asks.
    pub confirmed: bool,
}

/// The monospaced geometry a frontend lays out against.
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct FontMetricsDto {
    pub size: f32,
    pub cell_width: f32,
    pub line_height: f32,
    pub narrow_advance: f32,
    pub wide_advance: f32,
}

/// The palette, in the form the renderer draws (Decision 0011).
///
/// Deliberately parallel to `TerminalPalette`: one is what the far side is
/// told, one is what is drawn. A consumer that keeps them in step (the
/// `Palette.chosen` discipline) cannot disagree with itself.
#[derive(Debug, Clone, uniffi::Record)]
pub struct PaletteDto {
    pub background: RgbaDto,
    pub foreground: RgbaDto,
    pub cursor: RgbaDto,
    pub ansi: Vec<RgbaDto>,
}

#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct RgbaDto {
    pub red: f32,
    pub green: f32,
    pub blue: f32,
    pub alpha: f32,
}

fn wgpu_instance() -> wgpu::Instance {
    let mut descriptor = wgpu::InstanceDescriptor::new_without_display_handle();
    descriptor.backends =
        wgpu::Backends::from_env().unwrap_or(wgpu::Backends::VULKAN | wgpu::Backends::GL);
    wgpu::Instance::new(descriptor)
}

impl From<ScreenFrame> for Frame {
    fn from(frame: ScreenFrame) -> Self {
        Frame {
            columns: frame.columns,
            rows: frame.rows,
            cursor_row: frame.cursor_row,
            cursor_column: frame.cursor_column,
            cursor_shape: match frame.cursor_shape {
                crate::screen::CaretShape::Block => tether_render::Caret::Block,
                crate::screen::CaretShape::Underline => tether_render::Caret::Underline,
                crate::screen::CaretShape::Beam => tether_render::Caret::Beam,
                crate::screen::CaretShape::Hidden => tether_render::Caret::Hidden,
            },
            cursor_visible: frame.cursor_visible,
            alternate_screen: frame.alternate_screen,
            viewport_offset: frame.viewport_offset,
            history_lines: frame.history_lines,
            title: frame.title,
            lines: frame
                .lines
                .into_iter()
                .map(|row| tether_render::Row {
                    runs: row
                        .runs
                        .into_iter()
                        .map(|run| tether_render::Run {
                            text: run.text,
                            columns: run.columns,
                            style: tether_render::RunStyle {
                                foreground: paint(run.style.foreground),
                                background: paint(run.style.background),
                                underline: underline(run.style.underline),
                                underline_color: run.style.underline_color.map(paint),
                                bold: run.style.bold,
                                dim: run.style.dim,
                                italic: run.style.italic,
                                strikethrough: run.style.strikethrough,
                                inverse: run.style.inverse,
                                hidden: run.style.hidden,
                            },
                        })
                        .collect(),
                })
                .collect(),
        }
    }
}

fn paint(color: crate::screen::CellColor) -> tether_render::Paint {
    use crate::screen::CellColor;
    match color {
        CellColor::Named { name } => tether_render::Paint::Named(name_of(name)),
        CellColor::Indexed { index } => tether_render::Paint::Indexed(index),
        CellColor::Rgb { red, green, blue } => tether_render::Paint::Rgb { red, green, blue },
    }
}

fn name_of(name: crate::screen::ColorName) -> tether_render::Name {
    use crate::screen::ColorName;
    match name {
        ColorName::Black => tether_render::Name::Black,
        ColorName::Red => tether_render::Name::Red,
        ColorName::Green => tether_render::Name::Green,
        ColorName::Yellow => tether_render::Name::Yellow,
        ColorName::Blue => tether_render::Name::Blue,
        ColorName::Magenta => tether_render::Name::Magenta,
        ColorName::Cyan => tether_render::Name::Cyan,
        ColorName::White => tether_render::Name::White,
        ColorName::BrightBlack => tether_render::Name::BrightBlack,
        ColorName::BrightRed => tether_render::Name::BrightRed,
        ColorName::BrightGreen => tether_render::Name::BrightGreen,
        ColorName::BrightYellow => tether_render::Name::BrightYellow,
        ColorName::BrightBlue => tether_render::Name::BrightBlue,
        ColorName::BrightMagenta => tether_render::Name::BrightMagenta,
        ColorName::BrightCyan => tether_render::Name::BrightCyan,
        ColorName::BrightWhite => tether_render::Name::BrightWhite,
        ColorName::Foreground => tether_render::Name::Foreground,
        ColorName::Background => tether_render::Name::Background,
        ColorName::Cursor => tether_render::Name::Cursor,
    }
}

fn underline(value: crate::screen::UnderlineStyle) -> tether_render::Underline {
    use crate::screen::UnderlineStyle;
    match value {
        UnderlineStyle::None => tether_render::Underline::None,
        UnderlineStyle::Single => tether_render::Underline::Single,
        UnderlineStyle::Double => tether_render::Underline::Double,
        UnderlineStyle::Curly => tether_render::Underline::Curly,
        UnderlineStyle::Dotted => tether_render::Underline::Dotted,
        UnderlineStyle::Dashed => tether_render::Underline::Dashed,
    }
}

impl From<PaletteDto> for Palette {
    fn from(palette: PaletteDto) -> Self {
        let ansi: Vec<_> = palette.ansi.into_iter().map(rgba).collect();
        let mut normal = [Rgba::default(); 8];
        let mut bright = [Rgba::default(); 8];
        for (index, color) in ansi.iter().enumerate().take(16) {
            if index < 8 {
                normal[index] = *color;
            } else {
                bright[index - 8] = *color;
            }
        }
        Palette {
            background: rgba(palette.background),
            foreground: rgba(palette.foreground),
            cursor: rgba(palette.cursor),
            normal,
            bright,
        }
    }
}

impl From<OverlayDto> for Overlay {
    fn from(overlay: OverlayDto) -> Self {
        Overlay {
            selection: overlay.selection.map(|s| {
                (
                    Cell { column: s.anchor_column, row: s.anchor_row },
                    Cell { column: s.focus_column, row: s.focus_row },
                )
            }),
            link_underlines: overlay
                .link_underlines
                .into_iter()
                .map(|u| LinkUnderline {
                    span: CellSpan { row: u.row, start: u.start, end: u.end },
                    confirmed: u.confirmed,
                })
                .collect(),
            selection_color: rgba(overlay.selection_color),
            link_color: rgba(overlay.link_color),
        }
    }
}

fn rgba(value: RgbaDto) -> Rgba {
    Rgba::new(value.red, value.green, value.blue, value.alpha)
}

/// Installed family names, as seen by the same shaper that draws the terminal.
#[uniffi::export]
pub fn render_font_families() -> Vec<String> {
    tether_render::font_families()
}
