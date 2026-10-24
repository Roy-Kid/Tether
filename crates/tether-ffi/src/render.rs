//! The render seam, for a consumer that draws with `tether-render`.
//!
//! Feature-gated behind `render`; native Windows and Apple artifacts enable
//! this same renderer. Headless consumers can continue omitting it.
//!
//! The window is a pointer-sized `hwnd`, never a UI toolkit type (spec §8).
//! The frame is the same `ScreenFrame` a session returns — one contract.

use std::sync::{
    Arc, Mutex,
    atomic::{AtomicBool, Ordering},
};

use tether_render::{
    Cell, CellSpan, Frame, LinkUnderline, Overlay, Palette, RenderError, Rgba, SurfaceSize,
    TerminalRenderer,
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
    #[error("font: {cause}")]
    Font { cause: String },
}

impl From<RenderError> for RenderFailure {
    fn from(error: RenderError) -> Self {
        match error {
            RenderError::NoAdapter => Self::NoAdapter,
            RenderError::NoDevice(cause) => Self::NoDevice { cause },
            RenderError::Surface(cause) => Self::Surface { cause },
            RenderError::Font(cause) => Self::Font { cause },
        }
    }
}

/// A GPU terminal surface.
///
/// Toolkit-free at the boundary: it takes a window handle and a
/// [`ScreenFrame`], and paints.
struct Deferred {
    fonts: Option<(String, String)>,
    size: Option<(u32, u32)>,
}

#[derive(uniffi::Object)]
pub struct RenderSurface {
    inner: Mutex<Option<TerminalRenderer>>,
    attachment: Mutex<Option<tether_render::NativeAttachment>>,
    closed: AtomicBool,
    /// The size last asked of [`RenderSurface::measure`] or [`RenderSurface::draw`].
    /// Legacy [`RenderSurface::draw`] uses it. [`RenderSurface::draw_update`] takes
    /// the physical size for that frame explicitly.
    font_size: Mutex<f32>,
    /// Fonts and size asked for before the renderer exists. Applied when
    /// `initialize` stores it, so an early call is not dropped.
    deferred: Mutex<Deferred>,
    /// See [`RenderSurface::set_cell_background_opacity`].
    cell_background_opacity: Mutex<f32>,
    /// See [`RenderSurface::set_grid_padding`].
    grid_padding: Mutex<Option<f32>>,
}

