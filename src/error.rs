//! Error types for the whole application.
//!
//! All fallible operations funnel into [`Error`] via [snafu] context
//! selectors; the top-level `main` converts them into a `color-eyre`
//! report for pretty rendering.
//!
//! [snafu]: https://docs.rs/snafu

use std::io;
use std::path::PathBuf;

use snafu::Snafu;

/// Convenient alias for fallible operations in this crate.
pub type Result<T, E = Error> = std::result::Result<T, E>;

/// Every error the generator can produce.
#[derive(Debug, Snafu)]
#[snafu(visibility(pub(crate)))]
pub enum Error {
    /// The command line could not be parsed (palc).
    #[snafu(display("failed to parse command line arguments"))]
    Cli { source: palc::Error },

    /// The data directory could not be read.
    #[snafu(display("failed to read data directory {path:?}"))]
    ReadDataDir { path: PathBuf, source: io::Error },

    /// A directory inside the data directory is not a valid crate name.
    #[snafu(display("{path:?} is not a valid crate name: {reason}"))]
    InvalidCrateName { path: PathBuf, reason: String },

    /// A crate's changelog file could not be read.
    #[snafu(display("failed to read changelog of crate {name:?} at {path:?}"))]
    ReadChangelog {
        name: String,
        path: PathBuf,
        source: io::Error,
    },

    /// A crate's changelog file was empty.
    #[snafu(display("changelog of crate {name:?} at {path:?} is empty"))]
    EmptyChangelog { name: String, path: PathBuf },

    /// A crate's changelog file did not contain an http(s) URL.
    #[snafu(display(
        "changelog of crate {name:?} at {path:?} contains {url:?}, which is not an http(s) URL"
    ))]
    InvalidChangelogUrl {
        name: String,
        path: PathBuf,
        url: String,
    },

    /// The output directory could not be created.
    #[snafu(display("failed to create output directory {path:?}"))]
    CreateDir { path: PathBuf, source: io::Error },

    /// `--clean` refused to remove a path that is unsafe to delete.
    #[snafu(display("refusing to remove {path:?} as the output directory"))]
    UnsafeClean { path: PathBuf },

    /// `--clean` could not remove the output directory.
    #[snafu(display("failed to remove output directory {path:?}"))]
    RemoveDir { path: PathBuf, source: io::Error },

    /// A generated file could not be written.
    #[snafu(display("failed to write {path:?}"))]
    WriteFile { path: PathBuf, source: io::Error },
}
