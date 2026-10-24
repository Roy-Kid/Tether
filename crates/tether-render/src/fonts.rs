//! One font catalogue for native hosts. Storage and native font discovery belong
//! to the host; parsing, face identity and shaping belong to this crate.
use std::sync::{Mutex, OnceLock};

use glyphon::{FontSystem, fontdb};
use sha2::{Digest, Sha256};

const ALIAS_LANGUAGE: fontdb::Language = fontdb::Language::English_UnitedStates;

use crate::{FontMetrics, RenderError};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FontFace {
    /// Imported faces use content SHA256 + collection index, never a filename.
    pub id: String,
    pub family: String,
    pub name: String,
}

struct Catalogue {
    db: fontdb::Database,
    faces: Vec<FontFace>,
    /// Path → the faces that registration returned for it. A deduped file
    /// still remembers those faces; it does not claim a source it never stored.
    files: std::collections::HashMap<String, Vec<FontFace>>,
    generation: u64,
}

fn lock_catalogue() -> std::sync::MutexGuard<'static, Catalogue> {
    catalogue().lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

const MAX_FONT_BYTES: u64 = 128 * 1024 * 1024;

fn catalogue() -> &'static Mutex<Catalogue> {
    static CATALOGUE: OnceLock<Mutex<Catalogue>> = OnceLock::new();
    CATALOGUE.get_or_init(|| {
        #[allow(unused_mut)]
        let mut db = fontdb::Database::new();
        // fontdb 0.23 otherwise attempts Linux font directories on iOS.
        #[cfg(not(target_os = "ios"))]
        db.load_system_fonts();
        normalize_monospace_metadata(&mut db);
        #[cfg(target_os = "macos")]
        db.set_monospace_family("Menlo");
        #[cfg(windows)]
        db.set_monospace_family("Consolas");
        // A stored face id has to be a family query. PostScript names are not
        // families until they are installed beside the public family.
        install_identity_aliases(&mut db, None);
        let faces = published_faces(&db);
        let mut files = std::collections::HashMap::<String, Vec<FontFace>>::new();
        for face in db.faces() {
            let Some(path) = source_path(&face.source) else { continue };
            if face.post_script_name.is_empty() {
                continue;
            }
            let record = FontFace {
                id: face.post_script_name.clone(),
                family: public_family(face),
                name: face.post_script_name.clone(),
            };
            files.entry(canonical_key(path)).or_default().push(record);
        }
        Mutex::new(Catalogue { db, faces, files, generation: 0 })
    })
}

pub fn font_faces() -> Vec<FontFace> {
    let mut faces = lock_catalogue().faces.clone();
    faces.sort_by(|a, b| (&a.family, &a.name, &a.id).cmp(&(&b.family, &b.name, &b.id)));
    faces.dedup_by(|a, b| a.id == b.id);
    faces
}

const UNDRAWABLE: &str = "font has no TrueType, CFF or bitmap glyphs to draw";

/// Validate before publishing anything to the live catalogue.
pub fn register_font(data: Vec<u8>) -> Result<Vec<FontFace>, RenderError> {
    register_with_alias(data, None)
}

/// CoreText virtual system fonts expose tables rather than file URLs. Compose
/// their OpenType container with fontations; never reimplement font encoding.
pub fn register_font_tables(
    tables: Vec<(u32, Vec<u8>)>,
    alias: &str,
) -> Result<Vec<FontFace>, RenderError> {
    let mut builder = write_fonts::FontBuilder::new();
    for (tag, data) in tables {
        builder.add_raw(write_fonts::types::Tag::new(&tag.to_be_bytes()), data);
    }
    register_with_alias(builder.build(), Some(alias))
}