fn apply_deferred(renderer: &mut TerminalRenderer, deferred: &Deferred) {
    if let Some((primary, wide)) = &deferred.fonts {
        renderer.set_fonts(primary.clone(), wide.clone());
    }
    if let Some((width, height)) = deferred.size {
        renderer.resize(SurfaceSize { width, height });
    }
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
        let size = SurfaceSize { width, height };
        // SAFETY: the caller keeps the window alive for the surface's life.
        let renderer = unsafe { TerminalRenderer::attach_hwnd(hwnd as isize, size) }
            .await
            .map_err(RenderFailure::from)?;
        Ok(Arc::new(Self {
            inner: Mutex::new(Some(renderer)),
            attachment: Mutex::new(None),
            closed: AtomicBool::new(false),
            font_size: Mutex::new(DEFAULT_FONT_SIZE),
            deferred: Mutex::new(Deferred { fonts: None, size: None }),
            cell_background_opacity: Mutex::new(1.0),
            grid_padding: Mutex::new(None),
        }))
    }

    /// Capture the host-owned CAMetalLayer on the native main thread.
    /// No device work is performed until initialize() is awaited.
    #[uniffi::constructor]
    pub fn from_metal_layer(layer: u64) -> Result<Arc<Self>, RenderFailure> {
        // SAFETY: the native facade retains its layer through initialization
        // cancellation and until close() has dropped all render state.
        let attachment = unsafe { tether_render::NativeAttachment::metal_layer(layer) }?;
        Ok(Arc::new(Self {
            inner: Mutex::new(None),
            attachment: Mutex::new(Some(attachment)),
            closed: AtomicBool::new(false),
            font_size: Mutex::new(DEFAULT_FONT_SIZE),
            deferred: Mutex::new(Deferred { fonts: None, size: None }),
            cell_background_opacity: Mutex::new(1.0),
            grid_padding: Mutex::new(None),
        }))
    }

    #[uniffi::constructor]
    pub async fn offscreen(width: u32, height: u32) -> Result<Arc<Self>, RenderFailure> {
        let renderer = TerminalRenderer::offscreen(SurfaceSize { width, height }).await?;
        Ok(Arc::new(Self {
            inner: Mutex::new(Some(renderer)),
            attachment: Mutex::new(None),
            closed: AtomicBool::new(false),
            font_size: Mutex::new(DEFAULT_FONT_SIZE),
            deferred: Mutex::new(Deferred { fonts: None, size: None }),
            cell_background_opacity: Mutex::new(1.0),
            grid_padding: Mutex::new(None),
        }))
    }

    pub async fn initialize(&self, width: u32, height: u32) -> Result<(), RenderFailure> {
        let attachment = self
            .attachment
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .take()
            .ok_or_else(|| RenderFailure::Surface {
                cause: "surface already initialized or closed".into(),
            })?;
        let mut renderer = attachment.initialize(SurfaceSize { width, height }).await?;
        // Same order as set_fonts and resize: deferred, then the renderer.
        let deferred = self.deferred.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let mut inner = self.inner.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if self.closed.load(Ordering::Acquire) {
            return Err(RenderFailure::Surface {
                cause: "surface closed during initialization".into(),
            });
        }
        apply_deferred(&mut renderer, &deferred);
        *inner = Some(renderer);
        Ok(())
    }

    /// Stop native scheduling before calling. In-flight initialization observes
    /// cancellation and drops its renderer before returning to the native host.
    pub fn close(&self) {
        self.closed.store(true, Ordering::Release);
        self.inner.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).take();
        self.attachment.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).take();
    }

    pub fn read_pixels(&self) -> Result<Vec<u8>, RenderFailure> {
        self.inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .as_mut()
            .ok_or_else(|| RenderFailure::Surface { cause: "surface not ready".into() })?
            .read_pixels()
            .map_err(Into::into)
    }

    pub fn wait_idle(&self) -> Result<(), RenderFailure> {
        self.inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .as_ref()
            .ok_or_else(|| RenderFailure::Surface { cause: "surface not ready".into() })?
            .wait_idle()
            .map_err(Into::into)
    }

    /// How opaque a program's own cell backgrounds are drawn while the
    /// palette's background is see-through: a consumer drawing on glass
    /// passes its window opacity. Colours close to the background become the
    /// background. `1.0`, the default, draws them solid. A setter rather than
    /// a palette field, so bindings generated before it still read the palette.
    pub fn set_cell_background_opacity(&self, opacity: f32) {
        let value = if opacity.is_finite() { opacity.clamp(0.0, 1.0) } else { 1.0 };
        *self.cell_background_opacity.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) =
            value;
    }

    /// The least margin round the grid, in physical pixels, drawn by the
    /// surface itself: the grid is centred in what is left, and each edge
    /// cell's background carries on to the surface's edge, so a program that
    /// paints its own background is not framed by the page's. A negative
    /// value, the default, leaves the grid at the corner for a consumer that
    /// lays out its own margin.
    pub fn set_grid_padding(&self, padding: f32) {
        let value = (padding.is_finite() && padding >= 0.0).then_some(padding);
        *self.grid_padding.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = value;
    }

    pub fn set_fonts(&self, primary: String, wide: String) {
        let mut deferred = self.deferred.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        deferred.fonts = Some((primary.clone(), wide.clone()));
        let mut guard = self.inner.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(renderer) = guard.as_mut() {
            renderer.set_fonts(primary, wide);
        }
    }

    pub fn resize(&self, width: u32, height: u32) {
        let mut deferred = self.deferred.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        deferred.size = Some((width, height));
        let mut guard = self.inner.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(renderer) = guard.as_mut() {
            renderer.resize(SurfaceSize { width, height });
        }
    }

    /// Measures the monospaced face this surface will draw with.
    pub fn measure(&self, size: f32) -> Result<FontMetricsDto, RenderFailure> {
        *self.font_size.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = size;
        let mut guard = self.inner.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let renderer = guard.as_mut().ok_or_else(|| RenderFailure::Surface {
            cause: "surface not ready or closed".into(),
        })?;
        let metrics = renderer.measure(size)?;
        let (narrow, wide) = metrics.advances();
        Ok(FontMetricsDto {
            size: metrics.size,
            cell_width: metrics.cell_width,
            line_height: metrics.line_height,
            narrow_advance: narrow,
            wide_advance: wide,
        })
    }

    /// Draws one frame with the consumer's palette and whatever the pointer
    /// is doing (selection, link underlines — spec §14, Decisions/0015).
    ///
    /// Uses the physical size last passed to [`RenderSurface::measure`] or
    /// [`RenderSurface::draw_update`].
    ///
    /// `Ok(true)` is a presented frame, including an offscreen target.
    /// `Ok(false)` means the compositor skipped the acquire: keep the damage
    /// and draw again. It is not a failure.
    pub fn draw(
        &self,
        frame: ScreenFrame,
        palette: PaletteDto,
        overlay: Option<OverlayDto>,
    ) -> Result<bool, RenderFailure> {
        let size = *self.font_size.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        self.draw_update(frame, palette, overlay, size, None)
    }

    /// `font_size` is physical pixels, the same unit [`RenderSurface::measure`] uses.
    /// `None` rebuilds every row. An empty list updates the caret and pointer only.
    /// The bool is the same present result as [`RenderSurface::draw`].
    pub fn draw_update(
        &self,
        frame: ScreenFrame,
        palette: PaletteDto,
        overlay: Option<OverlayDto>,
        font_size: f32,
        dirty_rows: Option<Vec<u32>>,
    ) -> Result<bool, RenderFailure> {
        #[cfg(feature = "render-diagnostics")]
        let _native_span = tether_render::diagnostics::Span::new("native_draw_ms");
        *self.font_size.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = font_size;
        let mut guard = self.inner.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let renderer = guard.as_mut().ok_or_else(|| RenderFailure::Surface {
            cause: "surface not ready or closed".into(),
        })?;
        #[cfg(feature = "render-diagnostics")]
        let conversion_started = std::time::Instant::now();
        let frame = Frame::from(frame);
        renderer.set_padding(
            *self.grid_padding.lock().unwrap_or_else(|poisoned| poisoned.into_inner()),
        );
        let mut palette = Palette::from(palette);
        palette.cell_background_opacity =
            *self.cell_background_opacity.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let overlay = overlay.map(Overlay::from).unwrap_or_default();
        #[cfg(feature = "render-diagnostics")]
        tether_render::diagnostics::record(
            "frame_conversion_ms",
            conversion_started.elapsed().as_secs_f64() * 1000.0,
        );
        renderer
            .draw_update(&frame, &palette, &overlay, font_size, dirty_rows.as_deref())
            .map_err(RenderFailure::from)
    }
}

