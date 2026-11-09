//! A question put to the person: the Mac `Dialog`.
//!
//! A title that is the action, a line only when the button cannot say it,
//! and verbs. Return chooses the default action; Escape cancels; a
//! destructive verb has no Return unless the caller opts in. The platform
//! shows it (`platform::ask`); this is what is shown.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role {
    Confirm,
    Destructive,
    Cancel,
}

/// A key that chooses an action while the dialog is up.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Shortcut {
    Enter,
    /// ⌘ and a key: the chord that asked confirms.
    Command(char),
    /// ⌥⌘ and a key.
    CommandOption(char),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Action {
    pub title: String,
    pub role: Role,
    pub shortcuts: Vec<Shortcut>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Dialog {
    pub title: String,
    pub message: Option<String>,
    /// In reading order.
    pub actions: Vec<Action>,
}

impl Dialog {
    /// `Dialog.confirm`: Cancel, then the verb.
    pub fn confirm(
        title: impl Into<String>,
        message: Option<String>,
        verb: impl Into<String>,
        role: Role,
        shortcuts: Vec<Shortcut>,
    ) -> Self {
        Self {
            title: title.into(),
            message,
            actions: vec![
                Action { title: "Cancel".into(), role: Role::Cancel, shortcuts: Vec::new() },
                Action { title: verb.into(), role, shortcuts },
            ],
        }
    }

    /// An explicit Enter action, or the first ordinary confirmation.
    pub fn default_action(&self) -> Option<usize> {
        self.actions
            .iter()
            .position(|action| action.shortcuts.contains(&Shortcut::Enter))
            .or_else(|| self.actions.iter().position(|action| action.role == Role::Confirm))
    }

    /// The action Escape performs.
    pub fn cancel_action(&self) -> Option<usize> {
        self.actions.iter().position(|action| action.role == Role::Cancel)
    }

    /// The order buttons are added in (`DialogSurfaceMac.buttonOrder`): the
    /// primary action, then Cancel, then the rest.
    pub fn button_order(&self) -> Vec<usize> {
        let primary = self
            .default_action()
            .or_else(|| self.actions.iter().position(|action| action.role == Role::Destructive));
        let cancel = self.cancel_action();
        let rest = (0..self.actions.len())
            .filter(|index| Some(*index) != primary && Some(*index) != cancel);
        primary.into_iter().chain(cancel).chain(rest).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn closing_a_live_shell_leads_with_the_verb_and_has_no_return() {
        let dialog = Dialog::confirm(
            "Close vim?",
            Some("vim may stop.".into()),
            "Close",
            Role::Destructive,
            vec![Shortcut::Command('w')],
        );
        assert_eq!(dialog.default_action(), None);
        assert_eq!(dialog.cancel_action(), Some(0));
        assert_eq!(dialog.button_order(), [1, 0]);
    }

    #[test]
    fn an_ordinary_confirmation_is_the_default() {
        let dialog = Dialog::confirm("Import?", None, "Import", Role::Confirm, Vec::new());
        assert_eq!(dialog.default_action(), Some(1));
        assert_eq!(dialog.button_order(), [1, 0]);
    }
}
