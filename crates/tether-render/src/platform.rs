//! Native surface attachment and GPU instance policy.
//!
//! Keep OS handles here and all grid/shaping/draw logic in the shared renderer.
//! Future Apple attachment belongs here; it must feed the same draw_frame path.

use crate::RenderError;

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
