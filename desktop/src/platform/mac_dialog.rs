//! A `Dialog` as the Mac app shows one (`DialogSurfaceMac`): an alert sheet
//! on the window. The primary action first, then Cancel. A destructive
//! verb is marked and has no Return; Cancel has Escape (Return too when it
//! is the only button); a confirmation that is the default has Return. A
//! chord the dialog names — ⌘W again for Close — presses its button while
//! the sheet is the key window.

use std::cell::RefCell;
use std::ptr::NonNull;
use std::rc::Rc;

use block2::RcBlock;
use objc2::MainThreadMarker;
use objc2::rc::Retained;
use objc2::runtime::AnyObject;
use objc2_app_kit::{
    NSAlert, NSAlertFirstButtonReturn, NSButton, NSEvent, NSEventMask, NSEventModifierFlags,
    NSModalResponse,
};
use objc2_foundation::NSString;
use tether_desktop::dialog::{Dialog, Role, Shortcut};
use tokio::sync::oneshot;

use super::mac::content_view;

/// Shows `dialog` as a sheet. The answer is an index into its actions;
/// `None` when it could not be shown.
pub fn ask(window: &gpui::Window, dialog: &Dialog) -> oneshot::Receiver<Option<usize>> {
    let (sender, receiver) = oneshot::channel();
    let Some(marker) = MainThreadMarker::new() else {
        let _ = sender.send(None);
        return receiver;
    };
    let Some(sheet_parent) = content_view(window).ok().and_then(|view| view.window()) else {
        let _ = sender.send(None);
        return receiver;
    };
    let alert = NSAlert::new(marker);
    alert.setMessageText(&NSString::from_str(&dialog.title));
    alert.setInformativeText(&NSString::from_str(dialog.message.as_deref().unwrap_or("")));
    let order = dialog.button_order();
    let mut chords: Vec<(Shortcut, Retained<NSButton>)> = Vec::new();
    for &index in &order {
        let action = &dialog.actions[index];
        let button = alert.addButtonWithTitle(&NSString::from_str(&action.title));
        let key = match action.role {
            Role::Destructive => {
                button.setHasDestructiveAction(true);
                ""
            }
            Role::Cancel if dialog.actions.len() == 1 => "\r",
            Role::Cancel => "\u{1b}",
            Role::Confirm if dialog.default_action() == Some(index) => "\r",
            Role::Confirm => "",
        };
        button.setKeyEquivalent(&NSString::from_str(key));
        button.setKeyEquivalentModifierMask(NSEventModifierFlags::empty());
        chords.extend(action.shortcuts.iter().map(|shortcut| (*shortcut, button.clone())));
    }
    let monitor = watch(alert.window(), chords);
    let sender = RefCell::new(Some(sender));
    let handler = RcBlock::new(move |response: NSModalResponse| {
        if let Some(monitor) = monitor.borrow_mut().take() {
            // SAFETY: the monitor came from `addLocalMonitorForEventsMatchingMask`.
            unsafe { NSEvent::removeMonitor(&monitor) };
        }
        let chosen = usize::try_from(response - NSAlertFirstButtonReturn)
            .ok()
            .and_then(|button| order.get(button).copied());
        if let Some(sender) = sender.borrow_mut().take() {
            let _ = sender.send(chosen);
        }
    });
    alert.beginSheetModalForWindow_completionHandler(&sheet_parent, Some(&handler));
    receiver
}

type Monitor = Rc<RefCell<Option<Retained<AnyObject>>>>;

/// The dialog's chords, heard only while its sheet is the key window.
fn watch(
    sheet: Retained<objc2_app_kit::NSWindow>,
    chords: Vec<(Shortcut, Retained<NSButton>)>,
) -> Monitor {
    if chords.is_empty() {
        return Rc::new(RefCell::new(None));
    }
    let block = RcBlock::new(move |event: NonNull<NSEvent>| -> *mut NSEvent {
        // SAFETY: AppKit hands the monitor a live event.
        let event = unsafe { event.as_ref() };
        // Monitors run on the main thread, where AppKit delivers events.
        let Some(marker) = MainThreadMarker::new() else {
            return event as *const NSEvent as *mut NSEvent;
        };
        let ours = event
            .window(marker)
            .is_some_and(|window| Retained::as_ptr(&window) == Retained::as_ptr(&sheet));
        let pressed =
            ours.then(|| chords.iter().find(|(chord, _)| matches(*chord, event))).flatten();
        match pressed {
            Some((_, button)) => {
                // SAFETY: a button of this alert, pressed on the main thread.
                unsafe { button.performClick(None) };
                std::ptr::null_mut()
            }
            None => event as *const NSEvent as *mut NSEvent,
        }
    });
    // SAFETY: the handler returns the event or null, as the monitor expects.
    let monitor = unsafe {
        NSEvent::addLocalMonitorForEventsMatchingMask_handler(NSEventMask::KeyDown, &block)
    };
    Rc::new(RefCell::new(monitor))
}

fn matches(chord: Shortcut, event: &NSEvent) -> bool {
    let flags = event.modifierFlags() & NSEventModifierFlags::DeviceIndependentFlagsMask;
    let key = event
        .charactersIgnoringModifiers()
        .map(|text| text.to_string().to_lowercase())
        .unwrap_or_default();
    match chord {
        // Return and keypad Enter.
        Shortcut::Enter => flags.is_empty() && matches!(event.keyCode(), 36 | 76),
        Shortcut::Command(c) => flags == NSEventModifierFlags::Command && key == c.to_string(),
        Shortcut::CommandOption(c) => {
            flags == NSEventModifierFlags::Command | NSEventModifierFlags::Option
                && key == c.to_string()
        }
    }
}
