//! The chrome's marks as the Mac app draws them: SF Symbols at the
//! `UIStyle` sizes, rendered once per colour into a PNG GPUI can show.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use gpui::{Image, ImageFormat};
use objc2::AllocAnyThread;
use objc2_app_kit::{
    NSBitmapImageFileType, NSBitmapImageRep, NSColor, NSCompositingOperation,
    NSDeviceRGBColorSpace, NSFontWeight, NSFontWeightMedium, NSFontWeightSemibold,
    NSGraphicsContext, NSImage, NSImageSymbolConfiguration, NSRectFillUsingOperation,
};
use objc2_foundation::{NSDictionary, NSPoint, NSRect, NSSize, NSString};
use tether_ui::{Drawn, Icon, Style, Symbols};

/// Pixels per point in the PNG. GPUI scales it down to the display.
const SCALE: f64 = 3.0;

type Key = (Icon, Style, u32, u32);

#[derive(Default)]
pub struct SfSymbols {
    drawn: Mutex<HashMap<Key, Option<Drawn>>>,
}

impl Symbols for SfSymbols {
    fn draw(&self, icon: Icon, style: Style, rgb: u32, alpha: f32) -> Option<Drawn> {
        let key = (icon, style, rgb, alpha.to_bits());
        let mut drawn = self.drawn.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        drawn.entry(key).or_insert_with(|| render(icon, style, rgb, alpha)).clone()
    }
}

fn weight(style: Style) -> NSFontWeight {
    // SAFETY: AppKit's font weight constants are immutable statics.
    unsafe {
        match style {
            Style::Symbol => NSFontWeightMedium,
            Style::Accessory | Style::TabClose => NSFontWeightSemibold,
        }
    }
}

fn render(icon: Icon, style: Style, rgb: u32, alpha: f32) -> Option<Drawn> {
    let name = NSString::from_str(icon.system_name());
    let base = NSImage::imageWithSystemSymbolName_accessibilityDescription(&name, None)?;
    let config = NSImageSymbolConfiguration::configurationWithPointSize_weight(
        f64::from(style.points()),
        weight(style),
    );
    let image = base.imageWithSymbolConfiguration(&config)?;
    let size = image.size();
    let wide = (size.width * SCALE).ceil() as isize;
    let high = (size.height * SCALE).ceil() as isize;
    if wide <= 0 || high <= 0 {
        return None;
    }
    // SAFETY: a fresh bitmap of the given size, with AppKit allocating the planes.
    let rep = unsafe {
        NSBitmapImageRep::initWithBitmapDataPlanes_pixelsWide_pixelsHigh_bitsPerSample_samplesPerPixel_hasAlpha_isPlanar_colorSpaceName_bytesPerRow_bitsPerPixel(
            NSBitmapImageRep::alloc(),
            std::ptr::null_mut(),
            wide,
            high,
            8,
            4,
            true,
            false,
            NSDeviceRGBColorSpace,
            0,
            0,
        )
    }?;
    rep.setSize(size);
    let context = NSGraphicsContext::graphicsContextWithBitmapImageRep(&rep)?;
    let bounds = NSRect::new(NSPoint::new(0.0, 0.0), NSSize::new(size.width, size.height));
    let channel = |shift: u32| f64::from((rgb >> shift) & 0xFF) / 255.0;
    let color = NSColor::colorWithSRGBRed_green_blue_alpha(
        channel(16),
        channel(8),
        channel(0),
        f64::from(alpha),
    );
    NSGraphicsContext::saveGraphicsState_class();
    NSGraphicsContext::setCurrentContext(Some(&context));
    image.drawInRect(bounds);
    color.set();
    // The symbol's own pixels take the colour; the rest stays clear.
    NSRectFillUsingOperation(bounds, NSCompositingOperation::SourceAtop);
    NSGraphicsContext::restoreGraphicsState_class();
    // SAFETY: an empty property dictionary is a valid argument.
    let png = unsafe {
        rep.representationUsingType_properties(NSBitmapImageFileType::PNG, &NSDictionary::new())
    }?;
    Some(Drawn {
        image: Arc::new(Image::from_bytes(ImageFormat::Png, png.to_vec())),
        width: size.width as f32,
        height: size.height as f32,
    })
}
