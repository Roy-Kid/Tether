//! The GPU half: a draw list into a `wgpu` pass, glyphs through `glyphon`.
//!
//! `wgpu`, `glyphon` and `cosmic-text` types stop here (spec §8). Callers
//! hand in a [`DrawList`](crate::draw::DrawList) and get pixels; nothing
//! above this module knows what a texture atlas is.
//!
//! Grid alignment is not left to the shaper. A terminal is a grid: every
//! cell is one column wide (or two), and letting the text system choose
//! advances drifts out of alignment within a line of box-drawing characters.
//! `Buffer::set_monospace_width` forces every grapheme to the column pitch we
//! measured, which is the GPU equivalent of `FontMetrics::tracking`.

use glyphon::{
    Attrs, Buffer, Cache, Color, Family, FontSystem, Metrics, Resolution, Shaping, Style,
    SwashCache, TextArea, TextAtlas, TextBounds, TextRenderer, Viewport, Weight,
};

use crate::draw::{DrawList, Rgba, TextRun};
use crate::metrics::FontMetrics;

/// What a surface must tell us before the first frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SurfaceSize {
    pub width: u32,
    pub height: u32,
}

#[derive(Debug, thiserror::Error)]
pub enum RenderError {
    #[error("no suitable GPU adapter")]
    NoAdapter,
    #[error("no suitable GPU device: {0}")]
    NoDevice(String),
    #[error("surface configuration failed: {0}")]
    Surface(String),
}

/// Font measurements taken from a real face.
///
/// `cosmic-text` shapes; we ask it how far one narrow and one wide character
/// advance at `size`, which is what [`FontMetrics`] needs. A caller that
/// already knows the numbers can use [`FontMetrics::from_advances`] and skip
/// this entirely.
pub fn measure_monospace(fonts: &mut FontSystem, size: f32) -> FontMetrics {
    let metrics = Metrics::new(size, size * 1.2);

    let measure = |fonts: &mut FontSystem, text: &str| -> f32 {
        let mut buffer = Buffer::new(fonts, metrics);
        let attrs = Attrs::new().family(Family::Monospace);
        buffer.set_text(text, &attrs, Shaping::Advanced, None);
        buffer.shape_until_scroll(fonts, false);
        buffer.layout_runs().next().map(|run| run.line_w).unwrap_or(size * 0.6)
    };

    let narrow = measure(fonts, "M");
    let wide = measure(fonts, "中");
    FontMetrics::from_advances(size, narrow, wide, size * 1.2)
}

fn glyph_color(color: Rgba) -> Color {
    let [r, g, b, a] = color.to_bytes();
    Color::rgba(r, g, b, a)
}

/// A solid-colour quad pipeline for cell backgrounds and the caret.
///
/// Not a 2D scene renderer — just the two rectangles a terminal needs under
/// its glyphs. Anything richer would be the layer §22 forbids.
struct QuadPipeline {
    pipeline: wgpu::RenderPipeline,
    vertices: wgpu::Buffer,
    capacity: usize,
    instances: Vec<QuadVertex>,
    /// The target encodes on write, so colours go in linear.
    srgb: bool,
}

/// A palette colour is sRGB. An `*Srgb` target encodes whatever is written
/// to it, so writing sRGB values encodes them twice — `#12141A` comes out
/// as a mid grey. glyphon linearises its own colours; quads and the clear
/// colour are ours to convert.
fn linear(color: Rgba) -> Rgba {
    let channel = |c: f32| {
        if c <= 0.04045 {
            c / 12.92
        } else {
            ((c + 0.055) / 1.055).powf(2.4)
        }
    };
    Rgba::new(channel(color.red), channel(color.green), channel(color.blue), color.alpha)
}

#[repr(C)]
#[derive(Clone, Copy, Debug, bytemuck::Pod, bytemuck::Zeroable)]
struct QuadVertex {
    position: [f32; 2],
    color: [f32; 4],
}