/// What the pointer is doing, in the shape the frontend contract already
/// carries (spec §14: selection) plus the link underlines of Decisions/0015.
#[derive(Debug, Clone, uniffi::Record)]
pub struct OverlayDto {
    /// Anchor and focus of a drag, as `(column, row)` pairs.
    pub selection: Option<SelectionDto>,
    pub link_underlines: Vec<LinkUnderlineDto>,
    /// What to tint a selected cell with. The caller's selection tint.
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
            cell_background_opacity: 1.0,
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

/// Stable face identities. An id is also a family alias, so `set_fonts` selects that face.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FontFaceDto {
    pub id: String,
    pub family: String,
    pub name: String,
}
impl From<tether_render::FontFace> for FontFaceDto {
    fn from(face: tether_render::FontFace) -> Self {
        Self { id: face.id, family: face.family, name: face.name }
    }
}
#[uniffi::export]
pub fn render_font_faces() -> Vec<FontFaceDto> {
    tether_render::font_faces().into_iter().map(Into::into).collect()
}
#[uniffi::export]
pub fn render_register_font(data: Vec<u8>) -> Result<Vec<FontFaceDto>, RenderFailure> {
    Ok(tether_render::register_font(data)?.into_iter().map(Into::into).collect())
}
#[uniffi::export]
pub fn render_register_font_file(
    path: String,
    family_alias: Option<String>,
) -> Result<Vec<FontFaceDto>, RenderFailure> {
    Ok(tether_render::register_font_file(&path, family_alias.as_deref())?
        .into_iter()
        .map(Into::into)
        .collect())
}
#[uniffi::export]
pub fn render_measure_fonts(
    size: f32,
    primary: String,
    wide: String,
) -> Result<FontMetricsDto, RenderFailure> {
    let metrics = tether_render::measure_fonts(size, &primary, &wide)?;
    let (narrow_advance, wide_advance) = metrics.advances();
    Ok(FontMetricsDto {
        size: metrics.size,
        cell_width: metrics.cell_width,
        line_height: metrics.line_height,
        narrow_advance,
        wide_advance,
    })
}

/// Raw native font resources, not native shaping or rasterization.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FontTableDto {
    pub tag: u32,
    pub data: Vec<u8>,
}
#[uniffi::export]
pub fn render_register_font_tables(
    tables: Vec<FontTableDto>,
    family_alias: String,
) -> Result<Vec<FontFaceDto>, RenderFailure> {
    Ok(tether_render::register_font_tables(
        tables.into_iter().map(|table| (table.tag, table.data)).collect(),
        &family_alias,
    )?
    .into_iter()
    .map(Into::into)
    .collect())
}