fn register_with_alias(data: Vec<u8>, alias: Option<&str>) -> Result<Vec<FontFace>, RenderError> {
    if data.is_empty() || data.len() as u64 > MAX_FONT_BYTES {
        return Err(RenderError::Font("font must contain between 1 byte and 128 MiB".into()));
    }
    let digest = content_digest(&data);
    let mut parsed = fontdb::Database::new();
    let ids = parsed.load_font_source(fontdb::Source::Binary(std::sync::Arc::new(data)));
    if ids.is_empty() {
        return Err(RenderError::Font("not a supported TTF, OTF or TTC font".into()));
    }
    drop_undrawable_faces(&mut parsed);
    if parsed.is_empty() {
        return Err(RenderError::Font(UNDRAWABLE.into()));
    }
    normalize_monospace_metadata(&mut parsed);
    let ids = parsed.faces().map(|face| face.id).collect::<Vec<_>>();
    let mut catalogue = lock_catalogue();
    let mut result = Vec::new();
    for id in ids {
        let mut face = parsed.face(id).expect("parsed face").clone();
        let stable = format!("{digest}:{}", face.index);
        let record = FontFace {
            id: stable.clone(),
            family: face.families.first().map_or(String::new(), |f| f.0.clone()),
            name: face.post_script_name.clone(),
        };
        if catalogue.faces.iter().any(|existing| existing.id == stable) {
            // A later alias is the same rule as file registration.
            if let Some(alias) = alias.filter(|alias| !alias.is_empty())
                && add_alias_to_published_id(&mut catalogue.db, &stable, alias)
            {
                catalogue.generation += 1;
            }
        } else {
            // A private family alias selects this exact face even when a
            // system or imported font has the same public family name.
            face.families.push((stable, ALIAS_LANGUAGE));
            if let Some(alias) = alias.filter(|alias| !alias.is_empty()) {
                face.families.push((alias.to_owned(), ALIAS_LANGUAGE));
            }
            catalogue.db.push_face_info(face);
            catalogue.faces.push(record.clone());
            catalogue.generation += 1;
        }
        result.push(record);
    }
    Ok(result)
}

/// Native system-font files remain memory mapped instead of copied over FFI.
///
/// `alias`, when set, is an extra family name on every face in the file
/// (the system monospace alias). The path is recorded only after at least
/// one face parses; a later good file at the same path is not ignored.
pub fn register_font_file(path: &str, alias: Option<&str>) -> Result<Vec<FontFace>, RenderError> {
    let key = canonical_key(std::path::Path::new(path));
    let len = std::fs::metadata(&key).map_err(|error| RenderError::Font(error.to_string()))?.len();
    if len == 0 || len > MAX_FONT_BYTES {
        return Err(RenderError::Font("font must contain between 1 byte and 128 MiB".into()));
    }
    {
        let mut catalogue = lock_catalogue();
        if let Some(existing) = catalogue.files.get(&key).cloned() {
            return Ok(apply_stored_alias(&mut catalogue, &key, &existing, alias));
        }
    }
    // Parse outside the catalogue mutex. A slow disk must not stall a frame.
    // `load_font_file` keeps a memory-mapped `Source::File`. The bytes are
    // read only when a face has no PostScript name and needs a content id.
    let mut parsed = fontdb::Database::new();
    parsed.load_font_file(&key).map_err(|error| RenderError::Font(error.to_string()))?;
    if parsed.is_empty() {
        return Err(RenderError::Font("not a supported TTF, OTF or TTC font".into()));
    }
    drop_undrawable_faces(&mut parsed);
    if parsed.is_empty() {
        return Err(RenderError::Font(UNDRAWABLE.into()));
    }
    normalize_monospace_metadata(&mut parsed);
    if parsed.is_empty() {
        return Err(RenderError::Font("not a supported TTF, OTF or TTC font".into()));
    }
    install_identity_aliases(&mut parsed, alias.filter(|alias| !alias.is_empty()));
    let digest = if parsed.faces().any(|face| face.post_script_name.is_empty()) {
        let bytes = std::fs::read(&key).map_err(|error| RenderError::Font(error.to_string()))?;
        content_digest(&bytes)
    } else {
        String::new()
    };
    let mut catalogue = lock_catalogue();
    if let Some(existing) = catalogue.files.get(&key).cloned() {
        return Ok(apply_stored_alias(&mut catalogue, &key, &existing, alias));
    }
    let mut changed = false;
    let mut result = Vec::new();
    for face in parsed.faces().cloned() {
        let id = if face.post_script_name.is_empty() {
            format!("{digest}:{}", face.index)
        } else {
            face.post_script_name.clone()
        };
        if let Some(existing) = catalogue.faces.iter().find(|existing| existing.id == id).cloned() {
            if let Some(alias) = alias.filter(|alias| !alias.is_empty()) {
                changed |= add_alias_to_published_id(&mut catalogue.db, &id, alias);
            }
            result.push(existing);
            continue;
        }
        let mut face = face;
        if !face.families.iter().any(|(name, _)| name == &id) {
            face.families.push((id.clone(), ALIAS_LANGUAGE));
        }
        let record = FontFace {
            id: id.clone(),
            family: public_family(&face),
            name: if face.post_script_name.is_empty() { id } else { face.post_script_name.clone() },
        };
        face.id = fontdb::ID::dummy();
        catalogue.db.push_face_info(face);
        catalogue.faces.push(record.clone());
        result.push(record);
        changed = true;
    }
    if result.is_empty() {
        return Err(RenderError::Font("not a supported TTF, OTF or TTC font".into()));
    }
    catalogue.files.insert(key, result.clone());
    if changed {
        catalogue.generation += 1;
    }
    Ok(result)
}

