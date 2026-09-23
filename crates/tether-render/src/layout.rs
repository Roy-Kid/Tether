//! Grid layout: frame → draw list.
//!
//! This is the terminal-specific part spec §14 says we write. The hard and
//! generic parts — shaping, fallback, atlases, GPU submission — belong to
//! `cosmic-text` and `glyphon`. What happens here is where a run sits on the
//! grid, what colour it is, and which cells are not text at all.

use crate::draw::{BgRect, Cell, CursorQuad, DrawList, LinkUnderline, Overlay, Rgba, TextRun};
use crate::frame::{Caret, Frame, RunStyle};
use crate::metrics::FontMetrics;
use crate::palette::Palette;

/// Turns one frame into what to paint. No pointer marks.
pub fn prepare(frame: &Frame, metrics: &FontMetrics, palette: &Palette) -> DrawList {
    prepare_with_overlay(frame, metrics, palette, &Overlay::default())
}

/// Turns one frame, plus what the pointer is doing, into what to paint.
///
/// Full-frame today: every visible run is emitted. Damage-driven partial
/// redraw is the contract's other half (spec §12, §20) and lands against
/// [`crate::frame::Frame`] row spans; until then this is the measured path
/// from 0006 — a frame linear in runs, never in cells.
///
/// The overlay is the pointer's own marks: a selection and link underlines.
/// Both are just rects under the glyphs, which is what the Swift
/// `LinkUnderline` draws and what `UIStyle.selectionOpacity` tints.
pub fn prepare_with_overlay(
    frame: &Frame,
    metrics: &FontMetrics,
    palette: &Palette,
    overlay: &Overlay,
) -> DrawList {
    let mut list = DrawList {
        background: palette.background,
        ..DrawList::default()
    };

    // Visible columns is a clip, not a shrink: a run that starts inside is
    // drawn whole and clipped by the surface, which is what `TerminalView`
    // does with `context.clip`.
    let visible_columns = (metrics.columns_fitting(f32::MAX) as u32).min(frame.columns) as usize;
    let visible_rows = frame.lines.len().min(frame.rows as usize);

    for (index, row) in frame.lines.iter().take(visible_rows).enumerate() {
        let y = metrics.cell_y(index as u32);
        let mut column = 0u32;

        for run in &row.runs {
            if column as usize >= visible_columns {
                break;
            }

            let x = metrics.cell_x(column);
            let width = metrics.cells_width(run.columns);

            let (foreground, background) = resolved(&run.style, palette);
            if background != palette.background {
                list.rects.push(BgRect {
                    x,
                    y,
                    width,
                    height: metrics.line_height,
                    color: background,
                });
            }

            // Text present but not to be drawn: what a shell does while
            // reading a password. The background above is still painted, so
            // the cell does not become a hole in a highlighted region.
            let draws_text = !run.style.hidden && !run.text.chars().all(char::is_whitespace);
            if draws_text {
                let characters = run.text.chars().count();
                list.texts.push(TextRun {
                    x,
                    y,
                    width,
                    height: metrics.line_height,
                    text: run.text.clone(),
                    color: if run.style.dim { foreground.with_alpha(0.6) } else { foreground },
                    tracking: metrics.tracking(run.columns, characters),
                    bold: run.style.bold,
                    italic: run.style.italic,
                    underline: !matches!(run.style.underline, crate::frame::Underline::None),
                    underline_color: run
                        .style
                        .underline_color
                        .map(|paint| palette.resolve(paint)),
                    strikethrough: run.style.strikethrough,
                });
            }

            column += run.columns;
        }
    }

    // Hidden is a shape as well as a flag: a full-screen program hides the
    // cursor constantly while redrawing, and drawing it anyway is how a
    // terminal ends up with a block flickering across the screen.
    if frame.cursor_visible && frame.cursor_shape != Caret::Hidden {
        let x = metrics.cell_x(frame.cursor_column);
        let y = metrics.cell_y(frame.cursor_row);
        let (width, height, offset_y) = match frame.cursor_shape {
            Caret::Block => (metrics.cell_width, metrics.line_height, 0.0),
            Caret::Underline => (metrics.cell_width, 2.0, metrics.line_height - 2.0),
            Caret::Beam => (2.0, metrics.line_height, 0.0),
            Caret::Hidden => unreachable!("checked above"),
        };
        let color = palette.cursor.with_alpha(0.75);
        list.cursor = Some(CursorQuad {
            x,
            y: y + offset_y,
            width,
            height,
            // Blended rather than filled, so the character underneath stays
            // readable inside a block cursor without drawing it twice.
            color,
            shape: frame.cursor_shape,
        });
        // And as a glyph, so a backend whose quad path is not drawing still
        // shows the caret. The text pass is the one every backend has.
        list.texts.push(TextRun {
            x,
            y,
            width,
            height: metrics.line_height,
            text: match frame.cursor_shape {
                Caret::Block => "█".to_owned(),
                Caret::Underline => "_".to_owned(),
                Caret::Beam => "▏".to_owned(),
                Caret::Hidden => String::new(),
            },
            color,
            tracking: 0.0,
            bold: false,
            italic: false,
            underline: false,
            underline_color: None,
            strikethrough: false,
        });
    }

    // Pointer marks last among the rects so a selection sits over a cell
    // background and under the glyphs.
    push_overlay(&mut list, metrics, overlay, frame.columns);

    list
}

