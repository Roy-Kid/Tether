//! The host library: the Mac `Host` and `HostStore`, read.
//!
//! On a Mac the library is the app's own: `identity.sqlite` under
//! Application Support, one JSON snapshot per account scope, the active one
//! named by `active-account`. This host reads it and never writes it, so
//! both apps list the same hosts; editing is the Mac app's until the
//! library moves here. This machine is always first.

use std::path::{Path, PathBuf};

use serde_json::Value;

/// The Mac `Host.localID`.
pub const LOCAL_ID: &str = "10CA1005-0000-4000-A000-000000000001";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Host {
    pub id: String,
    pub label: String,
    pub hostname: String,
    pub port: u16,
    pub username: String,
    /// An `IdentityFile` bound on this device; `None` offers the default keys.
    pub key_path: Option<String>,
    /// Hops this host is reached through. Not dialled yet, as on a Mac.
    pub jumps: Vec<String>,
}

impl Host {
    pub fn local() -> Self {
        Self {
            id: LOCAL_ID.into(),
            label: "localhost".into(),
            hostname: String::new(),
            port: 22,
            username: String::new(),
            key_path: None,
            jumps: Vec::new(),
        }
    }

    pub fn is_local(&self) -> bool {
        self.id == LOCAL_ID
    }

    /// The trimmed label, or the hostname.
    pub fn display_name(&self) -> String {
        let label = self.label.trim();
        if label.is_empty() { self.hostname.clone() } else { label.to_owned() }
    }

    /// `user@host`, with `:port` only when it is not 22.
    pub fn address(&self) -> String {
        let at = if self.username.is_empty() {
            self.hostname.clone()
        } else {
            format!("{}@{}", self.username, self.hostname)
        };
        if self.port == 22 { at } else { format!("{at}:{}", self.port) }
    }

    /// `HostStore.routeProblem`: what this host needs that cannot be dialled yet.
    pub fn route_problem(&self) -> Option<String> {
        (!self.jumps.is_empty()).then(|| {
            "This route requires an SSH transport that is not available on this device.".to_owned()
        })
    }
}

/// Where the Mac app keeps its library on this machine.
pub fn library_path() -> Option<PathBuf> {
    dirs::data_dir().map(|dir| dir.join("Tether").join("identity.sqlite"))
}

/// The library's hosts in the Mac order — by label, as `localizedStandardCompare`
/// sorts — after this machine. A missing or unreadable library lists only it.
pub fn load(path: &Path) -> Result<Vec<Host>, String> {
    let flags =
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX;
    let db = rusqlite::Connection::open_with_flags(path, flags).map_err(|e| e.to_string())?;
    let read = |scope: &str| -> Result<Option<Vec<u8>>, String> {
        let mut statement =
            db.prepare("SELECT value FROM state WHERE scope = ?1").map_err(|e| e.to_string())?;
        let mut rows = statement.query([scope]).map_err(|e| e.to_string())?;
        match rows.next().map_err(|e| e.to_string())? {
            Some(row) => Ok(Some(row.get::<_, Vec<u8>>(0).map_err(|e| e.to_string())?)),
            None => Ok(None),
        }
    };
    let Some(active) = read("active-account")? else { return Ok(Vec::new()) };
    let scope: String = serde_json::from_slice(&active).map_err(|e| e.to_string())?;
    let Some(snapshot) = read(&scope)? else { return Ok(Vec::new()) };
    let snapshot: Value = serde_json::from_slice(&snapshot).map_err(|e| e.to_string())?;
    Ok(hosts(&snapshot))
}

