//! Where the grid sits on a surface larger than it, and what fills the rest.
//!
//! A surface is rarely a whole number of cells. Put at the corner, the grid
//! leaves every spare pixel along the bottom and the right, and a margin the
//! consumer asked to be even is not. Centred, the spare pixels split evenly.
//!
//! The margin is not a frame either. A program that paints its own
//! background paints the cells, not the margin, and a band of the page's
//! colour then runs round its screen. So an edge cell's background carries on
//! to the surface's edge, as Ghostty's `window-padding-color = extend` does,
//! and the program's screen reaches the window's.
//!
//! A status line is the exception. It is one row in a colour the row beside
//! it does not use, and carrying that colour through the margin draws a
//! second, empty bar. That row still reaches the side edges. The margin
//! past it stays the page.

use crate::draw::{BgRect, DrawList, Rgba};

/// The surface a grid is placed on, in the surface's pixels.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Placement {
    /// The least distance between the grid and each edge.
    pub inset: f32,
    pub width: f32,
    pub height: f32,
}

impl Placement {
    /// Where the grid's top-left corner goes. Whole pixels, so a cell edge
    /// stays on a pixel edge.
    pub fn origin(&self, grid_width: f32, grid_height: f32) -> (f32, f32) {
        (centred(self.width, grid_width, self.inset), centred(self.height, grid_height, self.inset))
    }
}

/// `inset` from the start, plus half of what is left once both insets and the
/// grid are taken out. A grid wider than its room starts at the inset.
pub fn centred(available: f32, used: f32, inset: f32) -> f32 {
    inset + ((available - 2.0 * inset - used).max(0.0) / 2.0).floor()
}

/// The colour painted at the row's left edge. A cell drawn as the page has
/// no rect, so the answer is `None` rather than the page colour itself.
fn left_color(row: &DrawList) -> Option<Rgba> {
    row.rects
        .iter()
        .rev()
        .find(|rect| rect.x <= 0.5 && rect.x + rect.width > 0.5)
        .map(|rect| rect.color)
}

/// Whether `row` is the screen continuing, judged against the row beside it.
///
/// The same colour, including the page on both, is one screen and may fill
/// the margin. A different colour is a status line.
fn continues(row: &DrawList, neighbour: &DrawList) -> bool {
    left_color(row) == left_color(neighbour)
}

/// Rects that carry each edge cell's background out to the surface's edge.
///
/// `rows` are the cell backgrounds of each row in grid coordinates, the
/// form the layout keeps them in; the rects returned are in the same
/// coordinates, so they reach outside the grid. A cell drawn as the page
/// has no rect, and the page shows in the margin beside it.
///
/// The first and last rows reach past the grid only when they match the row
/// beside them. A status line does not, or the margin would be a second bar.
/// It still reaches the side edges. One row has nothing to differ from, so
/// it reaches every edge.
pub fn extensions(
    rows: &[DrawList],
    grid: (f32, f32),
    origin: (f32, f32),
    placement: &Placement,
    complete: bool,
) -> Vec<BgRect> {
    let (grid_width, grid_height) = grid;
    let left = origin.0;
    let top = origin.1;
    let right = (placement.width - origin.0 - grid_width).max(0.0);
    let bottom = (placement.height - origin.1 - grid_height).max(0.0);
    let last = rows.len().checked_sub(1);
    let mut extended = Vec::new();
    for (index, row) in rows.iter().enumerate() {
        let first_row = index == 0;
        // Only the screen's real last row reaches down. A frame still
        // arriving has fewer rows, and its last one is not the bottom.
        let last_row = complete && Some(index) == last;
        // A single row has no neighbour, so it is the whole screen.
        let extend_above =
            first_row && rows.get(index + 1).map(|next| continues(row, next)).unwrap_or(true);
        let extend_below = last_row
            && index
                .checked_sub(1)
                .and_then(|prev| rows.get(prev))
                .map(|prev| continues(row, prev))
                .unwrap_or(true);
        for rect in &row.rects {
            let BgRect { x, y, width, height, color } = *rect;
            let at_left = x <= 0.5;
            let at_right = x + width >= grid_width - 0.5;
            let mut push = |x: f32, y: f32, width: f32, height: f32| {
                if width > 0.0 && height > 0.0 {
                    extended.push(BgRect { x, y, width, height, color });
                }
            };
            if extend_above {
                push(x, -top, width.min(grid_width - x), top);
            }
            if extend_below {
                push(x, grid_height, width.min(grid_width - x), bottom);
            }
            if at_left {
                push(-left, y, left, height);
                if extend_above {
                    push(-left, -top, left, top);
                }
                if extend_below {
                    push(-left, grid_height, left, bottom);
                }
            }
            if at_right {
                push(grid_width, y, right, height);
                if extend_above {
                    push(grid_width, -top, right, top);
                }
                if extend_below {
                    push(grid_width, grid_height, right, bottom);
                }
            }
        }
    }
    extended
}