fn apply_stored_alias(
    catalogue: &mut Catalogue,
    key: &str,
    existing: &[FontFace],
    alias: Option<&str>,
) -> Vec<FontFace> {
    if let Some(alias) = alias.filter(|alias| !alias.is_empty()) {
        let mut changed = false;
        for face in existing {
            changed |= add_alias_to_published_id(&mut catalogue.db, &face.id, alias);
        }
        if changed {
            catalogue.generation += 1;
            catalogue.files.insert(key.to_owned(), existing.to_vec());
        }
    }
    existing.to_vec()
}

fn content_digest(data: &[u8]) -> String {
    Sha256::digest(data).iter().map(|byte| format!("{byte:02x}")).collect()
}

pub(crate) fn snapshot() -> (FontSystem, u64) {
    let catalogue = lock_catalogue();
    (
        FontSystem::new_with_locale_and_db_and_fallback(
            "en-US".into(),
            catalogue.db.clone(),
            crate::fallback::platform(),
        ),
        catalogue.generation,
    )
}

pub(crate) fn generation() -> u64 {
    lock_catalogue().generation
}

pub fn measure_fonts(size: f32, primary: &str, wide: &str) -> Result<FontMetrics, RenderError> {
    // Measurement is GPU-independent. The cache lock does not cover shaping.
    type Key = (u32, String, String, u64);
    static CACHE: OnceLock<Mutex<std::collections::HashMap<Key, FontMetrics>>> = OnceLock::new();
    let cache = CACHE.get_or_init(Default::default);
    let key = (size.to_bits(), primary.to_owned(), wide.to_owned(), generation());
    {
        let cache = cache.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(metrics) = cache.get(&key) {
            return Ok(*metrics);
        }
    }
    let (mut fonts, _) = snapshot();
    let metrics =
        crate::renderer::measure_font(&mut fonts, size, &family_name(primary), &family_name(wide))?;
    let mut cache = cache.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    if cache.len() >= 256 {
        cache.clear();
    }
    cache.insert(key, metrics);
    Ok(metrics)
}

/// A catalogue id is a family alias on that face, so it is used unchanged.
/// A public family name such as "PingFang SC" is not an id and passes through.
pub(crate) fn family_name(name: &str) -> String {
    name.to_owned()
}

fn published_faces(db: &fontdb::Database) -> Vec<FontFace> {
    db.faces()
        .filter(|face| !face.post_script_name.is_empty())
        .map(|face| FontFace {
            id: face.post_script_name.clone(),
            family: public_family(face),
            name: face.post_script_name.clone(),
        })
        .collect()
}

fn public_family(face: &fontdb::FaceInfo) -> String {
    face.families.iter().find(|(name, _)| name != &face.post_script_name).map_or_else(
        || face.families.first().map_or(String::new(), |family| family.0.clone()),
        |(name, _)| name.clone(),
    )
}

/// Puts each face's published id on its family list, plus `extra` when set.
fn install_identity_aliases(db: &mut fontdb::Database, extra: Option<&str>) {
    let snapshot = db.faces().cloned().collect::<Vec<_>>();
    for mut face in snapshot {
        let mut changed = false;
        if !face.post_script_name.is_empty()
            && !face.families.iter().any(|(name, _)| name == &face.post_script_name)
        {
            face.families.push((face.post_script_name.clone(), ALIAS_LANGUAGE));
            changed = true;
        }
        if let Some(alias) = extra.filter(|alias| !alias.is_empty())
            && !face.families.iter().any(|(name, _)| name == alias)
        {
            face.families.push((alias.to_owned(), ALIAS_LANGUAGE));
            changed = true;
        }
        if changed {
            db.remove_face(face.id);
            face.id = fontdb::ID::dummy();
            db.push_face_info(face);
        }
    }
}