/// The hosts in one `IdentitySnapshot`. Swift writes a dictionary keyed by
/// UUID as `[key, value, key, value, …]`.
pub fn hosts(snapshot: &Value) -> Vec<Host> {
    let pairs = |field: &str| -> Vec<(String, Value)> {
        snapshot[field]
            .as_array()
            .map(|list| {
                list.chunks(2)
                    .filter_map(|pair| {
                        Some((pair.first()?.as_str()?.to_owned(), pair.get(1)?.clone()))
                    })
                    .collect()
            })
            .unwrap_or_default()
    };
    let bindings = pairs("bindings");
    let mut hosts: Vec<Host> = pairs("records")
        .into_iter()
        .filter(|(_, record)| !record["deleted"].as_bool().unwrap_or(false))
        .filter_map(|(id, record)| {
            let profile = &record["profile"];
            let text = |key: &str| profile[key].as_str().unwrap_or_default().to_owned();
            let hostname = text("hostname");
            if hostname.is_empty() {
                return None;
            }
            let key_path = bindings
                .iter()
                .find(|(host, _)| *host == id)
                .and_then(|(_, binding)| binding["keyPath"].as_str().map(str::to_owned))
                .filter(|path| !path.is_empty());
            let jumps = profile["jumpHosts"]
                .as_array()
                .map(|list| {
                    list.iter()
                        .map(|hop| {
                            hop.as_str().map(str::to_owned).unwrap_or_else(|| hop.to_string())
                        })
                        .collect()
                })
                .unwrap_or_default();
            Some(Host {
                id,
                label: text("label"),
                hostname,
                port: profile["port"]
                    .as_u64()
                    .and_then(|port| u16::try_from(port).ok())
                    .unwrap_or(22),
                username: text("username"),
                key_path,
                jumps,
            })
        })
        .collect();
    hosts.sort_by_key(|host| natural(&host.display_name()));
    hosts
}

/// Case-insensitive, with runs of digits compared as numbers: `web2` before `web10`.
fn natural(text: &str) -> Vec<(u8, String, u64)> {
    let mut keys = Vec::new();
    let mut chars = text.chars().peekable();
    while let Some(&c) = chars.peek() {
        if c.is_ascii_digit() {
            let mut digits = String::new();
            while let Some(&d) = chars.peek().filter(|d| d.is_ascii_digit()) {
                digits.push(d);
                chars.next();
            }
            keys.push((0, String::new(), digits.parse().unwrap_or(u64::MAX)));
        } else {
            keys.push((1, c.to_lowercase().collect(), 0));
            chars.next();
        }
    }
    keys
}

/// `SSHConfig` default identities, in OpenSSH's order, that exist.
pub fn default_keys(home: &Path) -> Vec<PathBuf> {
    ["id_rsa", "id_ecdsa", "id_ecdsa_sk", "id_ed25519", "id_ed25519_sk", "id_dsa"]
        .iter()
        .map(|name| home.join(".ssh").join(name))
        .filter(|path| path.is_file())
        .collect()
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn snapshot() -> Value {
        json!({
            "records": [
                "A", {"deleted": false, "profile": {"id": "A", "label": "web10", "hostname": "w10.example", "port": 22, "username": "ada", "jumpHosts": []}},
                "B", {"deleted": false, "profile": {"id": "B", "label": "", "hostname": "Web2.example", "port": 2222, "username": "ada", "jumpHosts": ["bastion"]}},
                "C", {"deleted": true, "profile": {"id": "C", "label": "gone", "hostname": "x", "port": 22, "username": "u", "jumpHosts": []}}
            ],
            "bindings": ["A", {"credentialID": "k", "keyPath": "~/.ssh/work"}]
        })
    }

    #[test]
    fn the_library_lists_live_hosts_in_label_order_with_their_keys() {
        let hosts = hosts(&snapshot());
        assert_eq!(
            hosts.iter().map(Host::display_name).collect::<Vec<_>>(),
            ["Web2.example", "web10"]
        );
        assert_eq!(hosts[1].key_path.as_deref(), Some("~/.ssh/work"));
        assert_eq!(hosts[0].address(), "ada@Web2.example:2222");
        assert_eq!(hosts[1].address(), "ada@w10.example");
        assert!(hosts[0].route_problem().is_some());
        assert!(hosts[1].route_problem().is_none());
    }

    #[test]
    fn the_library_file_is_read_through_its_active_scope() {
        let dir = std::env::temp_dir().join(format!("tether-library-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("identity.sqlite");
        let _ = std::fs::remove_file(&path);
        let db = rusqlite::Connection::open(&path).unwrap();
        db.execute("CREATE TABLE state (scope TEXT PRIMARY KEY, value BLOB NOT NULL)", []).unwrap();
        db.execute("INSERT INTO state VALUES ('active-account', ?1)", [b"\"local\"".to_vec()])
            .unwrap();
        db.execute(
            "INSERT INTO state VALUES ('local', ?1)",
            [serde_json::to_vec(&snapshot()).unwrap()],
        )
        .unwrap();
        drop(db);
        assert_eq!(load(&path).unwrap().len(), 2);
        assert!(load(&dir.join("missing.sqlite")).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn this_machine_is_named_localhost() {
        let local = Host::local();
        assert!(local.is_local());
        assert_eq!(local.display_name(), "localhost");
    }
}