/// Selection and link underlines, as rects under the glyphs.
fn push_overlay(
    list: &mut DrawList,
    metrics: &FontMetrics,
    overlay: &Overlay,
    columns: u32,
) {
    if let Some((anchor, focus)) = overlay.selection {
        for row in selection_rows(anchor, focus) {
            let (start, end) = selection_columns(anchor, focus, row, columns);
            if end <= start {
                continue;
            }
            list.rects.push(BgRect {
                x: metrics.cell_x(start),
                y: metrics.cell_y(row),
                width: metrics.cells_width(end - start),
                height: metrics.line_height,
                color: overlay.selection_color,
            });
        }
    }

    for underline in &overlay.link_underlines {
        push_link_underline(list, metrics, underline, overlay.link_color);
    }
}

fn selection_rows(anchor: Cell, focus: Cell) -> impl Iterator<Item = u32> {
    let top = anchor.row.min(focus.row);
    let bottom = anchor.row.max(focus.row);
    top..=bottom
}

/// The columns a selection covers on `row`. `end` is exclusive and clamped
/// to the grid: a drag that runs off the right edge selects to the edge,
/// not past it.
fn selection_columns(anchor: Cell, focus: Cell, row: u32, columns: u32) -> (u32, u32) {
    let (left, right) = if anchor.row == focus.row {
        (
            anchor.column.min(focus.column),
            anchor.column.max(focus.column) + 1,
        )
    } else if row == anchor.row {
        if focus.row > anchor.row {
            (anchor.column, columns)
        } else {
            (0, anchor.column + 1)
        }
    } else if row == focus.row {
        if focus.row > anchor.row {
            (0, focus.column + 1)
        } else {
            (focus.column, columns)
        }
    } else {
        (0, columns)
    };
    (left.min(columns), right.min(columns))
}

fn push_link_underline(
    list: &mut DrawList,
    metrics: &FontMetrics,
    underline: &LinkUnderline,
    color: Rgba,
) {
    // A 1px rule at the cell's baseline. Solid when the host has confirmed
    // the thing exists; dashed while it is still asking (0015).
    let y = metrics.cell_y(underline.span.row) + metrics.line_height - 1.0;
    let x = metrics.cell_x(underline.span.start);
    let width = metrics.cells_width(underline.span.end.saturating_sub(underline.span.start));

    if underline.confirmed {
        list.rects.push(BgRect {
            x,
            y,
            width,
            height: 1.0,
            color,
        });
        return;
    }

    // Dotted: 2px dash, 2px gap. Cheap and reads as "not yet known".
    let mut cursor = x;
    let end = x + width;
    while cursor < end {
        let dash = (end - cursor).min(2.0);
        list.rects.push(BgRect {
            x: cursor,
            y,
            width: dash,
            height: 1.0,
            color,
        });
        cursor += 4.0;
    }
}

