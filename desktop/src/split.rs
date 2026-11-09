//! Panes that share a tab: the Mac `WorkspaceSplit`, laid out in points.
//!
//! A leaf is one terminal. A branch holds two children in visual order —
//! left then right, or top then bottom — and the first child's share. The
//! tree is a value: every change returns a new one.

use tether_ui::{Chrome, Rect};

/// Stable for the life of a terminal, across splits and rearrangement.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct PaneId(pub u64);

/// The side a new pane goes on.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Direction {
    Left,
    Right,
    Up,
    Down,
}

impl Direction {
    /// Side by side, with a vertical divider.
    pub fn horizontal(self) -> bool {
        matches!(self, Self::Left | Self::Right)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum Split {
    Pane(PaneId),
    Branch { direction: Direction, first: Box<Split>, second: Box<Split>, fraction: f32 },
}

/// Which child, from the root down to a branch.
pub type Path = Vec<bool>;

impl Split {
    pub fn ids(&self) -> Vec<PaneId> {
        match self {
            Self::Pane(id) => vec![*id],
            Self::Branch { first, second, .. } => {
                let mut ids = first.ids();
                ids.extend(second.ids());
                ids
            }
        }
    }

    pub fn contains(&self, id: PaneId) -> bool {
        match self {
            Self::Pane(current) => *current == id,
            Self::Branch { first, second, .. } => first.contains(id) || second.contains(id),
        }
    }

    pub fn replacing(&self, id: PaneId, with: &Split) -> Split {
        match self {
            Self::Pane(current) if *current == id => with.clone(),
            Self::Pane(_) => self.clone(),
            Self::Branch { direction, first, second, fraction } => Self::Branch {
                direction: *direction,
                first: Box::new(first.replacing(id, with)),
                second: Box::new(second.replacing(id, with)),
                fraction: *fraction,
            },
        }
    }

    /// The tree without `id`. A branch left with one child becomes that child.
    pub fn removing(&self, id: PaneId) -> Option<Split> {
        match self {
            Self::Pane(current) => (*current != id).then(|| self.clone()),
            Self::Branch { direction, first, second, fraction } => {
                match (first.removing(id), second.removing(id)) {
                    (Some(a), Some(b)) => Some(Self::Branch {
                        direction: *direction,
                        first: Box::new(a),
                        second: Box::new(b),
                        fraction: *fraction,
                    }),
                    (a, b) => a.or(b),
                }
            }
        }
    }

    /// `new` beside `beside`, half and half, on the side `direction` names
    /// (`TabSet.split`). A `beside` not in the tree leaves it unchanged.
    pub fn splitting(&self, beside: PaneId, new: PaneId, direction: Direction) -> Split {
        let (first, second) = match direction {
            Direction::Left | Direction::Up => (new, beside),
            Direction::Right | Direction::Down => (beside, new),
        };
        let pair = Self::Branch {
            direction,
            first: Box::new(Self::Pane(first)),
            second: Box::new(Self::Pane(second)),
            fraction: 0.5,
        };
        self.replacing(beside, &pair)
    }

    /// The branch at `path` with a new first share. Any other path changes nothing.
    pub fn with_fraction(&self, path: &[bool], value: f32) -> Split {
        match (self, path.split_first()) {
            (Self::Branch { direction, first, second, .. }, None) => Self::Branch {
                direction: *direction,
                first: first.clone(),
                second: second.clone(),
                fraction: value,
            },
            (Self::Branch { direction, first, second, fraction }, Some((&side, rest))) => {
                let (first, second) = if side {
                    (first.clone(), Box::new(second.with_fraction(rest, value)))
                } else {
                    (Box::new(first.with_fraction(rest, value)), second.clone())
                };
                Self::Branch { direction: *direction, first, second, fraction: *fraction }
            }
            _ => self.clone(),
        }
    }

    pub fn layout(&self, rect: Rect) -> Layout {
        let mut layout = Layout::default();
        place(self, rect, &mut Vec::new(), &mut layout);
        layout
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Layout {
    pub panes: Vec<(PaneId, Rect)>,
    pub dividers: Vec<Divider>,
}

/// A hairline between two children, and the wider grab area around it.
#[derive(Clone, Debug, PartialEq)]
pub struct Divider {
    pub line: Rect,
    pub handle: Rect,
    pub path: Path,
    pub horizontal: bool,
    /// The branch's whole rect, which a drag measures against.
    pub span: Rect,
}

impl Divider {
    /// The first child's share with the divider under the pointer, clamped
    /// the same way the layout clamps it.
    pub fn fraction_at(&self, x: f32, y: f32) -> f32 {
        let (origin, extent, at) = if self.horizontal {
            (self.span.x, self.span.width, x)
        } else {
            (self.span.y, self.span.height, y)
        };
        let usable = extent - Chrome::HAIRLINE;
        if usable <= 0.0 {
            return 0.5;
        }
        let minimum = minimum(self.horizontal);
        length((at - origin) / usable, usable, minimum) / usable
    }
}

/// Width keeps a readable line; height keeps the pane's header and a few rows.
fn minimum(horizontal: bool) -> f32 {
    if horizontal { 120.0 } else { Chrome::TAB + 48.0 }
}

/// The first child's length. Below the minimum, both children share what is left.
fn length(fraction: f32, usable: f32, minimum: f32) -> f32 {
    if usable <= 0.0 {
        return 0.0;
    }
    let floor = minimum.min(usable / 2.0);
    let fraction = if fraction.is_finite() { fraction } else { 0.5 };
    (fraction * usable).clamp(floor, usable - floor)
}

fn place(split: &Split, rect: Rect, path: &mut Path, layout: &mut Layout) {
    let (direction, first, second, fraction) = match split {
        Split::Pane(id) => {
            layout.panes.push((*id, rect));
            return;
        }
        Split::Branch { direction, first, second, fraction } => {
            (direction, first, second, fraction)
        }
    };
    let horizontal = direction.horizontal();
    let extent = if horizontal { rect.width } else { rect.height };
    let usable = (extent - Chrome::HAIRLINE).max(0.0);
    let size = length(*fraction, usable, minimum(horizontal));
    let rest = usable - size;
    let (a, line, b) = if horizontal {
        (
            Rect { width: size, ..rect },
            Rect { x: rect.x + size, width: Chrome::HAIRLINE, ..rect },
            Rect { x: rect.x + size + Chrome::HAIRLINE, width: rest, ..rect },
        )
    } else {
        (
            Rect { height: size, ..rect },
            Rect { y: rect.y + size, height: Chrome::HAIRLINE, ..rect },
            Rect { y: rect.y + size + Chrome::HAIRLINE, height: rest, ..rect },
        )
    };
    let grab = (Chrome::COLUMN_HANDLE - Chrome::HAIRLINE) / 2.0;
    let handle = if horizontal {
        Rect { x: line.x - grab, width: Chrome::COLUMN_HANDLE, ..line }
    } else {
        Rect { y: line.y - grab, height: Chrome::COLUMN_HANDLE, ..line }
    };
    layout.dividers.push(Divider { line, handle, path: path.clone(), horizontal, span: rect });
    path.push(false);
    place(first, a, path, layout);
    path.pop();
    path.push(true);
    place(second, b, path, layout);
    path.pop();
}

#[cfg(test)]
mod tests {
    use super::*;

    const A: PaneId = PaneId(1);
    const B: PaneId = PaneId(2);
    const C: PaneId = PaneId(3);

    fn rect(x: f32, y: f32, width: f32, height: f32) -> Rect {
        Rect { x, y, width, height }
    }

    fn right(a: PaneId, b: PaneId) -> Split {
        Split::Pane(a).splitting(a, b, Direction::Right)
    }

    #[test]
    fn a_split_puts_the_new_pane_on_the_named_side() {
        assert_eq!(right(A, B).ids(), [A, B]);
        assert_eq!(Split::Pane(A).splitting(A, B, Direction::Left).ids(), [B, A]);
    }

    #[test]
    fn splitting_a_pane_nests_inside_its_branch() {
        let split = right(A, B).splitting(A, C, Direction::Down);
        assert_eq!(split.ids(), [A, C, B]);
        let layout = split.layout(rect(0.0, 0.0, 1001.0, 601.0));
        assert_eq!(layout.panes[0], (A, rect(0.0, 0.0, 500.0, 300.0)));
        assert_eq!(layout.panes[1], (C, rect(0.0, 301.0, 500.0, 300.0)));
        assert_eq!(layout.panes[2], (B, rect(501.0, 0.0, 500.0, 601.0)));
        assert_eq!(layout.dividers.len(), 2);
        assert_eq!(layout.dividers[1].path, vec![false]);
    }

    #[test]
    fn removing_folds_the_branch() {
        let split = right(A, B).splitting(B, C, Direction::Down);
        assert_eq!(split.removing(C), Some(right(A, B)));
        assert_eq!(right(A, B).removing(B), Some(Split::Pane(A)));
        assert_eq!(Split::Pane(A).removing(A), None);
    }

    #[test]
    fn a_fraction_is_clamped_to_the_minimum_and_follows_the_pointer() {
        let split = right(A, B).with_fraction(&[], 0.01);
        let layout = split.layout(rect(0.0, 0.0, 1001.0, 600.0));
        assert_eq!(layout.panes[0].1.width, 120.0);
        let divider = &layout.dividers[0];
        assert_eq!(divider.fraction_at(250.0, 10.0), 0.25);
        assert_eq!(divider.fraction_at(990.0, 10.0), 880.0 / 1000.0);
        assert_eq!(divider.handle.width, Chrome::COLUMN_HANDLE);
    }

    #[test]
    fn a_small_rect_shares_what_is_left() {
        let split = Split::Pane(A).splitting(A, B, Direction::Down);
        let layout = split.layout(rect(0.0, 0.0, 400.0, 101.0));
        assert_eq!(layout.panes[0].1.height, 50.0);
        assert_eq!(layout.panes[1].1.height, 50.0);
    }

    #[test]
    fn unknown_panes_and_paths_change_nothing() {
        let split = right(A, B);
        assert_eq!(split.splitting(C, PaneId(9), Direction::Up), split);
        assert_eq!(split.with_fraction(&[true, true], 0.3), split);
    }
}
