//! Build orchestration: discover data, render pages, write the site.
//!
//! Progress is reported with [indicatif] bars (hidden when `--no-progress`
//! is passed) and key milestones are logged with spdlog.
//!
//! [indicatif]: https://crates.io/crates/indicatif

use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use indicatif::{MultiProgress, ProgressBar, ProgressDrawTarget, ProgressStyle};
use snafu::ResultExt as _;
use spdlog::prelude::*;

use crate::cli::Cli;
use crate::data;
use crate::error::{self, Result};
use crate::render;

/// Static styles for the progress bars.
fn bar_style() -> ProgressStyle {
    ProgressStyle::with_template("[{elapsed_precise}] [{bar:36.cyan/blue}] {pos:>3}/{len:3} {msg}")
        .expect("static progress template")
        .progress_chars("█▉▊▋▌▍▎▏  ")
}

/// Static style for spinner bars.
fn spinner_style() -> ProgressStyle {
    ProgressStyle::with_template("{spinner:.cyan} {msg}")
        .expect("static spinner template")
        .tick_strings(&["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"])
}

/// Small wrapper around [`MultiProgress`] to cut down boilerplate.
struct Progress {
    mp: MultiProgress,
}

impl Progress {
    fn new(no_progress: bool) -> Self {
        let target = if no_progress {
            ProgressDrawTarget::hidden()
        } else {
            ProgressDrawTarget::stderr()
        };
        Self {
            mp: MultiProgress::with_draw_target(target),
        }
    }

    /// A spinner for phases with unknown duration.
    fn spinner(&self, message: &str) -> ProgressBar {
        let bar = self.mp.add(ProgressBar::new_spinner());
        bar.set_style(spinner_style());
        bar.enable_steady_tick(Duration::from_millis(80));
        bar.set_message(message.to_owned());
        bar
    }

    /// A determinate bar.
    fn bar(&self, len: u64, message: &str) -> ProgressBar {
        let bar = self.mp.add(ProgressBar::new(len));
        bar.set_style(bar_style());
        bar.set_message(message.to_owned());
        bar
    }

    /// Print a line below the active bars.
    fn line(&self, message: &str) {
        let _ = self.mp.println(message);
    }
}

/// A generated file: its final path and content.
struct OutputFile {
    path: PathBuf,
    content: String,
}

impl OutputFile {
    fn new(output_dir: &Path, rel_path: &str, content: String) -> Self {
        Self {
            path: output_dir.join(rel_path),
            content,
        }
    }
}

/// Refuse to delete obviously wrong targets when `--clean` is given.
fn is_safe_to_clean(output_dir: &Path) -> bool {
    !output_dir.as_os_str().is_empty()
        && output_dir != Path::new("/")
        && output_dir.parent().is_some()
}

/// Generate the whole site.
pub fn build(cli: &Cli) -> Result<()> {
    let progress = Progress::new(cli.no_progress);

    // 1. Discover the data source.
    let discover = progress.spinner(&format!("scanning {}…", cli.data_dir.display()));
    let crates = data::discover(&cli.data_dir)?;
    discover.finish_and_clear();
    progress.line(&format!("found {} crates", crates.len()));
    info!(
        "discovered {} crates in {}",
        crates.len(),
        cli.data_dir.display()
    );

    // 2. Optionally wipe the previous output (idempotent).
    if cli.clean && cli.output_dir.exists() {
        let clean = progress.spinner(&format!("removing {}…", cli.output_dir.display()));
        if !is_safe_to_clean(&cli.output_dir) {
            return Err(error::UnsafeCleanSnafu {
                path: cli.output_dir.clone(),
            }
            .build());
        }
        fs::remove_dir_all(&cli.output_dir).with_context(|_| error::RemoveDirSnafu {
            path: cli.output_dir.clone(),
        })?;
        clean.finish_and_clear();
        progress.line(&format!("removed {}", cli.output_dir.display()));
    }

    // 3. Render every page into memory.
    let render_bar = progress.bar(crates.len() as u64, "rendering redirect pages");
    let mut files: Vec<OutputFile> = Vec::with_capacity(crates.len() + 4);
    for krate in &crates {
        let name = krate.name.clone();
        let page = render::redirect_page(krate, &cli.base_url);
        files.push(OutputFile::new(
            &cli.output_dir,
            &format!("{name}/index.html"),
            page,
        ));
        debug!("rendered {name}");
        render_bar.set_message(name);
        render_bar.inc(1);
    }
    files.push(OutputFile::new(
        &cli.output_dir,
        "index.html",
        render::index_page(&crates, &cli.base_url),
    ));
    files.push(OutputFile::new(
        &cli.output_dir,
        "404.html",
        render::not_found_page(&crates, &cli.base_url),
    ));
    files.push(OutputFile::new(
        &cli.output_dir,
        "vercel.json",
        render::vercel_config(&crates),
    ));
    files.push(OutputFile::new(
        &cli.output_dir,
        "_redirects",
        render::netlify_redirects(&crates),
    ));
    render_bar.finish_with_message("done");
    progress.line(&format!("rendered {} pages", files.len()));

    // 4. Write everything to disk.
    let write_bar = progress.bar(files.len() as u64, "writing files");
    for file in &files {
        let parent = file
            .path
            .parent()
            .expect("output files always live in a directory");
        fs::create_dir_all(parent).with_context(|_| error::CreateDirSnafu {
            path: parent.to_owned(),
        })?;
        fs::write(&file.path, &file.content).with_context(|_| error::WriteFileSnafu {
            path: file.path.clone(),
        })?;
        debug!("wrote {}", file.path.display());
        write_bar.set_message(file.path.display().to_string());
        write_bar.inc(1);
    }
    write_bar.finish_with_message("done");
    progress.line(&format!("site generated in {}", cli.output_dir.display()));
    info!(
        "site generated in {} ({} files)",
        cli.output_dir.display(),
        files.len()
    );

    Ok(())
}