const QUAD_SHADER: &str = r#"
struct VsOut {
    @builtin(position) clip: vec4<f32>,
    @location(0) color: vec4<f32>,
}

@vertex
fn vs_main(@location(0) position: vec2<f32>, @location(1) color: vec4<f32>) -> VsOut {
    var out: VsOut;
    // Positions arrive in normalised surface space with y down.
    out.clip = vec4<f32>(
        position.x * 2.0 - 1.0,
        1.0 - position.y * 2.0,
        0.0,
        1.0,
    );
    out.color = color;
    return out;
}

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    return in.color;
}
"#;

impl QuadPipeline {
    fn new(device: &wgpu::Device, format: wgpu::TextureFormat) -> Self {
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("tether-render quads"),
            source: wgpu::ShaderSource::Wgsl(QUAD_SHADER.into()),
        });
        let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("tether-render quads"),
            bind_group_layouts: &[],
            immediate_size: 0,
        });
        let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("tether-render quads"),
            layout: Some(&layout),
            vertex: wgpu::VertexState {
                module: &shader,
                entry_point: Some("vs_main"),
                compilation_options: Default::default(),
                buffers: &[Some(wgpu::VertexBufferLayout {
                    array_stride: std::mem::size_of::<QuadVertex>() as wgpu::BufferAddress,
                    step_mode: wgpu::VertexStepMode::Vertex,
                    attributes: &wgpu::vertex_attr_array![0 => Float32x2, 1 => Float32x4],
                })],
            },
            fragment: Some(wgpu::FragmentState {
                module: &shader,
                entry_point: Some("fs_main"),
                compilation_options: Default::default(),
                targets: &[Some(wgpu::ColorTargetState {
                    format,
                    blend: Some(wgpu::BlendState::ALPHA_BLENDING),
                    write_mask: wgpu::ColorWrites::ALL,
                })],
            }),
            primitive: wgpu::PrimitiveState::default(),
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            multiview_mask: None,
            cache: None,
        });

        let capacity = 64 * 6;
        let vertices = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("tether-render quads"),
            size: (capacity * std::mem::size_of::<QuadVertex>()) as u64,
            usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        Self {
            pipeline,
            vertices,
            capacity,
            instances: Vec::new(),
            srgb: format.is_srgb(),
        }
    }

    fn push_rect(&mut self, x: f32, y: f32, width: f32, height: f32, color: Rgba, screen: (f32, f32)) {
        let (sw, sh) = screen;
        if sw <= 0.0 || sh <= 0.0 {
            return;
        }
        let normalise = |px: f32, py: f32| [px / sw, py / sh];
        let color = if self.srgb { linear(color) } else { color };
        let c = [color.red, color.green, color.blue, color.alpha];
        let a = normalise(x, y);
        let b = normalise(x + width, y);
        let d = normalise(x, y + height);
        let e = normalise(x + width, y + height);
        for (p0, p1, p2) in [(a, b, d), (b, e, d)] {
            for position in [p0, p1, p2] {
                self.instances.push(QuadVertex {
                    position,
                    color: c,
                });
            }
        }
    }

    fn upload(&mut self, device: &wgpu::Device, queue: &wgpu::Queue) {
        let needed = self.instances.len();
        if needed > self.capacity {
            self.capacity = needed.next_power_of_two().max(6);
            self.vertices = device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("tether-render quads"),
                size: (self.capacity * std::mem::size_of::<QuadVertex>()) as u64,
                usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
                mapped_at_creation: false,
            });
        }
        if !self.instances.is_empty() {
            queue.write_buffer(&self.vertices, 0, bytemuck::cast_slice(&self.instances));
        }
    }

    fn draw<'pass>(&'pass self, pass: &mut wgpu::RenderPass<'pass>) {
        if self.instances.is_empty() {
            return;
        }
        pass.set_pipeline(&self.pipeline);
        pass.set_vertex_buffer(0, self.vertices.slice(..));
        pass.draw(0..self.instances.len() as u32, 0..1);
    }

    fn clear(&mut self) {
        self.instances.clear();
    }
}

