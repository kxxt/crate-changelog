//! The changelog data source.
//!
//! Each crate gets a small file in the data directory. The file is named
//! `changelog` and its content is the URL of the crate's changelog:
//!
//! ```text
//! data/
//! └── tr/              <- first two letters of the crate name
//!     └── acexec/      <- the rest of the name
//!         └── changelog   <- contains the changelog URL of `tracexec`
//! ```
//!
//! Crate names of at most two characters live directly at
//! `data/<name>/changelog`.

use std::fs;
use std::io::Write as _;
use std::path::{Path, PathBuf};

use snafu::{ResultExt as _, ensure};
use spdlog::prelude::*;

use crate::error::{self, Result};

/// Maximum length of a crate name (crates.io allows 64 chars).
const MAX_CRATE_NAME_LEN: usize = 64;

/// A crate we know how to redirect to its changelog.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Crate {
    /// The crate name, e.g. `tracexec`.
    pub name: String,
    /// The URL of the crate's changelog.
    pub url: String,
    /// The `changelog` file this entry was loaded from.
    pub source: PathBuf,
}

/// Validate a crate name: 1..=64 chars of `[a-zA-Z0-9_-]`.
fn is_valid_crate_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= MAX_CRATE_NAME_LEN
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

fn is_http_url(url: &str) -> bool {
    url.starts_with("https://") || url.starts_with("http://")
}

/// Compute the `changelog` file path for a crate name.
pub fn changelog_path(data_dir: &Path, name: &str) -> PathBuf {
    let (prefix, rest) = name.split_at(name.len().min(2));
    if rest.is_empty() {
        data_dir.join(prefix).join("changelog")
    } else {
        data_dir.join(prefix).join(rest).join("changelog")
    }
}

/// Read a `changelog` file and turn it into a [`Crate`].
fn load_crate(name: &str, changelog: &Path) -> Result<Crate> {
    let raw = fs::read_to_string(changelog).with_context(|_| error::ReadChangelogSnafu {
        name: name.to_owned(),
        path: changelog.to_owned(),
    })?;
    let url = raw.trim();

    ensure!(
        !url.is_empty(),
        error::EmptyChangelogSnafu {
            name: name.to_owned(),
            path: changelog.to_owned()
        }
    );
    ensure!(
        is_http_url(url),
        error::InvalidChangelogUrlSnafu {
            name: name.to_owned(),
            path: changelog.to_owned(),
            url: url.to_owned(),
        }
    );

    debug!("loaded {} -> {}", name, url);
    Ok(Crate {
        name: name.to_owned(),
        url: url.to_owned(),
        source: changelog.to_owned(),
    })
}

/// Validate a directory name inside the data directory as a crate-name part.
///
/// Dot-directories (`.git`, `.github`, ...) are allowed and silently
/// skipped by callers.
fn validate_dir_name(path: &Path, dir_name: &str) -> Result<()> {
    ensure!(
        is_valid_crate_name(dir_name),
        error::InvalidCrateNameSnafu {
            path: path.to_owned(),
            reason: format!(
                "expected 1..={MAX_CRATE_NAME_LEN} chars of [a-zA-Z0-9_-], got {dir_name:?}"
            ),
        }
    );
    Ok(())
}

/// Discover every crate in the data directory, sorted by name.
pub fn discover(data_dir: &Path) -> Result<Vec<Crate>> {
    let entries = fs::read_dir(data_dir).with_context(|_| error::ReadDataDirSnafu {
        path: data_dir.to_owned(),
    })?;

    let mut crates: Vec<Crate> = Vec::new();
    for entry in entries {
        let entry = entry.with_context(|_| error::ReadDataDirSnafu {
            path: data_dir.to_owned(),
        })?;
        let dir = entry.path();
        if !dir.is_dir() {
            continue;
        }
        let Some(dir_name) = dir.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        if dir_name.starts_with('.') {
            debug!("skipping hidden directory {dir:?}");
            continue;
        }
        validate_dir_name(&dir, dir_name)?;

        // A crate of at most two characters may live directly at
        // `data/<name>/changelog`.
        let direct = dir.join("changelog");
        if direct.is_file() {
            crates.push(load_crate(dir_name, &direct)?);
        }

        // Longer names are sharded: `data/<first two>/<rest>/changelog`.
        for sub in fs::read_dir(&dir).with_context(|_| error::ReadDataDirSnafu {
            path: dir.to_owned(),
        })? {
            let sub = sub.with_context(|_| error::ReadDataDirSnafu {
                path: dir.to_owned(),
            })?;
            let sub_path = sub.path();
            if !sub_path.is_dir() {
                continue;
            }
            let Some(rest) = sub_path.file_name().and_then(|n| n.to_str()) else {
                continue;
            };
            if rest.starts_with('.') {
                debug!("skipping hidden directory {sub_path:?}");
                continue;
            }
            validate_dir_name(&sub_path, rest)?;

            let changelog = sub_path.join("changelog");
            if changelog.is_file() {
                let name = format!("{dir_name}{rest}");
                crates.push(load_crate(&name, &changelog)?);
            }
        }
    }

    crates.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(crates)
}

