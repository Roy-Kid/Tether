//! Where a glyph the chosen fonts lack is looked for.
//!
//! cosmic-text picks its list by target: macOS gets Apple's fonts, and every
//! other Unix — iOS included — gets Linux's (Noto, DejaVu), which no iPhone
//! has. There nothing is found, and a `◈` or `❯` an agent prints is drawn as
//! a missing glyph. iOS gets the Apple fonts it does ship; everywhere else
//! keeps upstream's list.

use glyphon::cosmic_text::Fallback;
use unicode_script::Script;

/// The fallback list for the platform this renderer runs on.
#[cfg(target_os = "ios")]
pub(crate) fn platform() -> impl Fallback {
    AppleMobile
}

/// The fallback list for the platform this renderer runs on.
#[cfg(not(target_os = "ios"))]
pub(crate) fn platform() -> impl Fallback {
    glyphon::cosmic_text::PlatformFallback
}

/// Fonts every iPhone and iPad has, with outlines swash can draw. CoreText
/// draws the symbols agents and TUIs print (`◈ ❯ ✓ ╭ →`) from Menlo.
/// PingFang is absent on purpose: iOS ships it as `hvgl` only.
#[cfg_attr(not(any(target_os = "ios", test)), allow(dead_code))]
struct AppleMobile;

impl Fallback for AppleMobile {
    fn common_fallback(&self) -> &[&'static str] {
        &["Menlo", "Apple Symbols", "Hiragino Sans", "Apple SD Gothic Neo", "Zapf Dingbats"]
    }

    fn forbidden_fallback(&self) -> &[&'static str] {
        &[".LastResort"]
    }

    fn script_fallback(&self, script: Script, _locale: &str) -> &[&'static str] {
        match script {
            Script::Han | Script::Hiragana | Script::Katakana => &["Hiragino Sans"],
            Script::Hangul => &["Apple SD Gothic Neo"],
            _ => &[],
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_mobile_list_names_no_font_it_cannot_draw() {
        let list = AppleMobile;
        assert!(list.common_fallback().contains(&"Menlo"));
        for script in
            [Script::Han, Script::Hiragana, Script::Katakana, Script::Hangul, Script::Latin]
        {
            assert!(
                !list.script_fallback(script, "zh-CN").iter().any(|name| name.contains("PingFang"))
            );
        }
        assert!(!list.common_fallback().iter().any(|name| name.contains("PingFang")));
    }
}
