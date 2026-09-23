//! Shared by the tests that feed a terminal bytes nobody wrote by hand.
//!
//! `stress.rs` generates its bytes and `corpus.rs` replays recorded ones, but
//! both ask the same two questions of the result — does the screen still obey
//! its own contract, and does the damage describe every change — so the
//! answers live in one place.

#![allow(dead_code)] // Each test binary uses a subset; the module is shared.

pub mod invariants;
pub mod mirror;
pub mod snapshot;
