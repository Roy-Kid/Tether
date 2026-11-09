//! The chrome's symbols.
//!
//! On a Mac they are SF Symbols, the same ones the Mac app draws, rendered
//! by the host through [`Symbols`] — this crate calls no platform API. A
//! host that renders none gets the bundled SVG stand-ins, drawn by GPUI in
//! the label's colour; it installs [`Assets`] with `Application::with_assets`.

use std::borrow::Cow;
use std::sync::Arc;

use gpui::{AnyElement, AssetSource, SharedString, img, prelude::*, px, svg};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Icon {
    Terminal,
    Close,
    Plus,
    ChevronDown,
    Settings,
    /// The status bar's mark for a shell that ended.
    Ended,
    /// Needs authentication.
    Key,
    /// A down terminal's way back.
    Reconnect,
    /// The current host in the picker.
    Check,
    /// Connecting. No SF Symbol: drawn from the bundle and turned.
    Spinner,
}

impl Icon {
    pub const ALL: [Self; 10] = [
        Self::Terminal,
        Self::Close,
        Self::Plus,
        Self::ChevronDown,
        Self::Settings,
        Self::Ended,
        Self::Key,
        Self::Reconnect,
        Self::Check,
        Self::Spinner,
    ];

    /// The SF Symbol the Mac app draws for this mark.
    pub fn system_name(self) -> &'static str {
        match self {
            Self::Terminal => "terminal",
            Self::Close => "xmark",
            Self::Plus => "plus",
            Self::ChevronDown => "chevron.down",
            Self::Settings => "gearshape",
            Self::Ended => "stop.circle",
            Self::Key => "key.fill",
            Self::Reconnect => "arrow.clockwise",
            Self::Check => "checkmark",
            Self::Spinner => "",
        }
    }

    pub fn path(self) -> &'static str {
        match self {
            Self::Terminal => "icons/terminal.svg",
            Self::Close => "icons/close.svg",
            Self::Plus => "icons/plus.svg",
            Self::ChevronDown => "icons/chevron-down.svg",
            Self::Settings => "icons/settings.svg",
            Self::Ended => "icons/ended.svg",
            Self::Key => "icons/key.svg",
            Self::Reconnect => "icons/reconnect.svg",
            Self::Check => "icons/check.svg",
            Self::Spinner => "icons/spinner.svg",
        }
    }

    fn bytes(self) -> &'static [u8] {
        match self {
            Self::Terminal => include_bytes!("../icons/terminal.svg"),
            Self::Close => include_bytes!("../icons/close.svg"),
            Self::Plus => include_bytes!("../icons/plus.svg"),
            Self::ChevronDown => include_bytes!("../icons/chevron-down.svg"),
            Self::Settings => include_bytes!("../icons/settings.svg"),
            Self::Ended => include_bytes!("../icons/ended.svg"),
            Self::Key => include_bytes!("../icons/key.svg"),
            Self::Reconnect => include_bytes!("../icons/reconnect.svg"),
            Self::Check => include_bytes!("../icons/check.svg"),
            Self::Spinner => include_bytes!("../icons/spinner.svg"),
        }
    }
}

/// The chrome's icons, by the paths [`Icon::path`] names. A path this crate
/// does not own is absent, not an error.
pub struct Assets;

impl AssetSource for Assets {
    fn load(&self, path: &str) -> gpui::Result<Option<Cow<'static, [u8]>>> {
        Ok(Icon::ALL
            .iter()
            .find(|icon| icon.path() == path)
            .map(|icon| Cow::Borrowed(icon.bytes())))
    }

    fn list(&self, path: &str) -> gpui::Result<Vec<SharedString>> {
        Ok(Icon::ALL
            .iter()
            .map(|icon| icon.path())
            .filter(|known| known.starts_with(path))
            .map(SharedString::from)
            .collect())
    }
}

/// The Mac app's symbol fonts (`UIStyle`, `Chrome.tabClose`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Style {
    /// `UIStyle.symbol`: 11pt, medium.
    Symbol,
    /// `UIStyle.accessory`: 10pt, semibold.
    Accessory,
    /// `Chrome.tabClose`: 9pt, semibold.
    TabClose,
}

impl Style {
    pub fn points(self) -> f32 {
        match self {
            Self::Symbol => 11.0,
            Self::Accessory => 10.0,
            Self::TabClose => 9.0,
        }
    }
}

/// A symbol the host rendered, with its size in points.
#[derive(Clone, Debug)]
pub struct Drawn {
    pub image: Arc<gpui::Image>,
    pub width: f32,
    pub height: f32,
}

/// The platform's symbols. `rgb` and `alpha` are the colour to draw in.
/// `None` falls back to the bundled SVG.
pub trait Symbols: Send + Sync + 'static {
    fn draw(&self, icon: Icon, style: Style, rgb: u32, alpha: f32) -> Option<Drawn>;
}

/// The connecting mark (`ProgressView`, mini): an arc that turns.
pub(crate) fn spinner(rgb: u32, alpha: f32) -> AnyElement {
    use gpui::{Animation, AnimationExt, Transformation, percentage};
    svg()
        .path(Icon::Spinner.path())
        .flex_none()
        .size(px(Style::Symbol.points()))
        .text_color(gpui::rgb(rgb).opacity(alpha))
        .with_animation(
            "connecting",
            Animation::new(std::time::Duration::from_secs(1)).repeat(),
            |svg, turned| svg.with_transformation(Transformation::rotate(percentage(turned))),
        )
        .into_any_element()
}

pub(crate) fn icon(
    symbols: Option<&dyn Symbols>,
    icon: Icon,
    style: Style,
    rgb: u32,
    alpha: f32,
) -> AnyElement {
    let system = !icon.system_name().is_empty();
    if let Some(drawn) =
        symbols.filter(|_| system).and_then(|symbols| symbols.draw(icon, style, rgb, alpha))
    {
        return img(drawn.image)
            .flex_none()
            .w(px(drawn.width))
            .h(px(drawn.height))
            .into_any_element();
    }
    // SVG stand-ins are drawn a little larger than the point size, as a symbol's box is.
    let size = style.points() + 2.0;
    svg()
        .path(icon.path())
        .flex_none()
        .size(px(size))
        .text_color(gpui::rgb(rgb).opacity(alpha))
        .into_any_element()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_icon_loads_as_svg() {
        for icon in Icon::ALL {
            let bytes = Assets.load(icon.path()).unwrap().unwrap_or_else(|| panic!("{icon:?}"));
            let text = std::str::from_utf8(&bytes).unwrap();
            assert!(text.starts_with("<svg") && text.trim_end().ends_with("</svg>"), "{icon:?}");
        }
        assert!(Assets.load("icons/missing.svg").unwrap().is_none());
        assert_eq!(Assets.list("icons/").unwrap().len(), Icon::ALL.len());
    }
}
