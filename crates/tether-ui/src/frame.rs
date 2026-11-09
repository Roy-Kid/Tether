//! Geometry of the workspace, in the Mac window's order.
//!
//! Origin is the top-left of the client area. Y grows downward. Units are
//! points, the same points `Chrome` uses. A rect that would not be visible
//! is omitted. Sizes that do not fit floor at zero; side columns keep the
//! width they were given, and the canvas absorbs the rest.

use crate::Chrome;

/// Axis-aligned rect. A shared edge is not an overlap.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Rect {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

impl Rect {
    fn new(x: f32, y: f32, width: f32, height: f32) -> Self {
        Self { x, y, width, height }
    }

    pub fn contains(self, x: f32, y: f32) -> bool {
        x >= self.x && y >= self.y && x < self.x + self.width && y < self.y + self.height
    }

    pub fn intersects(self, other: Self) -> bool {
        self.x < other.x + other.width
            && other.x < self.x + self.width
            && self.y < other.y + other.height
            && other.y < self.y + self.height
    }

    fn area(self) -> f32 {
        self.width.max(0.0) * self.height.max(0.0)
    }
}

/// Who paints a region.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role {
    /// Shared chrome. This crate paints it.
    Ui,
    /// Cell grid. `tether-render` paints it. This crate leaves it empty.
    Terminal,
    /// Plugin surface, web view or native. The host places it.
    Plugin,
    /// Window chrome the host paints. Traffic lights on a Mac.
    Platform,
}

/// Which band a region is. [`Kind::role`] is the layer that owns it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    TabStrip,
    DragStrip,
    TabSidebar,
    Divider,
    Status,
    Terminal,
    Plugin,
    Platform,
}

