//! Command line interface, parsed with [palc].
//!
//! [palc]: https://crates.io/crates/palc

use std::path::PathBuf;

use palc::{Parser, Subcommand};

use crate::error::{self, Result};

/// Generate a static site that redirects to each crate's changelog.
///
/// The data source lives in a directory (default `data/`), one
/// `changelog` file per crate. The file's content is the URL of the
/// crate's changelog, e.g. `data/tr/acexec/changelog` for `tracexec`.
#[derive(Debug, Parser)]
#[command(name = "crate-changelog", long_about)]
pub struct Cli {
    /// Directory containing the changelog data source
    #[arg(long, value_name = "DIR", default_value = "data")]
    pub data_dir: PathBuf,

    /// Directory the generated site is written to
    #[arg(long, value_name = "DIR", default_value = "site")]
    pub output_dir: PathBuf,

    /// Base URL of the deployed site, used for canonical links
    #[arg(
        long,
        value_name = "URL",
        default_value = "https://crate-changelog.kxxt.dev/"
    )]
    pub base_url: String,

    /// Remove the output directory before generating the site
    #[arg(long)]
    pub clean: bool,

    /// Disable progress bars (useful for CI logs)
    #[arg(long)]
    pub no_progress: bool,

    /// Print version and exit
    #[arg(long)]
    pub version: bool,

    /// Enable verbose (debug) logging
    #[arg(short, long)]
    pub verbose: bool,

    /// Manage the changelog data source
    #[command(subcommand)]
    pub command: Option<Command>,
}

/// Administrative subcommands.
#[derive(Debug, Subcommand)]
pub enum Command {
    /// Add a crate's changelog URL to the data source
    Add {
        /// Crate name, e.g. `tracexec`
        name: String,
        /// URL of the crate's changelog
        url: String,
    },
}

/// Parse the command line, printing help for `--help`.
pub fn parse() -> Result<Cli> {
    let cli = match Cli::try_parse_from(std::env::args_os()) {
        Ok(cli) => cli,
        Err(err) => match err.try_into_help() {
            Ok(help) => {
                println!("{help}");
                std::process::exit(0);
            }
            Err(err) => return Err(error::Error::Cli { source: err }),
        },
    };
    Ok(cli)
}