impl DrawList {
    /// Moves everything by `(dx, dy)`: grid coordinates to surface ones.
    pub fn translate(&mut self, dx: f32, dy: f32) {
        if dx == 0.0 && dy == 0.0 {
            return;
        }
        for rect in &mut self.rects {
            rect.x += dx;
            rect.y += dy;
        }
        for run in &mut self.texts {
            run.x += dx;
            run.y += dy;
        }
        if let Some(cursor) = &mut self.cursor {
            cursor.x += dx;
            cursor.y += dy;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::draw::Rgba;

    fn painted(rects: &[(f32, f32)], y: f32, color: Rgba) -> DrawList {
        DrawList {
            rects: rects
                .iter()
                .map(|&(x, width)| BgRect { x, y, width, height: 10.0, color })
                .collect(),
            ..DrawList::default()
        }
    }

    fn row(rects: &[(f32, f32)], y: f32) -> DrawList {
        painted(rects, y, Rgba::new(0.1, 0.1, 0.1, 1.0))
    }

    #[test]
    fn the_spare_pixels_split_evenly() {
        // 100 wide, 8 + 8 inset, 80 of grid: 4 spare, 2 each side.
        assert_eq!(centred(100.0, 80.0, 8.0), 10.0);
        // An odd pixel goes to the far side.
        assert_eq!(centred(101.0, 80.0, 8.0), 10.0);
        // A grid larger than its room keeps the inset.
        assert_eq!(centred(50.0, 80.0, 8.0), 8.0);
    }

    #[test]
    fn a_full_screen_background_reaches_every_edge() {
        let placement = Placement { inset: 10.0, width: 120.0, height: 40.0 };
        let rows = [row(&[(0.0, 100.0)], 0.0), row(&[(0.0, 100.0)], 10.0)];
        let origin = placement.origin(100.0, 20.0);
        assert_eq!(origin, (10.0, 10.0));
        let mut list = DrawList {
            rects: rows.iter().flat_map(|r| r.rects.clone()).collect(),
            ..Default::default()
        };
        list.rects.extend(extensions(&rows, (100.0, 20.0), origin, &placement, true));
        list.translate(origin.0, origin.1);
        let covered: f32 = list.rects.iter().map(|r| r.width * r.height).sum();
        assert_eq!(covered, 120.0 * 40.0, "the whole surface, with no overlap");
        let min_x = list.rects.iter().map(|r| r.x).fold(f32::MAX, f32::min);
        let max_x = list.rects.iter().map(|r| r.x + r.width).fold(f32::MIN, f32::max);
        assert_eq!((min_x, max_x), (0.0, 120.0));
    }

    #[test]
    fn only_what_touches_an_edge_is_extended() {
        let placement = Placement { inset: 10.0, width: 120.0, height: 50.0 };
        // Row 0: a highlight in the middle. Row 1 (middle row): touches neither side.
        // Row 2: a band at the left only.
        let rows =
            [row(&[(30.0, 20.0)], 0.0), row(&[(30.0, 20.0)], 10.0), row(&[(0.0, 40.0)], 20.0)];
        let extended = extensions(&rows, (100.0, 30.0), (10.0, 10.0), &placement, true);
        // Up from row 0's highlight, and left of row 2. Row 2's colour is not
        // the page the row above leaves, so it does not continue downward.
        assert_eq!(extended.len(), 2);
        assert!(extended.iter().any(|r| r.x == 30.0 && r.y == -10.0 && r.width == 20.0));
        assert!(extended.iter().any(|r| r.x == -10.0 && r.y == 20.0));
        assert!(extended.iter().all(|r| r.y + r.height <= 30.0), "nothing reaches below the grid");
        assert!(extended.iter().all(|r| r.x + r.width <= 100.0), "nothing reaches the right");
    }

    #[test]
    fn a_status_line_does_not_paint_a_second_row() {
        let placement = Placement { inset: 10.0, width: 120.0, height: 50.0 };
        let page = Rgba::new(0.1, 0.1, 0.1, 1.0);
        let status = Rgba::new(0.16, 0.54, 0.22, 1.0);
        let rows = [
            painted(&[(0.0, 100.0)], 0.0, page),
            painted(&[(0.0, 100.0)], 10.0, page),
            painted(&[(0.0, 100.0)], 20.0, status),
        ];
        let extended = extensions(&rows, (100.0, 30.0), (10.0, 10.0), &placement, true);
        assert!(
            extended.iter().any(|r| r.color == page && r.y < 0.0),
            "the screen still reaches the top"
        );
        assert!(
            extended.iter().all(|r| r.color != status || r.y + r.height <= 30.0),
            "the status colour stays inside the grid"
        );
        assert!(
            extended.iter().any(|r| r.color == status && r.x < 0.0 && r.y == 20.0),
            "the status line still reaches the side edge"
        );
    }

    #[test]
    fn a_status_line_drawn_on_the_page_does_not_fill_the_margin() {
        // What tmux actually paints: the rows above leave the page, and the
        // last row is a solid bar. The margin under it stays the page.
        let placement = Placement { inset: 10.0, width: 120.0, height: 40.0 };
        let status = Rgba::new(0.16, 0.54, 0.22, 1.0);
        let rows = [DrawList::default(), painted(&[(0.0, 100.0)], 10.0, status)];
        let extended = extensions(&rows, (100.0, 20.0), (10.0, 10.0), &placement, true);
        assert!(extended.iter().all(|r| r.y + r.height <= 20.0));
        assert!(extended.iter().any(|r| r.color == status && r.x < 0.0 && r.y == 10.0));
    }

    #[test]
    fn a_status_line_at_the_top_does_not_paint_the_margin() {
        let placement = Placement { inset: 10.0, width: 120.0, height: 50.0 };
        let page = Rgba::new(0.1, 0.1, 0.1, 1.0);
        let status = Rgba::new(0.16, 0.54, 0.22, 1.0);
        let rows = [
            painted(&[(0.0, 100.0)], 0.0, status),
            painted(&[(0.0, 100.0)], 10.0, page),
            painted(&[(0.0, 100.0)], 20.0, page),
        ];
        let extended = extensions(&rows, (100.0, 30.0), (10.0, 10.0), &placement, true);
        assert!(extended.iter().all(|r| r.color != status || r.y >= 0.0));
        assert!(
            extended.iter().any(|r| r.color == page && r.y >= 30.0),
            "the screen still reaches the bottom"
        );
    }

    #[test]
    fn one_row_still_reaches_every_edge() {
        let placement = Placement { inset: 10.0, width: 120.0, height: 40.0 };
        let rows = [row(&[(0.0, 100.0)], 0.0)];
        let extended = extensions(&rows, (100.0, 10.0), (10.0, 10.0), &placement, true);
        assert!(extended.iter().any(|r| r.y < 0.0));
        assert!(extended.iter().any(|r| r.y >= 10.0));
    }

    #[test]
    fn an_incomplete_screen_does_not_reach_the_bottom() {
        let placement = Placement { inset: 10.0, width: 120.0, height: 40.0 };
        let rows = [row(&[(30.0, 20.0)], 0.0)];
        let extended = extensions(&rows, (100.0, 20.0), (10.0, 10.0), &placement, false);
        assert!(extended.iter().all(|r| r.y < 0.0));
    }
}
