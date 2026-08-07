//! crate-changelog: a static site generator that redirects
//! `/<crate>` paths to each crate's changelog.
//!
//! The data source lives in `data/`, one `changelog` file per crate
//! (e.g. `data/tr/acexec/changelog` for `tracexec`). The generated site
//! works on static hosts such as GitHub Pages and Vercel.

mod build;
mod cli;
mod data;
mod error;
mod render;

use cli::Command;
use color_eyre::eyre::Result;
use spdlog::prelude::*;

fn main() -> Result<()> {
    color_eyre::install()?;

    let cli = cli::parse()?;

    // Logging is quiet by default; `-v` lifts the filter, and
    // `SPDLOG_RS_LEVEL` (applied after) can refine it further.
    if cli.verbose {
        spdlog::default_logger().set_level_filter(LevelFilter::All);
    }
    let _ = spdlog::init_env_level();

    if cli.version {
        println!("crate-changelog {}", env!("CARGO_PKG_VERSION"));
        return Ok(());
    }

    match cli.command {
        Some(Command::Add { name, url }) => data::add(&cli.data_dir, &name, &url)?,
        None => build::build(&cli)?,
    }

    Ok(())
}
