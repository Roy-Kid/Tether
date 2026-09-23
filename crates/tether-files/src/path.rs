//! Paths on the far side.
//!
//! SFTP paths are POSIX paths whatever this machine uses, so they are
//! strings here, never `std::path::Path` — a `Path` would be interpreted by
//! the rules of the computer running this code, not the one being asked.

/// `name` inside `directory`.
pub fn join(directory: &str, name: &str) -> String {
    if directory.is_empty() {
        name.to_owned()
    } else if directory.ends_with('/') {
        format!("{directory}{name}")
    } else {
        format!("{directory}/{name}")
    }
}

/// The last component: `c` for `/a/b/c` and `/a/b/c/`, `/` for `/`.
pub fn name_of(path: &str) -> &str {
    let trimmed = path.trim_end_matches('/');
    if trimmed.is_empty() {
        return if path.is_empty() { "" } else { "/" };
    }
    trimmed.rsplit('/').next().unwrap_or(trimmed)
}

/// The directory holding `path`: `/a/b` for `/a/b/c`, `/` for `/a` and `/`,
/// and `.` for a bare name.
pub fn parent_of(path: &str) -> &str {
    let trimmed = path.trim_end_matches('/');
    match trimmed.rfind('/') {
        Some(0) => "/",
        Some(index) => &trimmed[..index],
        None if path.starts_with('/') => "/",
        None => ".",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn joining_never_doubles_a_separator() {
        assert_eq!(join("/", "a"), "/a");
        assert_eq!(join("/a", "b"), "/a/b");
        assert_eq!(join("/a/", "b"), "/a/b");
        assert_eq!(join("", "b"), "b");
    }

    #[test]
    fn a_name_is_the_last_component() {
        assert_eq!(name_of("/a/b/c"), "c");
        assert_eq!(name_of("/a/b/c/"), "c");
        assert_eq!(name_of("c"), "c");
        assert_eq!(name_of("/"), "/");
        assert_eq!(name_of(""), "");
    }

    #[test]
    fn a_parent_is_everything_before_it() {
        assert_eq!(parent_of("/a/b/c"), "/a/b");
        assert_eq!(parent_of("/a/b/c/"), "/a/b");
        assert_eq!(parent_of("/a"), "/");
        assert_eq!(parent_of("/"), "/");
        assert_eq!(parent_of("c"), ".");
        assert_eq!(parent_of("a/b"), "a");
    }
}