/// A terminal surface: device, swapchain-sized target, glyph atlas.
///
/// Construction needs a window handle only so `wgpu` can make a surface; the
/// draw path itself is toolkit-free. An offscreen target is the same type
/// with a texture instead of a surface — which is how the headless tests
/// exercise a frame (spec §15).
pub struct TerminalRenderer {
    device: wgpu::Device,
    queue: wgpu::Queue,
    surface: wgpu::Surface<'static>,
    config: wgpu::SurfaceConfiguration,
    fonts: FontSystem,
    swash: SwashCache,
    atlas: TextAtlas,
    text: TextRenderer,
    viewport: Viewport,
    quads: QuadPipeline,
    buffers: Vec<Buffer>,
    size: SurfaceSize,
}

impl TerminalRenderer {
    /// Creates a renderer for a window the caller already owns.
    ///
    /// `target` is any `raw-window-handle` surface target: a WinUI
    /// `SwapChainPanel`, an `NSView`, a test window. Nothing here names a
    /// toolkit (spec §8).
    pub async fn new(
        instance: &wgpu::Instance,
        target: wgpu::SurfaceTarget<'static>,
        size: SurfaceSize,
    ) -> Result<Self, RenderError> {
        let surface = instance
            .create_surface(target)
            .map_err(|error| RenderError::Surface(error.to_string()))?;
        Self::with_surface(instance, surface, size).await
    }

    /// Creates a renderer for a Win32 `HWND`.
    ///
    /// The caller keeps the window alive; the surface does not own it. This is
    /// the seam a WinUI host uses — the handle is a pointer-sized integer, not
    /// a UI toolkit type (spec §8).
    ///
    /// # Safety
    ///
    /// `hwnd` must be a valid `HWND` that outlives the returned renderer.
    pub async unsafe fn from_hwnd(
        instance: &wgpu::Instance,
        hwnd: isize,
        size: SurfaceSize,
    ) -> Result<Self, RenderError> {
        use std::num::NonZeroIsize;

        use raw_window_handle::{RawDisplayHandle, RawWindowHandle, Win32WindowHandle, WindowsDisplayHandle};

        let hwnd = NonZeroIsize::new(hwnd).ok_or_else(|| RenderError::Surface("null hwnd".into()))?;
        let mut window = Win32WindowHandle::new(hwnd);
        // Vulkan will not make a surface without the module that owns the
        // window. Leave it out and wgpu falls back to GL without a word —
        // and a GL child inside a WinUI window (`WS_EX_NOREDIRECTIONBITMAP`)
        // presents to nowhere: a terminal that runs and shows nothing.
        window.hinstance = window_instance(hwnd.get());
        let raw_window_handle = RawWindowHandle::Win32(window);
        let raw_display_handle = RawDisplayHandle::Windows(WindowsDisplayHandle::new());

        let surface = unsafe {
            instance
                .create_surface_unsafe(wgpu::SurfaceTargetUnsafe::RawHandle {
                    raw_display_handle: Some(raw_display_handle),
                    raw_window_handle,
                })
                .map_err(|error| RenderError::Surface(error.to_string()))?
        };
        Self::with_surface(instance, surface, size).await
    }

