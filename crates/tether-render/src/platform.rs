//! Native surface attachment and GPU instance policy.
//!
//! Keep OS handles here and all grid/shaping/draw logic in the shared renderer.
//! Apple attaches a CAMetalLayer here and presents through the same draw_frame path.

use crate::RenderError;

/// Captured synchronously on the native UI thread, before any async device work.
pub struct NativeAttachment {
    pub(crate) instance: wgpu::Instance,
    pub(crate) surface: wgpu::Surface<'static>,
}

impl NativeAttachment {
    /// # Safety
    /// Called on the main thread with a live CAMetalLayer. The host retains the
    /// layer until initialization has finished and the renderer is closed.
    pub unsafe fn metal_layer(layer: u64) -> Result<Self, RenderError> {
        #[cfg(target_vendor = "apple")]
        {
            if layer == 0 {
                return Err(RenderError::Surface("null Metal layer".into()));
            }
            unsafe extern "C" {
                fn pthread_main_np() -> std::ffi::c_int;
            }
            // SAFETY: pthread_main_np has no arguments or preconditions.
            if unsafe { pthread_main_np() } == 0 {
                return Err(RenderError::Surface(
                    "Metal layer attachment requires the main thread".into(),
                ));
            }
            let instance = instance();
            // SAFETY: native caller supplies and retains a real CAMetalLayer.
            let surface = unsafe {
                instance.create_surface_unsafe(wgpu::SurfaceTargetUnsafe::CoreAnimationLayer(
                    layer as *mut std::ffi::c_void,
                ))
            }
            .map_err(|e| RenderError::Surface(e.to_string()))?;
            Ok(Self { instance, surface })
        }
        #[cfg(not(target_vendor = "apple"))]
        {
            let _ = layer;
            Err(RenderError::Surface("Metal layer attachment requires Apple".into()))
        }
    }

    pub async fn initialize(
        self,
        size: crate::SurfaceSize,
    ) -> Result<crate::TerminalRenderer, RenderError> {
        crate::TerminalRenderer::with_surface(&self.instance, self.surface, size).await
    }
}

pub(crate) fn instance() -> wgpu::Instance {
    let mut descriptor = wgpu::InstanceDescriptor::new_without_display_handle();
    // Preserve existing product policy, including the diagnostic environment
    // override. This is a set of allowed backends, not a priority ordering.
    descriptor.backends = wgpu::Backends::from_env().unwrap_or(
        wgpu::Backends::DX12 | wgpu::Backends::METAL | wgpu::Backends::VULKAN | wgpu::Backends::GL,
    );
    wgpu::Instance::new(descriptor)
}

/// # Safety
/// The HWND must remain live until the returned surface is dropped.
#[cfg(windows)]
pub(crate) unsafe fn surface_from_hwnd(
    instance: &wgpu::Instance,
    hwnd: isize,
) -> Result<wgpu::Surface<'static>, RenderError> {
    use raw_window_handle::{
        RawDisplayHandle, RawWindowHandle, Win32WindowHandle, WindowsDisplayHandle,
    };
    use std::num::NonZeroIsize;
    let hwnd = NonZeroIsize::new(hwnd).ok_or_else(|| RenderError::Surface("null hwnd".into()))?;
    let mut window = Win32WindowHandle::new(hwnd);
    // Vulkan also needs the module that owns the window class.
    window.hinstance = window_instance(hwnd.get());
    // SAFETY: the caller keeps the native window alive for the surface's life.
    unsafe {
        instance.create_surface_unsafe(wgpu::SurfaceTargetUnsafe::RawHandle {
            raw_display_handle: Some(RawDisplayHandle::Windows(WindowsDisplayHandle::new())),
            raw_window_handle: RawWindowHandle::Win32(window),
        })
    }
    .map_err(|error| RenderError::Surface(error.to_string()))
}

#[cfg(not(windows))]
pub(crate) unsafe fn surface_from_hwnd(
    _instance: &wgpu::Instance,
    _hwnd: isize,
) -> Result<wgpu::Surface<'static>, RenderError> {
    Err(RenderError::Surface("HWND attachment requires Windows".into()))
}

#[cfg(windows)]
fn window_instance(hwnd: isize) -> Option<std::num::NonZeroIsize> {
    #[link(name = "user32")]
    unsafe extern "system" {
        fn GetWindowLongPtrW(hwnd: isize, index: i32) -> isize;
    }
    const GWLP_HINSTANCE: i32 = -6;
    // SAFETY: the attachment caller guarantees this is a live HWND.
    std::num::NonZeroIsize::new(unsafe { GetWindowLongPtrW(hwnd, GWLP_HINSTANCE) })
}
