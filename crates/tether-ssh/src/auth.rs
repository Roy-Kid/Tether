//! Proving who you are.
//!
//! Three families, three primitives. They are separate calls rather than one
//! `Credential` enum because they compose differently: a server may demand a
//! key *and* an interactive factor, and the caller sequences that
//! (law: primitive public surface).

/// One question from the server during an interactive exchange.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Prompt {
    pub text: String,
    /// False for anything that must not be displayed while typed.
    pub echo: bool,
}

/// A round of questions.
///
/// `name` and `instruction` are the server's own words — an institution's
/// wording about which factor to use, or why a login is being challenged —
/// and are shown to the person, not parsed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Challenge {
    pub name: String,
    pub instruction: String,
    pub prompts: Vec<Prompt>,
}

/// Answers a server's questions.
///
/// There is no fixed number of rounds and no fixed set of questions:
/// keyboard-interactive is a conversation the server drives. Nothing here
/// assumes a one-time password (spec §10).
#[async_trait::async_trait]
pub trait Prompter: Send + Sync {
    /// One answer per prompt, in order. Returning `None` abandons the
    /// exchange — the person declined, which is not an authentication
    /// failure and must not be reported as one.
    ///
    /// A challenge always carries at least one prompt. A round with none is
    /// the server talking rather than asking, and is answered without anyone
    /// being disturbed.
    async fn answer(&self, challenge: &Challenge) -> Option<Vec<String>>;
}

/// An authentication method a server says it will still accept.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Method(pub String);

impl std::fmt::Display for Method {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

/// Keyboard-interactive is not a synonym for one-time passwords.
///
/// A server may use it for a password, an OTP, a token, a challenge/response,
/// a factor selection, or its own institutional wording. The protocol layer
/// reports prompts; a higher layer decides how a person answers them
/// (spec §10). Stated here as a constant so the rule is visible at the point
/// the temptation arises.
pub const KEYBOARD_INTERACTIVE_IS_GENERIC: &str =
    "prompts are opaque text with an echo flag; never assume OTP";