    /// Creates a renderer for an existing surface — including an offscreen
    /// texture surface, which is what a headless test uses.
    pub async fn with_surface(
        instance: &wgpu::Instance,
        surface: wgpu::Surface<'static>,
        size: SurfaceSize,
    ) -> Result<Self, RenderError> {
        let adapter = instance
            .request_adapter(&wgpu::RequestAdapterOptions {
                power_preference: wgpu::PowerPreference::LowPower,
                compatible_surface: Some(&surface),
                force_fallback_adapter: false,
                apply_limit_buckets: true,
            })
            .await
            .map_err(|error| RenderError::Surface(error.to_string()))?;

        let (device, queue) = adapter
            .request_device(&wgpu::DeviceDescriptor {
                label: Some("tether-render"),
                required_features: wgpu::Features::empty(),
                required_limits: wgpu::Limits::downlevel_webgl2_defaults()
                    .using_resolution(adapter.limits()),
                experimental_features: wgpu::ExperimentalFeatures::disabled(),
                memory_hints: wgpu::MemoryHints::default(),
                trace: Default::default(),
            })
            .await
            .map_err(|error| RenderError::NoDevice(error.to_string()))?;

        let capabilities = surface.get_capabilities(&adapter);
        let format = capabilities
            .formats
            .iter()
            .copied()
            .find(wgpu::TextureFormat::is_srgb)
            .unwrap_or(capabilities.formats[0]);

        let config = wgpu::SurfaceConfiguration {
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            format,
            width: size.width.max(1),
            height: size.height.max(1),
            present_mode: wgpu::PresentMode::AutoVsync,
            desired_maximum_frame_latency: 2,
            alpha_mode: capabilities.alpha_modes[0],
            color_space: wgpu::SurfaceColorSpace::Srgb,
            view_formats: vec![],
        };
        surface.configure(&device, &config);

        let cache = Cache::new(&device);
        let mut atlas = TextAtlas::new(&device, &queue, &cache, format);
        let text = TextRenderer::new(&mut atlas, &device, wgpu::MultisampleState::default(), None);
        let viewport = Viewport::new(&device, &cache);
        let quads = QuadPipeline::new(&device, format);

        Ok(Self {
            device,
            queue,
            surface,
            config,
            fonts: FontSystem::new(),
            swash: SwashCache::new(),
            atlas,
            text,
            viewport,
            quads,
            buffers: Vec::new(),
            size,
        })
    }

    pub fn size(&self) -> SurfaceSize {
        self.size
    }

    pub fn resize(&mut self, size: SurfaceSize) {
        self.size = SurfaceSize {
            width: size.width.max(1),
            height: size.height.max(1),
        };
        self.config.width = self.size.width;
        self.config.height = self.size.height;
        self.surface.configure(&self.device, &self.config);
    }

    pub fn fonts(&mut self) -> &mut FontSystem {
        &mut self.fonts
    }