/// Add a crate to the data source, creating shard directories as needed.
pub fn add(data_dir: &Path, name: &str, url: &str) -> Result<()> {
    let name = name.trim();
    let url = url.trim();

    ensure!(
        is_valid_crate_name(name),
        error::InvalidCrateNameSnafu {
            path: data_dir.join(name),
            reason: format!(
                "expected 1..={MAX_CRATE_NAME_LEN} chars of [a-zA-Z0-9_-], got {name:?}"
            ),
        }
    );
    let path = changelog_path(data_dir, name);
    ensure!(
        is_http_url(url),
        error::InvalidChangelogUrlSnafu {
            name: name.to_owned(),
            path: path.clone(),
            url: url.to_owned(),
        }
    );

    // `changelog_path` always joins a final `changelog` segment, so the
    // parent directory is structurally guaranteed to exist.
    let parent = path.parent().expect("changelog path always has a parent");
    fs::create_dir_all(parent).with_context(|_| error::CreateDirSnafu {
        path: parent.to_owned(),
    })?;
    let mut file =
        fs::File::create(&path).with_context(|_| error::WriteFileSnafu { path: path.clone() })?;
    file.write_all(url.as_bytes())
        .and_then(|()| file.write_all(b"\n"))
        .with_context(|_| error::WriteFileSnafu { path: path.clone() })?;

    info!("added {name} -> {url} at {}", path.display());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// A fresh, unique temporary directory for one test.
    fn temp_dir(tag: &str) -> PathBuf {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let dir = std::env::temp_dir().join(format!(
            "crate-changelog-test-{}-{tag}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = fs::remove_dir_all(&dir);
        dir
    }

    #[test]
    fn changelog_path_shards_long_names() {
        let p = changelog_path(Path::new("data"), "tracexec");
        assert_eq!(p, Path::new("data/tr/acexec/changelog"));
    }

    #[test]
    fn changelog_path_keeps_short_names_flat() {
        assert_eq!(
            changelog_path(Path::new("data"), "ab"),
            Path::new("data/ab/changelog")
        );
        assert_eq!(
            changelog_path(Path::new("data"), "x"),
            Path::new("data/x/changelog")
        );
    }

    #[test]
    fn validate_name() {
        assert!(is_valid_crate_name("tracexec"));
        assert!(is_valid_crate_name("color-eyre"));
        assert!(is_valid_crate_name("a"));
        assert!(!is_valid_crate_name(""));
        assert!(!is_valid_crate_name("has space"));
        assert!(!is_valid_crate_name(&"a".repeat(65)));
    }

    #[test]
    fn discover_roundtrip() {
        let dir = temp_dir("roundtrip");
        fs::create_dir_all(dir.join("tr/acexec")).unwrap();
        fs::write(
            dir.join("tr/acexec/changelog"),
            "https://example.com/tracexec\n",
        )
        .unwrap();
        fs::create_dir_all(dir.join("ab")).unwrap();
        fs::write(dir.join("ab/changelog"), "https://example.com/ab\n").unwrap();
        // Dot-directories and stray files are skipped.
        fs::create_dir_all(dir.join(".github")).unwrap();
        fs::write(dir.join("README.md"), "readme").unwrap();

        let crates = discover(&dir).unwrap();
        assert_eq!(crates.len(), 2);
        assert_eq!(crates[0].name, "ab");
        assert_eq!(crates[1].name, "tracexec");
        assert_eq!(crates[1].url, "https://example.com/tracexec");

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn discover_rejects_invalid_url() {
        let dir = temp_dir("bad-url");
        fs::create_dir_all(dir.join("fo/o")).unwrap();
        fs::write(dir.join("fo/o/changelog"), "not a url\n").unwrap();

        assert!(matches!(
            discover(&dir),
            Err(crate::error::Error::InvalidChangelogUrl { .. })
        ));

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn add_writes_sharded_file() {
        let dir = temp_dir("add");
        add(&dir, "eza", "https://example.com/eza/changelog").unwrap();
        assert_eq!(
            fs::read_to_string(dir.join("ez/a/changelog")).unwrap(),
            "https://example.com/eza/changelog\n"
        );
        fs::remove_dir_all(&dir).unwrap();
    }
}