/// `id` is the published face id: a PostScript name, or `sha256:index` for a
/// face that has neither. Byte faces never store that id as `post_script_name`.
fn add_alias_to_published_id(db: &mut fontdb::Database, id: &str, alias: &str) -> bool {
    let Some(mut face) = db
        .faces()
        .find(|face| {
            face.post_script_name == id || face.families.iter().any(|(name, _)| name == id)
        })
        .cloned()
    else {
        return false;
    };
    if face.families.iter().any(|(name, _)| name == alias) {
        return false;
    }
    db.remove_face(face.id);
    face.id = fontdb::ID::dummy();
    face.families.push((alias.to_owned(), ALIAS_LANGUAGE));
    db.push_face_info(face);
    true
}

fn source_path(source: &fontdb::Source) -> Option<&std::path::Path> {
    match source {
        fontdb::Source::File(path) => Some(path.as_path()),
        _ => None,
    }
}

fn canonical_key(path: &std::path::Path) -> String {
    std::fs::canonicalize(path)
        .map(|path| path.to_string_lossy().into_owned())
        .unwrap_or_else(|_| path.to_string_lossy().into_owned())
}

/// Tables holding glyph images swash can paint: TrueType and CFF outlines,
/// and the colour bitmaps emoji ship as. `COLR` layers are drawn from `glyf`.
const DRAWABLE_GLYPH_TABLES: [&[u8; 4]; 6] = [b"glyf", b"CFF ", b"CFF2", b"sbix", b"CBDT", b"EBDT"];

/// Leaves out faces this renderer cannot draw.
///
/// iOS ships PingFang with Apple's `hvgl` outlines and nothing else. Kept,
/// such a face is chosen for its character map, so fallback never looks
/// further, and every glyph comes out empty: Chinese vanishes from the line.
fn drop_undrawable_faces(db: &mut fontdb::Database) {
    let undrawable = db
        .faces()
        .filter(|face| {
            !db.with_face_data(face.id, |data, index| {
                ttf_parser::RawFace::parse(data, index).is_ok_and(|raw| {
                    DRAWABLE_GLYPH_TABLES
                        .iter()
                        .any(|tag| raw.table(ttf_parser::Tag::from_bytes(tag)).is_some())
                })
            })
            .unwrap_or(false)
        })
        .map(|face| face.id)
        .collect::<Vec<_>>();
    for id in undrawable {
        db.remove_face(id);
    }
}

