//! A menu at the pointer, as AppKit draws one (the Mac app's tab menu is an
//! `NSMenu`). Blocks while it is open and returns the chosen entry's index.

use std::cell::Cell;

use objc2::rc::Retained;
use objc2::runtime::AnyObject;
use objc2::{MainThreadMarker, MainThreadOnly, define_class, msg_send, sel};
use objc2_app_kit::{NSControlStateValueOn, NSEvent, NSMenu, NSMenuItem};
use objc2_foundation::{NSObject, NSObjectProtocol, NSString};
use tether_desktop::tab_menu::Entry;

thread_local! {
    static CHOSEN: Cell<Option<isize>> = const { Cell::new(None) };
}

define_class!(
    // SAFETY: NSObject has no subclassing requirements, and this class
    // implements no Drop.
    #[unsafe(super(NSObject))]
    #[thread_kind = MainThreadOnly]
    #[name = "TetherMenuTarget"]
    struct MenuTarget;

    unsafe impl NSObjectProtocol for MenuTarget {}

    impl MenuTarget {
        #[unsafe(method(choose:))]
        fn choose(&self, sender: &NSMenuItem) {
            CHOSEN.with(|chosen| chosen.set(Some(sender.tag())));
        }
    }
);

impl MenuTarget {
    fn new(marker: MainThreadMarker) -> Retained<Self> {
        // SAFETY: `init` on a fresh NSObject subclass with no ivars.
        unsafe { msg_send![Self::alloc(marker), init] }
    }
}

/// Opens `entries` at the pointer. Call it outside any GPUI update: the
/// menu runs AppKit's tracking loop, which delivers other events meanwhile.
pub fn menu(entries: &[Entry]) -> Option<usize> {
    let marker = MainThreadMarker::new()?;
    let target = MenuTarget::new(marker);
    let menu = NSMenu::new(marker);
    menu.setAutoenablesItems(false);
    for (index, entry) in entries.iter().enumerate() {
        let Entry::Item { title, enabled, checked } = entry else {
            menu.addItem(&NSMenuItem::separatorItem(marker));
            continue;
        };
        // SAFETY: `choose:` is the target's one action and takes the item.
        let item = unsafe {
            NSMenuItem::initWithTitle_action_keyEquivalent(
                NSMenuItem::alloc(marker),
                &NSString::from_str(title),
                Some(sel!(choose:)),
                &NSString::from_str(""),
            )
        };
        let target: &AnyObject = &target;
        // SAFETY: the target outlives the menu, which is closed when this returns.
        unsafe { item.setTarget(Some(target)) };
        item.setTag(index as isize);
        item.setEnabled(*enabled);
        if *checked {
            item.setState(NSControlStateValueOn);
        }
        menu.addItem(&item);
    }
    CHOSEN.with(|chosen| chosen.set(None));
    menu.popUpMenuPositioningItem_atLocation_inView(None, NSEvent::mouseLocation(), None);
    CHOSEN.with(Cell::take).and_then(|tag| usize::try_from(tag).ok())
}