    /// Draws one prepared frame.
    ///
    /// Background quads first, glyphs over them, the caret last — the same
    /// paint order [`crate::layout::prepare`] emits.
    pub fn render(&mut self, list: &DrawList) -> Result<(), RenderError> {
        let screen = (self.config.width as f32, self.config.height as f32);
        self.viewport.update(
            &self.queue,
            Resolution {
                width: self.config.width,
                height: self.config.height,
            },
        );

        self.quads.clear();
        for rect in &list.rects {
            self.quads
                .push_rect(rect.x, rect.y, rect.width, rect.height, rect.color, screen);
        }

        // Glyphs. One `Buffer` per run, rebuilt each frame; the run is placed
        // by `left`/`top` and spaced by `set_monospace_width` so a character
        // lands on exactly the column pitch we measured.
        self.buffers.clear();
        self.buffers.reserve(list.texts.len());
        for run in &list.texts {
            self.buffers.push(build_buffer(&mut self.fonts, run));
        }

        let areas: Vec<TextArea<'_>> = list
            .texts
            .iter()
            .zip(self.buffers.iter())
            .map(|(run, buffer)| TextArea {
                buffer,
                left: run.x,
                top: run.y,
                scale: 1.0,
                bounds: TextBounds {
                    left: run.x.floor() as i32,
                    top: run.y.floor() as i32,
                    right: (run.x + run.width).ceil() as i32,
                    bottom: (run.y + run.height).ceil() as i32,
                },
                default_color: glyph_color(run.color),
                custom_glyphs: &[],
            })
            .collect();

        self.text
            .prepare(
                &self.device,
                &self.queue,
                &mut self.fonts,
                &mut self.atlas,
                &self.viewport,
                areas,
                &mut self.swash,
            )
            .map_err(|error| RenderError::Surface(error.to_string()))?;

        // Caret over the glyphs, so a block sits on its character.
        if let Some(cursor) = &list.cursor {
            self.quads.push_rect(
                cursor.x,
                cursor.y,
                cursor.width,
                cursor.height,
                cursor.color,
                screen,
            );
        }
        self.quads.upload(&self.device, &self.queue);

        let frame = match self.surface.get_current_texture() {
            wgpu::CurrentSurfaceTexture::Success(frame)
            | wgpu::CurrentSurfaceTexture::Suboptimal(frame) => frame,
            // The compositor is not asking for a frame right now. Skip and
            // try again on the next wake — not an error (0006: a frame that
            // costs nothing is still a frame we did not have to draw).
            wgpu::CurrentSurfaceTexture::Timeout
            | wgpu::CurrentSurfaceTexture::Occluded => return Ok(()),
            wgpu::CurrentSurfaceTexture::Outdated
            | wgpu::CurrentSurfaceTexture::Lost
            | wgpu::CurrentSurfaceTexture::Validation => {
                return Err(RenderError::Surface("surface outdated or lost".into()));
            }
        };
        let view = frame
            .texture
            .create_view(&wgpu::TextureViewDescriptor::default());
        let clear = if self.config.format.is_srgb() {
            linear(list.background)
        } else {
            list.background
        };
        let mut encoder =
            self.device
                .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                    label: Some("tether-render"),
                });

        {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("tether-render"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &view,
                    depth_slice: None,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color {
                            r: clear.red as f64,
                            g: clear.green as f64,
                            b: clear.blue as f64,
                            a: clear.alpha as f64,
                        }),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
                multiview_mask: None,
            });

            self.quads.draw(&mut pass);
            self.text
                .render(&self.atlas, &self.viewport, &mut pass)
                .map_err(|error| RenderError::Surface(error.to_string()))?;
        }

        self.queue.submit(Some(encoder.finish()));
        self.queue.present(frame);
        Ok(())
    }
}

/// One run shaped into a buffer, spaced to the grid.
fn build_buffer(fonts: &mut FontSystem, run: &TextRun) -> Buffer {
    let metrics = Metrics::new(run.height * 0.75, run.height);
    let mut buffer = Buffer::new(fonts, metrics);
    let characters = run.text.chars().count().max(1) as f32;
    // Every grapheme advances `width / characters`, which is the column pitch
    // for this run: one cell for narrow text, two for wide. This is the GPU
    // half of `FontMetrics::tracking` — the font's own advance is not asked.
    buffer.set_monospace_width(Some(run.width / characters));

    let mut attrs = Attrs::new().family(Family::Monospace).color(glyph_color(run.color));
    if run.bold {
        attrs = attrs.weight(Weight::BOLD);
    }
    if run.italic {
        attrs = attrs.style(Style::Italic);
    }

    buffer.set_text(&run.text, &attrs, Shaping::Advanced, None);
    buffer.shape_until_scroll(fonts, false);
    buffer
}

/// The module that registered `hwnd`'s class — what raw-window-handle calls
/// `hinstance`. One call into user32; no binding crate for a single symbol.
#[cfg(windows)]
fn window_instance(hwnd: isize) -> Option<std::num::NonZeroIsize> {
    #[link(name = "user32")]
    unsafe extern "system" {
        fn GetWindowLongPtrW(hwnd: isize, index: i32) -> isize;
    }
    const GWLP_HINSTANCE: i32 = -6;
    // SAFETY: the caller of `from_hwnd` guarantees `hwnd` is a live window.
    std::num::NonZeroIsize::new(unsafe { GetWindowLongPtrW(hwnd, GWLP_HINSTANCE) })
}

#[cfg(not(windows))]
fn window_instance(_hwnd: isize) -> Option<std::num::NonZeroIsize> {
    None
}