impl Kind {
    pub fn role(self) -> Role {
        match self {
            Self::TabStrip | Self::DragStrip | Self::TabSidebar | Self::Divider | Self::Status => {
                Role::Ui
            }
            Self::Terminal => Role::Terminal,
            Self::Plugin => Role::Plugin,
            Self::Platform => Role::Platform,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Region {
    pub kind: Kind,
    pub rect: Rect,
}

impl Region {
    pub fn role(self) -> Role {
        self.kind.role()
    }
}

/// Where the tab list sits. Vertical keeps the top strip and adds a column.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Placement {
    Horizontal,
    Vertical,
}

/// What fills the canvas hole.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Canvas {
    Terminal,
    Plugin,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Side {
    Leading,
    Trailing,
}

/// A pointer target in the chrome. Column handles overlap the canvas by a
/// few points and are not painted, matching the clear grab overlay.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Hit {
    Tab(usize),
    Close(usize),
    NewTab,
    Settings,
    Column(Side),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Tab {
    pub title: String,
    pub selected: bool,
}

impl Tab {
    pub fn new(title: impl Into<String>) -> Self {
        Self { title: title.into(), selected: false }
    }

    pub fn selected(mut self) -> Self {
        self.selected = true;
        self
    }
}

/// Inputs the host already has. Nothing here reads iCloud, the keychain, or a window.
#[derive(Clone, Debug, PartialEq)]
pub struct Workspace {
    pub width: f32,
    pub height: f32,
    pub zen: bool,
    /// `TabSet.showsTabBar` is this and not zen. Zen forces the drag strip.
    pub tab_bar: bool,
    pub placement: Placement,
    pub inspector: bool,
    pub inspector_width: f32,
    pub tab_sidebar_width: f32,
    /// Width of host-painted window chrome inside the client area.
    /// macOS passes [`Chrome::TRAFFIC_LIGHTS`]. Windows passes 0.
    pub leading_reserve: f32,
    pub canvas: Canvas,
    /// The gear on the status bar. It opens the host's settings window.
    pub settings: bool,
}

impl Workspace {
    /// The ordinary Mac workspace: traffic-light reserve, settings gear, terminal hole.
    pub fn mac(width: f32, height: f32) -> Self {
        Self {
            width,
            height,
            zen: false,
            tab_bar: true,
            placement: Placement::Horizontal,
            inspector: false,
            inspector_width: Chrome::INSPECTOR_IDEAL,
            tab_sidebar_width: Chrome::TAB_SIDEBAR_IDEAL,
            leading_reserve: Chrome::TRAFFIC_LIGHTS,
            canvas: Canvas::Terminal,
            settings: true,
        }
    }

    /// The same chrome in a Windows client area. The caption is outside, so
    /// the leading reserve is zero.
    pub fn windows(width: f32, height: f32) -> Self {
        Self { leading_reserve: 0.0, ..Self::mac(width, height) }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Frame {
    pub regions: Vec<Region>,
    pub hits: Vec<(Hit, Rect)>,
}

impl Frame {
    pub fn region(&self, kind: Kind) -> Option<Rect> {
        self.regions.iter().find(|region| region.kind == kind).map(|region| region.rect)
    }

    pub fn regions_of(&self, kind: Kind) -> impl Iterator<Item = Rect> + '_ {
        self.regions.iter().filter(move |region| region.kind == kind).map(|region| region.rect)
    }

    /// Chrome this crate paints. Holes and the host's reserve are absent.
    pub fn painted(&self) -> impl Iterator<Item = &Region> {
        self.regions.iter().filter(|region| region.role() == Role::Ui)
    }

    pub fn hit_test(&self, x: f32, y: f32) -> Option<Hit> {
        self.hits.iter().find(|(_, rect)| rect.contains(x, y)).map(|(hit, _)| *hit)
    }
}

/// Lay out one workspace. Columns keep their clamped width. The canvas floors at zero.
pub fn layout(workspace: &Workspace, tabs: &[Tab]) -> Frame {
    let width = finite_nonneg(workspace.width);
    let height = finite_nonneg(workspace.height);
    let mut frame = Frame { regions: Vec::new(), hits: Vec::new() };

    let top = if workspace.zen { Chrome::TITLEBAR } else { Chrome::TAB };
    let top = top.min(height);
    let status = if workspace.zen { 0.0 } else { Chrome::STATUS.min(height - top) };
    let body_y = top;
    let body_h = (height - top - status).max(0.0);
    let reserve = finite_nonneg(workspace.leading_reserve).min(width);

    let show_tabs = workspace.tab_bar && !workspace.zen;
    let horizontal = show_tabs && workspace.placement == Placement::Horizontal;
    let sidebar = if show_tabs && workspace.placement == Placement::Vertical {
        clamp_range(workspace.tab_sidebar_width, Chrome::TAB_SIDEBAR_MIN, Chrome::TAB_SIDEBAR_MAX)
    } else {
        0.0
    };
    let inspector = if workspace.inspector && !workspace.zen {
        clamp_range(workspace.inspector_width, Chrome::INSPECTOR_MIN, Chrome::INSPECTOR_MAX)
    } else {
        0.0
    };

    push(&mut frame, Kind::Platform, Rect::new(0.0, 0.0, reserve, top));
    let strip = Rect::new(reserve, 0.0, (width - reserve).max(0.0), top);
    push(&mut frame, if horizontal { Kind::TabStrip } else { Kind::DragStrip }, strip);

    let mut x = 0.0;
    if sidebar > 0.0 {
        let column = Rect::new(0.0, body_y, sidebar, body_h);
        push(&mut frame, Kind::TabSidebar, column);
        x = sidebar;
        let divider = Rect::new(x, body_y, Chrome::HAIRLINE, body_h);
        push(&mut frame, Kind::Divider, divider);
        push_handle(&mut frame, Side::Leading, divider);
        x += Chrome::HAIRLINE;
    }

    let span = |column: f32| {
        if column > 0.0 { column + Chrome::HAIRLINE } else { 0.0 }
    };
    let canvas_w = (width - span(sidebar) - span(inspector)).max(0.0);
    let canvas = Rect::new(x, body_y, canvas_w, body_h);
    let canvas_kind = match workspace.canvas {
        Canvas::Terminal => Kind::Terminal,
        Canvas::Plugin => Kind::Plugin,
    };
    // A collapsed width is still the slot: the host sizes the grid to zero.
    // No height means there is no row to put it in.
    if canvas.height > 0.0 {
        frame.regions.push(Region { kind: canvas_kind, rect: canvas });
    }
    x += canvas_w;

    if inspector > 0.0 {
        let divider = Rect::new(x, body_y, Chrome::HAIRLINE, body_h);
        push(&mut frame, Kind::Divider, divider);
        push_handle(&mut frame, Side::Trailing, divider);
        x += Chrome::HAIRLINE;
        push(&mut frame, Kind::Plugin, Rect::new(x, body_y, inspector, body_h));
    }

    let status_rect = Rect::new(0.0, height - status, width, status);
    push(&mut frame, Kind::Status, status_rect);

    if horizontal {
        place_row(&mut frame, tabs, strip, true, Chrome::TAB, Chrome::ICON + Chrome::SPACE_INSET);
    } else if show_tabs && let Some(column) = frame.region(Kind::TabSidebar) {
        place_row(
            &mut frame,
            tabs,
            column,
            false,
            Chrome::TAB_SIDEBAR_ROW,
            Chrome::ICON + Chrome::SPACE_SMALL,
        );
    }

    if workspace.settings {
        let gear = Rect::new(
            width - Chrome::SPACE_INSET - Chrome::ICON,
            status_rect.y,
            Chrome::ICON,
            status_rect.height,
        );
        if status_rect.contains(gear.x, gear.y) && gear.x >= status_rect.x {
            frame.hits.push((Hit::Settings, gear));
        }
    }

    frame
}

fn place_row(
    frame: &mut Frame,
    tabs: &[Tab],
    content: Rect,
    horizontal: bool,
    row: f32,
    close_width: f32,
) {
    let mut cursor = if horizontal { content.x } else { content.y };
    for (index, tab) in tabs.iter().enumerate() {
        let chip = if horizontal {
            Rect::new(cursor, content.y, Chrome::TAB_TITLE_WIDTH, content.height)
        } else {
            Rect::new(content.x, cursor, content.width, row)
        };
        if let Some(visible) = intersection(chip, content) {
            if tab.selected {
                let close = Rect::new(
                    chip.x + chip.width - close_width,
                    chip.y,
                    close_width.min(chip.width),
                    chip.height,
                );
                if let Some(close) = intersection(close, content) {
                    // Ahead of the tab, so the close box wins the points they share.
                    frame.hits.push((Hit::Close(index), close));
                }
            }
            frame.hits.push((Hit::Tab(index), visible));
        }
        cursor += if horizontal { Chrome::TAB_TITLE_WIDTH + Chrome::SPACE_SMALL } else { row };
    }
    let button = if horizontal {
        Rect::new(cursor, content.y, Chrome::TAB, content.height)
    } else {
        Rect::new(content.x, cursor, content.width, row)
    };
    if let Some(button) = intersection(button, content) {
        frame.hits.push((Hit::NewTab, button));
    }
}

fn intersection(a: Rect, b: Rect) -> Option<Rect> {
    let x = a.x.max(b.x);
    let y = a.y.max(b.y);
    let width = (a.x + a.width).min(b.x + b.width) - x;
    let height = (a.y + a.height).min(b.y + b.height) - y;
    if width > 0.0 && height > 0.0 { Some(Rect::new(x, y, width, height)) } else { None }
}

fn push(frame: &mut Frame, kind: Kind, rect: Rect) {
    if rect.area() > 0.0 {
        frame.regions.push(Region { kind, rect });
    }
}

fn push_handle(frame: &mut Frame, side: Side, divider: Rect) {
    if divider.area() == 0.0 {
        return;
    }
    let extra = (Chrome::COLUMN_HANDLE - Chrome::HAIRLINE) / 2.0;
    frame.hits.push((
        Hit::Column(side),
        Rect::new(divider.x - extra, divider.y, Chrome::COLUMN_HANDLE, divider.height),
    ));
}

fn finite_nonneg(value: f32) -> f32 {
    if value.is_finite() { value.max(0.0) } else { 0.0 }
}

fn clamp_range(value: f32, min: f32, max: f32) -> f32 {
    if !value.is_finite() {
        return min;
    }
    value.clamp(min, max)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mac() -> Workspace {
        Workspace::mac(Chrome::WINDOW_WIDTH, Chrome::WINDOW_HEIGHT)
    }

    fn kind(frame: &Frame, kind: Kind) -> Rect {
        frame.region(kind).unwrap_or_else(|| panic!("missing {kind:?}"))
    }

    #[test]
    fn a_mac_window_matches_the_workspace_stack() {
        let frame = layout(&mac(), &[]);
        assert_eq!(kind(&frame, Kind::Platform), Rect::new(0.0, 0.0, 76.0, 32.0));
        assert_eq!(kind(&frame, Kind::TabStrip), Rect::new(76.0, 0.0, 1024.0, 32.0));
        assert_eq!(kind(&frame, Kind::Terminal), Rect::new(0.0, 32.0, 1100.0, 644.0));
        assert_eq!(kind(&frame, Kind::Status), Rect::new(0.0, 676.0, 1100.0, 24.0));
        assert!(frame.region(Kind::Plugin).is_none());
        assert!(frame.region(Kind::TabSidebar).is_none());
        assert!(frame.region(Kind::DragStrip).is_none());
    }

    #[test]
    fn zen_keeps_a_drag_strip_and_drops_the_status_and_the_inspector() {
        let mut workspace = mac();
        workspace.zen = true;
        workspace.inspector = true;
        workspace.placement = Placement::Vertical;
        let frame = layout(&workspace, &[Tab::new("shell").selected()]);
        assert!(frame.region(Kind::Status).is_none());
        assert!(frame.region(Kind::Plugin).is_none());
        assert!(frame.region(Kind::TabSidebar).is_none());
        assert!(frame.region(Kind::TabStrip).is_none());
        assert_eq!(kind(&frame, Kind::DragStrip), Rect::new(76.0, 0.0, 1024.0, 32.0));
        assert_eq!(kind(&frame, Kind::Terminal), Rect::new(0.0, 32.0, 1100.0, 668.0));
        assert!(frame.hits.iter().all(|(hit, _)| !matches!(hit, Hit::Tab(_) | Hit::NewTab)));
    }

    #[test]
    fn a_hidden_tab_bar_keeps_the_strip_and_the_status() {
        let mut workspace = mac();
        workspace.tab_bar = false;
        let frame = layout(&workspace, &[Tab::new("shell")]);
        assert_eq!(kind(&frame, Kind::DragStrip).height, Chrome::TAB);
        assert!(frame.region(Kind::Status).is_some());
        assert!(frame.hit_test(80.0, 10.0).is_none());
    }

    #[test]
    fn vertical_tabs_keep_the_top_strip_and_a_leading_column() {
        let mut workspace = mac();
        workspace.placement = Placement::Vertical;
        let frame = layout(&workspace, &[]);
        assert_eq!(kind(&frame, Kind::DragStrip), Rect::new(76.0, 0.0, 1024.0, 32.0));
        assert_eq!(kind(&frame, Kind::TabSidebar), Rect::new(0.0, 32.0, 220.0, 644.0));
        assert_eq!(
            frame.regions_of(Kind::Divider).next(),
            Some(Rect::new(220.0, 32.0, 1.0, 644.0))
        );
        assert_eq!(kind(&frame, Kind::Terminal), Rect::new(221.0, 32.0, 879.0, 644.0));
    }

    #[test]
    fn the_inspector_sits_under_the_strip_and_clamps() {
        let mut workspace = mac();
        workspace.inspector = true;
        let frame = layout(&workspace, &[]);
        assert_eq!(kind(&frame, Kind::Terminal), Rect::new(0.0, 32.0, 819.0, 644.0));
        assert_eq!(kind(&frame, Kind::Plugin), Rect::new(820.0, 32.0, 280.0, 644.0));
        assert!(!kind(&frame, Kind::Plugin).intersects(kind(&frame, Kind::TabStrip)));
        assert!(!kind(&frame, Kind::Plugin).intersects(kind(&frame, Kind::Status)));

        workspace.inspector_width = 999.0;
        assert_eq!(kind(&layout(&workspace, &[]), Kind::Plugin).width, Chrome::INSPECTOR_MAX);
        workspace.inspector_width = 10.0;
        assert_eq!(kind(&layout(&workspace, &[]), Kind::Plugin).width, Chrome::INSPECTOR_MIN);
        workspace.inspector_width = f32::NAN;
        assert_eq!(kind(&layout(&workspace, &[]), Kind::Plugin).width, Chrome::INSPECTOR_MIN);
    }

    #[test]
    fn both_columns_leave_the_canvas_the_remainder() {
        let mut workspace = mac();
        workspace.placement = Placement::Vertical;
        workspace.inspector = true;
        let frame = layout(&workspace, &[]);
        assert_eq!(kind(&frame, Kind::TabSidebar).width, 220.0);
        assert_eq!(kind(&frame, Kind::Terminal), Rect::new(221.0, 32.0, 598.0, 644.0));
        assert_eq!(kind(&frame, Kind::Plugin), Rect::new(820.0, 32.0, 280.0, 644.0));
    }

    #[test]
    fn a_window_smaller_than_the_columns_floors_the_canvas() {
        let mut workspace = mac();
        workspace.width = 200.0;
        workspace.height = 40.0;
        workspace.inspector = true;
        let frame = layout(&workspace, &[]);
        assert!(frame.region(Kind::Terminal).is_none());
        assert_eq!(kind(&frame, Kind::Status).height, 8.0);
        assert!(frame.region(Kind::Plugin).is_none());

        workspace.height = Chrome::WINDOW_HEIGHT;
        let frame = layout(&workspace, &[]);
        assert_eq!(kind(&frame, Kind::Terminal), Rect::new(0.0, 32.0, 0.0, 644.0));
        assert_eq!(kind(&frame, Kind::Plugin).x, 1.0);
    }

    #[test]
    fn windows_has_no_traffic_light_reserve() {
        let frame = layout(&Workspace::windows(1100.0, 700.0), &[]);
        assert!(frame.region(Kind::Platform).is_none());
        assert_eq!(kind(&frame, Kind::TabStrip), Rect::new(0.0, 0.0, 1100.0, 32.0));
        assert_eq!(kind(&frame, Kind::Terminal).width, 1100.0);
    }

    #[test]
    fn a_plugin_standing_in_for_the_shell_is_not_a_terminal_hole() {
        let mut workspace = mac();
        workspace.canvas = Canvas::Plugin;
        let frame = layout(&workspace, &[]);
        assert!(frame.region(Kind::Terminal).is_none());
        assert_eq!(kind(&frame, Kind::Plugin), Rect::new(0.0, 32.0, 1100.0, 644.0));
    }

    #[test]
    fn painted_chrome_does_not_cover_a_hole() {
        let mut workspace = mac();
        workspace.placement = Placement::Vertical;
        workspace.inspector = true;
        let frame = layout(&workspace, &[Tab::new("shell").selected()]);
        let holes: Vec<_> = frame
            .regions
            .iter()
            .filter(|region| region.role() != Role::Ui)
            .map(|region| region.rect)
            .collect();
        for painted in frame.painted() {
            assert!(
                holes.iter().all(|hole| !painted.rect.intersects(*hole)),
                "{:?} covers a hole",
                painted.kind
            );
        }
        assert!(frame.painted().any(|region| region.kind == Kind::Divider));
        assert!(frame.painted().all(|region| region.role() == Role::Ui));
    }

    #[test]
    fn a_tab_and_its_close_box_share_the_title_width() {
        let tabs = [Tab::new("local"), Tab::new("figma").selected()];
        let frame = layout(&mac(), &tabs);
        assert_eq!(frame.hit_test(76.0, 8.0), Some(Hit::Tab(0)));
        assert_eq!(frame.hit_test(76.0 + 144.0 + 4.0, 8.0), Some(Hit::Tab(1)));
        assert_eq!(frame.hit_test(76.0 + 148.0 + 144.0 - 1.0, 8.0), Some(Hit::Close(1)));
        let new_tab_x = 76.0 + 2.0 * 144.0 + 2.0 * 4.0;
        assert_eq!(frame.hit_test(new_tab_x, 8.0), Some(Hit::NewTab));
        assert_eq!(frame.hit_test(10.0, 8.0), None);
        assert_eq!(frame.hit_test(400.0, 100.0), None);
    }

    #[test]
    fn a_vertical_tab_uses_the_taller_row() {
        let mut workspace = mac();
        workspace.placement = Placement::Vertical;
        let frame = layout(&workspace, &[Tab::new("shell").selected()]);
        assert_eq!(frame.hit_test(10.0, 32.0), Some(Hit::Tab(0)));
        assert_eq!(frame.hit_test(210.0, 40.0), Some(Hit::Close(0)));
        assert_eq!(frame.hit_test(10.0, 32.0 + 36.0), Some(Hit::NewTab));
    }

    #[test]
    fn the_column_handle_is_grabbable_and_unpainted() {
        let mut workspace = mac();
        workspace.inspector = true;
        let frame = layout(&workspace, &[]);
        assert_eq!(frame.hit_test(819.0, 100.0), Some(Hit::Column(Side::Trailing)));
        assert_eq!(frame.hit_test(817.0, 100.0), Some(Hit::Column(Side::Trailing)));
        assert_eq!(frame.hit_test(815.0, 100.0), None);
        assert!(frame.painted().all(|region| region.kind != Kind::Terminal));
    }

    #[test]
    fn settings_sits_on_the_trailing_edge_of_the_status_bar() {
        let frame = layout(&mac(), &[]);
        assert_eq!(frame.hit_test(1100.0 - 12.0 - 18.0, 676.0), Some(Hit::Settings));
        let mut workspace = mac();
        workspace.zen = true;
        assert!(layout(&workspace, &[]).hit_test(1100.0 - 20.0, 690.0).is_none());
    }

    #[test]
    fn a_degenerate_window_is_empty() {
        let frame = layout(&Workspace::mac(-1.0, f32::NAN), &[]);
        assert!(frame.regions.is_empty());
        assert!(frame.hits.is_empty());
    }
}