/// Some Apple fallback faces declare themselves monospaced but give space a
/// zero advance. cosmic-text's monospace fallback scaling then divides by
/// zero. Keep shaping those faces normally while retaining our grid snapping.
fn normalize_monospace_metadata(db: &mut fontdb::Database) {
    let invalid = db
        .faces()
        .filter(|face| face.monospaced)
        .filter_map(|face| {
            let valid = db
                .with_face_data(face.id, |data, index| {
                    ttf_parser::Face::parse(data, index)
                        .ok()
                        .and_then(|font| {
                            font.glyph_index(' ').and_then(|glyph| font.glyph_hor_advance(glyph))
                        })
                        .is_some_and(|advance| advance > 0)
                })
                .unwrap_or(false);
            (!valid).then(|| face.clone())
        })
        .collect::<Vec<_>>();
    for mut face in invalid {
        db.remove_face(face.id);
        face.monospaced = false;
        db.push_face_info(face);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejected_font_does_not_mutate_catalogue() {
        let before = font_faces();
        let generation = generation();
        assert!(register_font(b"not a font".to_vec()).is_err());
        assert_eq!(before, font_faces());
        assert_eq!(generation, super::generation());
    }

    #[test]
    fn invalid_font_file_is_not_remembered() {
        let dir = std::env::temp_dir().join(format!("tether-font-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("bad.ttf");
        std::fs::write(&path, b"not a font").unwrap();
        let before = font_faces();
        let generation = generation();
        assert!(register_font_file(path.to_str().unwrap(), None).is_err());
        assert_eq!(before, font_faces());
        assert_eq!(generation, super::generation());
        assert!(register_font_file(path.to_str().unwrap(), None).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A real font's tables, as CoreText would hand them over.
    fn system_font_tables() -> Option<Vec<(u32, Vec<u8>)>> {
        let data = [
            "/System/Library/Fonts/Menlo.ttc",
            "/System/Library/Fonts/Supplemental/Courier New.ttf",
        ]
        .iter()
        .find_map(|path| std::fs::read(path).ok())?;
        let face = ttf_parser::RawFace::parse(&data, 0).ok()?;
        Some(
            face.table_records
                .into_iter()
                .filter_map(|record| {
                    let bytes = face.table(record.tag)?;
                    Some((record.tag.0, bytes.to_vec()))
                })
                .collect(),
        )
    }

    #[test]
    fn a_face_with_no_outline_this_renderer_draws_is_refused() {
        let Some(tables) = system_font_tables() else { return };
        // iOS ships PingFang with Apple's `hvgl` outlines only. A face
        // registered without outlines it can paint would be chosen for its
        // cmap and then draw every glyph as nothing.
        let hidden = tables
            .iter()
            .map(|(tag, data)| {
                let tag =
                    if &tag.to_be_bytes() == b"glyf" { u32::from_be_bytes(*b"hvgl") } else { *tag };
                (tag, data.clone())
            })
            .collect::<Vec<_>>();
        let refused = register_font_tables(hidden, "Undrawable Test Family");
        assert!(refused.is_err(), "{refused:?}");
        assert!(!font_faces().iter().any(|face| face.family == "Undrawable Test Family"));
        let accepted =
            register_font_tables(tables, "Drawable Test Family").expect("outlines present");
        assert!(!accepted.is_empty());
    }

    #[test]
    fn published_face_id_is_a_family_alias() {
        let mut db = fontdb::Database::new();
        db.push_face_info(fontdb::FaceInfo {
            id: fontdb::ID::dummy(),
            source: fontdb::Source::Binary(std::sync::Arc::new(Vec::<u8>::new())),
            index: 0,
            families: vec![("Menlo".into(), ALIAS_LANGUAGE)],
            post_script_name: "Menlo-Bold".into(),
            style: fontdb::Style::Normal,
            weight: fontdb::Weight::BOLD,
            stretch: fontdb::Stretch::Normal,
            monospaced: true,
        });
        install_identity_aliases(&mut db, Some("Tether System Monospace"));
        let face = db.faces().next().expect("face");
        let names = face.families.iter().map(|(name, _)| name.as_str()).collect::<Vec<_>>();
        assert!(names.contains(&"Menlo-Bold"), "{names:?}");
        assert!(names.contains(&"Menlo"), "{names:?}");
        assert!(names.contains(&"Tether System Monospace"), "{names:?}");
        assert_eq!(family_name("Menlo-Bold"), "Menlo-Bold");
        assert_eq!(family_name("PingFang SC"), "PingFang SC");
    }

    #[test]
    fn later_alias_matches_a_content_id() {
        let mut db = fontdb::Database::new();
        let id = "abc123:0";
        db.push_face_info(fontdb::FaceInfo {
            id: fontdb::ID::dummy(),
            source: fontdb::Source::Binary(std::sync::Arc::new(Vec::<u8>::new())),
            index: 0,
            families: vec![("Demo".into(), ALIAS_LANGUAGE), (id.into(), ALIAS_LANGUAGE)],
            post_script_name: String::new(),
            style: fontdb::Style::Normal,
            weight: fontdb::Weight::NORMAL,
            stretch: fontdb::Stretch::Normal,
            monospaced: true,
        });
        assert!(add_alias_to_published_id(&mut db, id, "Tether System Monospace"));
        assert!(!add_alias_to_published_id(&mut db, id, "Tether System Monospace"));
        let names = db
            .faces()
            .next()
            .expect("face")
            .families
            .iter()
            .map(|(name, _)| name.as_str())
            .collect::<Vec<_>>();
        assert!(names.contains(&"Tether System Monospace"), "{names:?}");
    }

    #[test]
    fn catalogue_postscript_id_is_not_collapsed() {
        for face in font_faces() {
            assert_eq!(family_name(&face.id), face.id);
            if face.id.contains(':') {
                continue;
            }
            let catalogue = lock_catalogue();
            let stored =
                catalogue.db.faces().find(|candidate| candidate.post_script_name == face.id);
            let Some(stored) = stored else { continue };
            assert!(
                stored.families.iter().any(|(name, _)| name == &face.id),
                "{} is not selectable as itself",
                face.id
            );
        }
    }
}
