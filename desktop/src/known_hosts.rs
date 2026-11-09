//! Whether a host key is the one expected: the Mac `KnownHosts` and
//! `SystemKnownHosts`.
//!
//! The app's own pins are `known_hosts.json` beside the library, shared
//! with the Mac app (`[{endpoint: "host:port", algorithm, fingerprint}]`).
//! `~/.ssh/known_hosts` is read, never written. Order: a system `@revoked`
//! line, then the app's pin, then the system file. A new key is a question;
//! a changed one is refused without one.

use std::path::{Path, PathBuf};

use base64::Engine;
use base64::engine::general_purpose::{STANDARD, STANDARD_NO_PAD};
use hmac::{Hmac, Mac};
use serde_json::{Value, json};
use sha1::Sha1;
use sha2::{Digest, Sha256};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Verdict {
    Trusted,
    /// Refused, with the reason a person is shown.
    Changed(String),
    Unknown,
}

pub const CHANGED_PIN: &str =
    "This host’s key has changed. Forget the old key in Settings to trust the new one.";
pub const CHANGED_SYSTEM: &str =
    "This host’s key differs from the one ssh recorded in known_hosts.";

pub fn pins_path() -> Option<PathBuf> {
    dirs::data_dir().map(|dir| dir.join("Tether").join("known_hosts.json"))
}

pub fn system_path() -> Option<PathBuf> {
    dirs::home_dir().map(|home| home.join(".ssh").join("known_hosts"))
}

/// `host:port`, the port always written.
pub fn endpoint(host: &str, port: u16) -> String {
    format!("{host}:{port}")
}

/// `SHA256:` and unpadded base64 of the key blob, as OpenSSH prints it.
pub fn fingerprint(blob: &[u8]) -> String {
    format!("SHA256:{}", STANDARD_NO_PAD.encode(Sha256::digest(blob)))
}

/// The decision for a key, from the app's pins (`pins`, the JSON text) and
/// the system file (`system`, its text).
pub fn verdict(
    pins: &str,
    system: &str,
    host: &str,
    port: u16,
    algorithm: &str,
    print: &str,
) -> Verdict {
    let records = system_records(system, host, port);
    if records.iter().any(|record| record.revoked && record.fingerprint == print) {
        return Verdict::Changed(CHANGED_SYSTEM.into());
    }
    let place = endpoint(host, port);
    if let Some(pin) = parse_pins(pins).into_iter().find(|pin| pin["endpoint"] == place) {
        return if pin["fingerprint"] == print && pin["algorithm"] == algorithm {
            Verdict::Trusted
        } else {
            Verdict::Changed(CHANGED_PIN.into())
        };
    }
    let known: Vec<&SystemRecord> = records.iter().filter(|record| !record.revoked).collect();
    if known.iter().any(|record| record.fingerprint == print) {
        Verdict::Trusted
    } else if known.iter().any(|record| record.algorithm == algorithm) {
        Verdict::Changed(CHANGED_SYSTEM.into())
    } else {
        Verdict::Unknown
    }
}

/// The pins with this one in place of any earlier pin for the endpoint,
/// written the way the Mac app writes them: pretty, keys sorted.
pub fn remembered(pins: &str, host: &str, port: u16, algorithm: &str, print: &str) -> String {
    let place = endpoint(host, port);
    let mut list: Vec<Value> =
        parse_pins(pins).into_iter().filter(|pin| pin["endpoint"] != place).collect();
    list.push(json!({"algorithm": algorithm, "endpoint": place, "fingerprint": print}));
    list.sort_by(|a, b| a["endpoint"].as_str().cmp(&b["endpoint"].as_str()));
    serde_json::to_string_pretty(&list).unwrap_or_else(|_| "[]".into())
}

fn parse_pins(pins: &str) -> Vec<Value> {
    serde_json::from_str::<Vec<Value>>(pins).unwrap_or_default()
}

pub fn read(path: &Path) -> String {
    std::fs::read_to_string(path).unwrap_or_default()
}

struct SystemRecord {
    algorithm: String,
    fingerprint: String,
    revoked: bool,
}

/// The lines naming this host: `host` on port 22, `[host]:port` otherwise,
/// hashed `|1|salt|hash` entries, and `!` negations. `@cert-authority` is skipped.
fn system_records(text: &str, host: &str, port: u16) -> Vec<SystemRecord> {
    let name = if port == 22 { host.to_owned() } else { format!("[{host}]:{port}") };
    text.lines()
        .filter_map(|line| {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                return None;
            }
            let mut parts = line.split_whitespace().peekable();
            let marker =
                parts.peek().filter(|part| part.starts_with('@')).map(|part| part.to_string());
            if marker.is_some() {
                parts.next();
            }
            if marker.as_deref() == Some("@cert-authority") {
                return None;
            }
            let (patterns, algorithm, key) = (parts.next()?, parts.next()?, parts.next()?);
            if !names(patterns, &name) {
                return None;
            }
            let blob = STANDARD.decode(key).ok()?;
            Some(SystemRecord {
                algorithm: algorithm.to_owned(),
                fingerprint: fingerprint(&blob),
                revoked: marker.as_deref() == Some("@revoked"),
            })
        })
        .collect()
}

fn names(patterns: &str, name: &str) -> bool {
    let mut matched = false;
    for pattern in patterns.split(',') {
        if let Some(negated) = pattern.strip_prefix('!') {
            if glob(negated, name) {
                return false;
            }
        } else if pattern.starts_with("|1|") {
            matched |= hashed(pattern, name);
        } else if glob(pattern, name) {
            matched = true;
        }
    }
    matched
}