/// Foreground and background as this renderer draws them.
///
/// `inverse` is a flag rather than pre-swapped colours so that a renderer can
/// decide; this one decides by swapping, which is what a terminal does.
fn resolved(style: &RunStyle, palette: &Palette) -> (Rgba, Rgba) {
    let foreground = palette.resolve(style.foreground);
    let background = palette.resolve(style.background);
    if style.inverse {
        (background, foreground)
    } else {
        (foreground, background)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::frame::{Name, Paint, Row, Run, RunStyle};

    fn metrics() -> FontMetrics {
        FontMetrics::from_advances(13.0, 8.0, 16.0, 16.0)
    }

    fn one_row(runs: Vec<Run>) -> Frame {
        Frame {
            columns: runs.iter().map(|r| r.columns).sum(),
            rows: 1,
            cursor_row: 0,
            cursor_column: 0,
            cursor_shape: Caret::Hidden,
            cursor_visible: false,
            alternate_screen: false,
            viewport_offset: 0,
            history_lines: 0,
            title: String::new(),
            lines: vec![Row { runs }],
        }
    }

    fn styled(text: &str, columns: u32) -> Run {
        Run {
            text: text.to_string(),
            columns,
            style: RunStyle::default(),
        }
    }

    #[test]
    fn runs_land_on_the_grid() {
        let frame = one_row(vec![
            styled("hello", 5),
            styled("world", 5),
        ]);
        let list = prepare(&frame, &metrics(), &Palette::dark());
        assert_eq!(list.texts.len(), 2);
        assert_eq!(list.texts[0].x, 0.0);
        assert_eq!(list.texts[0].width, 40.0);
        assert_eq!(list.texts[1].x, 40.0);
        assert_eq!(list.texts[1].width, 40.0);
    }

    #[test]
    fn a_row_of_runs_never_covers_more_columns_than_the_screen_has() {
        let frame = one_row(vec![styled("ab中文cd", 8)]);
        // The frame builder already split on width changes; this asserts the
        // layout places what it was given exactly as wide as it claims.
        let list = prepare(&frame, &metrics(), &Palette::dark());
        assert_eq!(list.texts[0].width, 8.0 * metrics().cell_width);
    }

    #[test]
    fn own_background_becomes_a_rect() {
        let mut run = styled("hi", 2);
        run.style.background = Paint::Named(Name::Red);
        let list = prepare(&one_row(vec![run]), &metrics(), &Palette::dark());
        assert_eq!(list.rects.len(), 1);
        assert_eq!(list.rects[0].color, Palette::dark().normal[1]);
        assert_eq!(list.texts.len(), 1);
    }

    #[test]
    fn page_background_is_not_a_rect() {
        let list = prepare(&one_row(vec![styled("hi", 2)]), &metrics(), &Palette::dark());
        assert!(list.rects.is_empty());
    }

    #[test]
    fn inverse_swaps_colours() {
        let mut run = styled("x", 1);
        run.style.inverse = true;
        let palette = Palette::dark();
        let list = prepare(&one_row(vec![run]), &metrics(), &palette);
        assert_eq!(list.texts[0].color, palette.background);
        assert_eq!(list.rects[0].color, palette.foreground);
    }

    #[test]
    fn hidden_text_keeps_its_background() {
        let mut run = styled("secret", 6);
        run.style.hidden = true;
        run.style.background = Paint::Named(Name::Blue);
        let list = prepare(&one_row(vec![run]), &metrics(), &Palette::dark());
        assert_eq!(list.rects.len(), 1, "the cell must not become a hole");
        assert!(list.texts.is_empty());
    }

    #[test]
    fn whitespace_is_not_drawn_as_text() {
        let list = prepare(&one_row(vec![styled("    ", 4)]), &metrics(), &Palette::dark());
        assert!(list.texts.is_empty());
    }

    #[test]
    fn dim_text_keeps_its_colour_with_alpha() {
        let mut run = styled("x", 1);
        run.style.dim = true;
        let palette = Palette::dark();
        let list = prepare(&one_row(vec![run]), &metrics(), &palette);
        assert_eq!(list.texts[0].color.alpha, 0.6);
        assert_eq!(list.texts[0].color.red, palette.foreground.red);
    }

    #[test]
    fn cursor_shapes_are_boxes() {
        for (shape, expect) in [
            (Caret::Block, (8.0, 16.0)),
            (Caret::Underline, (8.0, 2.0)),
            (Caret::Beam, (2.0, 16.0)),
        ] {
            let frame = Frame {
                cursor_shape: shape,
                cursor_visible: true,
                cursor_row: 2,
                cursor_column: 3,
                ..one_row(vec![styled("x", 1)])
            };
            // one_row only has one row; give the cursor somewhere to sit.
            let frame = Frame {
                rows: 3,
                lines: vec![frame.lines[0].clone(), frame.lines[0].clone(), frame.lines[0].clone()],
                ..frame
            };
            let list = prepare(&frame, &metrics(), &Palette::dark());
            let cursor = list.cursor.expect("cursor drawn");
            assert_eq!((cursor.width, cursor.height), expect, "shape {shape:?}");
            assert_eq!(cursor.x, 24.0);
            assert_eq!(cursor.y, 32.0 + if shape == Caret::Underline { 14.0 } else { 0.0 });
            assert!((cursor.color.alpha - 0.75).abs() < 1e-6);
        }
    }

    #[test]
    fn hidden_or_invisible_cursor_is_absent() {
        let mut hidden_shape = one_row(vec![styled("x", 1)]);
        hidden_shape.cursor_visible = true;
        hidden_shape.cursor_shape = Caret::Hidden;
        assert!(prepare(&hidden_shape, &metrics(), &Palette::dark()).cursor.is_none());

        let mut invisible = one_row(vec![styled("x", 1)]);
        invisible.cursor_visible = false;
        invisible.cursor_shape = Caret::Block;
        assert!(prepare(&invisible, &metrics(), &Palette::dark()).cursor.is_none());
    }

    fn cell(column: u32, row: u32) -> Cell {
        Cell { column, row }
    }

    #[test]
    fn a_selection_paints_a_tint_over_its_cells() {
        let frame = one_row(vec![styled("hello", 5)]);
        let overlay = Overlay {
            selection: Some((cell(1, 0), cell(3, 0))),
            selection_color: Rgba::new(0.2, 0.5, 1.0, 0.12),
            ..Overlay::default()
        };
        let list = prepare_with_overlay(&frame, &metrics(), &Palette::dark(), &overlay);

        let selection = list
            .rects
            .iter()
            .find(|r| (r.color.alpha - 0.12).abs() < 1e-6)
            .expect("selection rect");
        assert_eq!(selection.x, 8.0);
        assert_eq!(selection.width, 24.0, "three columns");
    }

    #[test]
    fn a_selection_crosses_rows() {
        let frame = Frame {
            columns: 10,
            rows: 3,
            cursor_row: 0,
            cursor_column: 0,
            cursor_shape: Caret::Hidden,
            cursor_visible: false,
            alternate_screen: false,
            viewport_offset: 0,
            history_lines: 0,
            title: String::new(),
            lines: vec![
                Row { runs: vec![styled("aaaaaaaaaa", 10)] },
                Row { runs: vec![styled("bbbbbbbbbb", 10)] },
                Row { runs: vec![styled("cccccccccc", 10)] },
            ],
        };
        let overlay = Overlay {
            // From (8, 0) to (2, 2): three rows, partial first and last.
            selection: Some((cell(8, 0), cell(2, 2))),
            selection_color: Rgba::new(1.0, 1.0, 1.0, 0.12),
            ..Overlay::default()
        };
        let list = prepare_with_overlay(&frame, &metrics(), &Palette::dark(), &overlay);
        let rects: Vec<_> = list
            .rects
            .iter()
            .filter(|r| (r.color.alpha - 0.12).abs() < 1e-6)
            .collect();
        assert_eq!(rects.len(), 3, "one rect per row");
        assert_eq!(rects[0].width, 2.0 * 8.0, "columns 8..end on the first row");
        assert_eq!(rects[1].width, 10.0 * 8.0, "the middle row is whole");
        assert_eq!(rects[2].x, 0.0, "the last row starts at the left edge");
    }

    #[test]
    fn a_link_underline_is_solid_when_confirmed_and_dashed_when_not() {
        let frame = one_row(vec![styled("src/main.rs", 11)]);
        let mut confirmed = Overlay {
            link_color: Rgba::new(0.3, 0.6, 1.0, 1.0),
            ..Overlay::default()
        };
        confirmed.link_underlines.push(LinkUnderline {
            span: crate::draw::CellSpan { row: 0, start: 0, end: 11 },
            confirmed: true,
        });
        let solid = prepare_with_overlay(&frame, &metrics(), &Palette::dark(), &confirmed);
        let rules: Vec<_> = solid.rects.iter().filter(|r| r.height == 1.0).collect();
        assert_eq!(rules.len(), 1, "a confirmed underline is one rule");

        let mut dashed = confirmed.clone();
        dashed.link_underlines[0].confirmed = false;
        let dotted = prepare_with_overlay(&frame, &metrics(), &Palette::dark(), &dashed);
        let rules: Vec<_> = dotted.rects.iter().filter(|r| r.height == 1.0).collect();
        assert!(rules.len() > 1, "a dotted underline is several dashes");
    }
}
