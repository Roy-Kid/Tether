//! The input method's composing text, drawn over the terminal as the Mac
//! `KeyCaptureView.draw` does: the label colour, underlined, in the
//! monospaced system font at 0.8 of a row, on the text background with a
//! 2pt radius and 3pt sides, kept inside the right edge.
//!
//! It is a layer above the terminal's own: the surface covers whatever GPUI
//! draws, so nothing under it can show the text. Not on the wire yet — a
//! candidate has not been chosen — so the grid has nothing to draw.

use objc2::rc::Retained;
use objc2::runtime::AnyObject;
use objc2_app_kit::{
    NSAttributedStringNSStringDrawing, NSColor, NSFont, NSFontAttributeName, NSFontWeightRegular,
    NSForegroundColorAttributeName, NSUnderlineStyleAttributeName,
};
use objc2_core_foundation::{CGPoint, CGRect, CGSize};
use objc2_foundation::{NSAttributedString, NSDictionary, NSNumber, NSString};
use objc2_quartz_core::{CALayer, CATextLayer, CATransaction};
use tether_ui::Rect;

/// `NSUnderlineStyle.single`.
const UNDERLINE_SINGLE: isize = 1;
const SIDE: f64 = 3.0;

pub struct Preedit {
    chip: Retained<CALayer>,
    text: Retained<CATextLayer>,
}

impl Preedit {
    pub fn new(parent: &CALayer) -> Self {
        let chip = CALayer::new();
        chip.setHidden(true);
        chip.setCornerRadius(2.0);
        let text = CATextLayer::new();
        chip.addSublayer(&text);
        parent.addSublayer(&chip);
        Self { chip, text }
    }

    /// `caret` is the cursor's cell in the parent's points, from its top left.
    /// An empty `marked` hides the chip.
    pub fn show(&self, parent: &CALayer, marked: &str, caret: Rect, row: f32, scale: f32) {
        CATransaction::begin();
        CATransaction::setDisableActions(true);
        self.place(parent, marked, caret, row, scale);
        CATransaction::commit();
    }

    fn place(&self, parent: &CALayer, marked: &str, caret: Rect, row: f32, scale: f32) {
        if marked.is_empty() {
            self.chip.setHidden(true);
            return;
        }
        let size = f64::from((row * 0.8).max(8.0));
        // SAFETY: AppKit's attribute keys and weights are immutable statics.
        let (font_key, color_key, underline_key, regular) = unsafe {
            (
                NSFontAttributeName,
                NSForegroundColorAttributeName,
                NSUnderlineStyleAttributeName,
                NSFontWeightRegular,
            )
        };
        let font = NSFont::monospacedSystemFontOfSize_weight(size, regular);
        let color = NSColor::labelColor();
        let underline = NSNumber::new_isize(UNDERLINE_SINGLE);
        let values: [&AnyObject; 3] = [&font, &color, &underline];
        let attributes = NSDictionary::from_slices(&[font_key, color_key, underline_key], &values);
        // SAFETY: the attributes are a font, a colour and an underline style.
        let string = unsafe {
            NSAttributedString::new_with_attributes(&NSString::from_str(marked), &attributes)
        };
        let measured = string.size();
        let bounds = parent.bounds();
        let height = if caret.height > 0.0 { f64::from(caret.height) } else { f64::from(row) };
        let width = measured.width + SIDE * 2.0;
        let mut x = f64::from(caret.x);
        if x + width > bounds.size.width {
            x = (bounds.size.width - width).max(0.0);
        }
        let top = f64::from(caret.y);
        let y = if parent.isGeometryFlipped() { top } else { bounds.size.height - top - height };
        self.chip.setFrame(CGRect::new(CGPoint::new(x, y), CGSize::new(width, height)));
        self.chip.setBackgroundColor(Some(&NSColor::textBackgroundColor().CGColor()));
        self.chip.setContentsScale(f64::from(scale));
        let inset = ((height - measured.height) / 2.0).max(0.0);
        self.text.setFrame(CGRect::new(CGPoint::new(SIDE, inset), measured));
        self.text.setContentsScale(f64::from(scale));
        // SAFETY: a CATextLayer takes an attributed string as its string.
        unsafe { self.text.setString(Some(&string)) };
        self.chip.setHidden(false);
    }
}

impl Drop for Preedit {
    fn drop(&mut self) {
        self.chip.removeFromSuperlayer();
    }
}
