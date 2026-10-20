//! Opt-in evaluation telemetry. CSV writes are buffered; GPU reads never wait
//! in the draw path. A timestamp measures the render pass, not presentation.
use std::fs::{File, OpenOptions};
use std::io::{BufWriter, Write};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Instant;

type Output = Arc<Mutex<BufWriter<File>>>;

thread_local! {
    static FRAME: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
}

fn output() -> Option<&'static Output> {
    static OUTPUT: OnceLock<Option<Output>> = OnceLock::new();
    OUTPUT
        .get_or_init(|| {
            let path = std::env::var_os("TETHER_RENDER_TRACE")?;
            let file = OpenOptions::new().create(true).append(true).open(path).ok()?;
            Some(Arc::new(Mutex::new(BufWriter::new(file))))
        })
        .as_ref()
}

pub fn record(stage: &str, milliseconds: f64) {
    record_for(FRAME.get(), stage, milliseconds);
}

fn record_for(frame: u64, stage: &str, milliseconds: f64) {
    if let Some(output) = output()
        && let Ok(mut file) = output.lock()
    {
        let _ = writeln!(file, "{stage},{milliseconds:.6},{frame}");
    }
}

pub fn flush() {
    if let Some(output) = output()
        && let Ok(mut file) = output.lock()
    {
        let _ = file.flush();
    }
}

pub struct Span {
    stage: &'static str,
    start: Instant,
    previous_frame: u64,
}

impl Span {
    pub fn new(stage: &'static str) -> Self {
        static NEXT_FRAME: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
        let id = NEXT_FRAME.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        Self { stage, start: Instant::now(), previous_frame: FRAME.replace(id) }
    }
}

impl Drop for Span {
    fn drop(&mut self) {
        record(self.stage, self.start.elapsed().as_secs_f64() * 1000.0);
        FRAME.set(self.previous_frame);
    }
}

pub(crate) fn adapter(info: &wgpu::AdapterInfo) {
    if let Some(path) = std::env::var_os("TETHER_RENDER_ADAPTER") {
        // Debug output is diagnostic context, never a public binding type.
        let _ = std::fs::write(path, format!("{info:#?}\n"));
    }
}

/// Snapshot-only run: copy the real swapchain texture, never the desktop.
pub(crate) fn capture(
    device: &wgpu::Device,
    encoder: &mut wgpu::CommandEncoder,
    texture: &wgpu::Texture,
    config: &wgpu::SurfaceConfiguration,
) {
    let Some(path) = std::env::var_os("TETHER_RENDER_CAPTURE") else { return };
    if !matches!(
        config.format,
        wgpu::TextureFormat::Bgra8UnormSrgb
            | wgpu::TextureFormat::Bgra8Unorm
            | wgpu::TextureFormat::Rgba8UnormSrgb
            | wgpu::TextureFormat::Rgba8Unorm
    ) {
        record("capture_unsupported_format", 1.0);
        return;
    }
    let width = config.width;
    let height = config.height;
    let pitch = (width * 4).div_ceil(256) * 256;
    let read = device.create_buffer(&wgpu::BufferDescriptor {
        label: Some("evaluation snapshot"),
        size: pitch as u64 * height as u64,
        usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
        mapped_at_creation: false,
    });
    encoder.copy_texture_to_buffer(
        texture.as_image_copy(),
        wgpu::TexelCopyBufferInfo {
            buffer: &read,
            layout: wgpu::TexelCopyBufferLayout {
                offset: 0,
                bytes_per_row: Some(pitch),
                rows_per_image: Some(height),
            },
        },
        wgpu::Extent3d { width, height, depth_or_array_layers: 1 },
    );
    let buffer = read.clone();
    let bgra = matches!(
        config.format,
        wgpu::TextureFormat::Bgra8Unorm | wgpu::TextureFormat::Bgra8UnormSrgb
    );
    encoder.map_buffer_on_submit(&read, wgpu::MapMode::Read, .., move |result| {
        if result.is_ok() {
            let bytes = buffer.slice(..).get_mapped_range().expect("mapped evaluation buffer");
            let mut image = format!("P6\n{width} {height}\n255\n").into_bytes();
            for row in bytes.chunks(pitch as usize).take(height as usize) {
                for pixel in row[..width as usize * 4].as_chunks::<4>().0 {
                    if bgra {
                        image.extend_from_slice(&[pixel[2], pixel[1], pixel[0]]);
                    } else {
                        image.extend_from_slice(&pixel[..3]);
                    }
                }
            }
            if std::fs::write(path, image).is_err() {
                record("capture_write_error", 1.0);
            }
            drop(bytes);
            buffer.unmap();
        } else {
            record("capture_read_error", 1.0);
        }
    });
}

pub(crate) struct GpuTimer {
    pub query: wgpu::QuerySet,
    resolve: wgpu::Buffer,
    read: wgpu::Buffer,
    busy: Arc<std::sync::atomic::AtomicBool>,
}

impl GpuTimer {
    pub fn new(device: &wgpu::Device) -> Option<Self> {
        if !device.features().contains(wgpu::Features::TIMESTAMP_QUERY) {
            return None;
        }
        Some(Self {
            query: device.create_query_set(&wgpu::QuerySetDescriptor {
                label: Some("evaluation timestamps"),
                ty: wgpu::QueryType::Timestamp,
                count: 2,
            }),
            resolve: device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("evaluation resolve"),
                size: 16,
                usage: wgpu::BufferUsages::QUERY_RESOLVE | wgpu::BufferUsages::COPY_SRC,
                mapped_at_creation: false,
            }),
            read: device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("evaluation readback"),
                size: 16,
                usage: wgpu::BufferUsages::MAP_READ | wgpu::BufferUsages::COPY_DST,
                mapped_at_creation: false,
            }),
            busy: Arc::new(std::sync::atomic::AtomicBool::new(false)),
        })
    }

    pub fn available(&self) -> bool {
        !self.busy.load(std::sync::atomic::Ordering::Acquire)
    }

    pub fn resolve(&self, encoder: &mut wgpu::CommandEncoder, period: f32) {
        self.busy.store(true, std::sync::atomic::Ordering::Release);
        encoder.resolve_query_set(&self.query, 0..2, &self.resolve, 0);
        encoder.copy_buffer_to_buffer(&self.resolve, 0, &self.read, 0, 16);
        let read = self.read.clone();
        let busy = self.busy.clone();
        let frame_id = FRAME.get();
        encoder.map_buffer_on_submit(&self.read, wgpu::MapMode::Read, .., move |result| {
            if result.is_ok() {
                let bytes = read.slice(..).get_mapped_range().expect("mapped evaluation buffer");
                let start = u64::from_ne_bytes(bytes[..8].try_into().unwrap());
                let end = u64::from_ne_bytes(bytes[8..16].try_into().unwrap());
                if end >= start {
                    record_for(frame_id, "gpu_pass_ms", (end - start) as f64 * period as f64 / 1e6);
                } else {
                    record_for(frame_id, "gpu_timestamp_error", 1.0);
                }
                drop(bytes);
                read.unmap();
            } else {
                record_for(frame_id, "gpu_read_error", 1.0);
            }
            busy.store(false, std::sync::atomic::Ordering::Release);
        });
    }
}