fn hashed(pattern: &str, name: &str) -> bool {
    let mut fields = pattern.trim_start_matches("|1|").split('|');
    let (Some(salt), Some(hash)) = (fields.next(), fields.next()) else { return false };
    let (Ok(salt), Ok(hash)) = (STANDARD.decode(salt), STANDARD.decode(hash)) else { return false };
    let Ok(mut mac) = Hmac::<Sha1>::new_from_slice(&salt) else { return false };
    mac.update(name.as_bytes());
    mac.verify_slice(&hash).is_ok()
}

/// `*` and `?` wildcards, case-insensitive as OpenSSH matches host names.
fn glob(pattern: &str, name: &str) -> bool {
    fn walk(p: &[char], n: &[char]) -> bool {
        match (p.first(), n.first()) {
            (None, None) => true,
            (Some('*'), _) => walk(&p[1..], n) || (!n.is_empty() && walk(p, &n[1..])),
            (Some('?'), Some(_)) => walk(&p[1..], &n[1..]),
            (Some(a), Some(b)) => a.eq_ignore_ascii_case(b) && walk(&p[1..], &n[1..]),
            _ => false,
        }
    }
    let (p, n): (Vec<char>, Vec<char>) = (pattern.chars().collect(), name.chars().collect());
    walk(&p, &n)
}

#[cfg(test)]
mod tests {
    use super::*;

    const KEY: &str = "AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
    const OTHER: &str = "AAAAC3NzaC1lZDI1NTE5AAAAIBtE4DtBWLk2l4Ny8FaypNsFNxrjE1j1N3bFvMVtVTXb";

    fn print(key: &str) -> String {
        fingerprint(&STANDARD.decode(key).unwrap())
    }

    #[test]
    fn a_pin_trusts_its_own_key_and_refuses_another() {
        let pins = remembered("[]", "h.example", 22, "ssh-ed25519", &print(KEY));
        assert_eq!(
            verdict(&pins, "", "h.example", 22, "ssh-ed25519", &print(KEY)),
            Verdict::Trusted
        );
        assert_eq!(
            verdict(&pins, "", "h.example", 22, "ssh-ed25519", &print(OTHER)),
            Verdict::Changed(CHANGED_PIN.into())
        );
        assert_eq!(
            verdict(&pins, "", "h.example", 2222, "ssh-ed25519", &print(OTHER)),
            Verdict::Unknown
        );
    }

    #[test]
    fn the_system_file_is_read_by_name_port_and_hash() {
        let system = format!("h.example ssh-ed25519 {KEY}\n[h.example]:2222 ssh-ed25519 {OTHER}\n");
        assert_eq!(
            verdict("[]", &system, "h.example", 22, "ssh-ed25519", &print(KEY)),
            Verdict::Trusted
        );
        assert_eq!(
            verdict("[]", &system, "H.EXAMPLE", 2222, "ssh-ed25519", &print(OTHER)),
            Verdict::Trusted
        );
        assert_eq!(
            verdict("[]", &system, "h.example", 22, "ssh-ed25519", &print(OTHER)),
            Verdict::Changed(CHANGED_SYSTEM.into())
        );
        // `ssh-keygen -H` form of `h.example` with a fixed salt.
        let salt = [7u8; 20];
        let mut mac = Hmac::<Sha1>::new_from_slice(&salt).unwrap();
        mac.update(b"h.example");
        let hashed = format!(
            "|1|{}|{} ssh-ed25519 {KEY}",
            STANDARD.encode(salt),
            STANDARD.encode(mac.finalize().into_bytes())
        );
        assert_eq!(
            verdict("[]", &hashed, "h.example", 22, "ssh-ed25519", &print(KEY)),
            Verdict::Trusted
        );
        assert_eq!(
            verdict("[]", &hashed, "other.example", 22, "ssh-ed25519", &print(KEY)),
            Verdict::Unknown
        );
    }

    #[test]
    fn revoked_and_negated_lines_count_against() {
        let revoked = format!("@revoked h.example ssh-ed25519 {KEY}\n");
        assert_eq!(
            verdict("[]", &revoked, "h.example", 22, "ssh-ed25519", &print(KEY)),
            Verdict::Changed(CHANGED_SYSTEM.into())
        );
        let negated = format!("*.example,!h.example ssh-ed25519 {KEY}\n");
        assert_eq!(
            verdict("[]", &negated, "h.example", 22, "ssh-ed25519", &print(KEY)),
            Verdict::Unknown
        );
        assert_eq!(
            verdict("[]", &negated, "g.example", 22, "ssh-ed25519", &print(KEY)),
            Verdict::Trusted
        );
    }

    #[test]
    fn remembering_replaces_the_endpoint_and_keeps_the_mac_shape() {
        let pins = remembered("[]", "a", 22, "ssh-rsa", "SHA256:x");
        let pins = remembered(&pins, "a", 22, "ssh-ed25519", "SHA256:y");
        let list: Vec<Value> = serde_json::from_str(&pins).unwrap();
        assert_eq!(
            list,
            [json!({"algorithm": "ssh-ed25519", "endpoint": "a:22", "fingerprint": "SHA256:y"})]
        );
        // The Mac app's own file escapes slashes; it reads the same.
        let mac = r#"[{"algorithm":"ssh-ed25519","endpoint":"a:22","fingerprint":"SHA256:a\/b"}]"#;
        assert_eq!(verdict(mac, "", "a", 22, "ssh-ed25519", "SHA256:a/b"), Verdict::Trusted);
    }
}
