# crate-changelog

[![CI](https://github.com/kxxt/crate-changelog/actions/workflows/ci.yml/badge.svg)](https://github.com/kxxt/crate-changelog/actions/workflows/ci.yml)

A static site generator, written in Rust, that powers
[crate-changelog.kxxt.dev](https://crate-changelog.kxxt.dev): every
`/<crate>` path redirects to that crate's changelog.

For example, `https://crate-changelog.kxxt.dev/tracexec` redirects to
[the `tracexec` changelog](https://github.com/kxxt/tracexec/blob/main/CHANGELOG.md).

## How it works

The changelog data source lives in [`data/`](data/): one file per crate,
named `changelog`, whose content is the URL of that crate's changelog.
Crate names of more than two characters are sharded by their first two
letters:

```text
data/
└── tr/                 <- first two letters of the crate name
    └── acexec/         <- the rest of the name
        └── changelog   <- contains https://github.com/kxxt/tracexec/blob/main/CHANGELOG.md
```

Names of at most two characters live directly at `data/<name>/changelog`.

The generator (`cargo run`) reads this data source and emits a fully
static site into `site/`:

| Output                  | Purpose                                                        |
| ----------------------- | -------------------------------------------------------------- |
| `site/<crate>/index.html` | redirect page (meta refresh + JS + link fallback)            |
| `site/index.html`       | index of all known crates                                      |
| `site/404.html`         | error page for unknown crates, explaining how to add data      |
| `site/vercel.json`      | server-side 302 redirects when deployed on Vercel              |
| `site/_redirects`       | Netlify-style redirects for other hosts                        |

Redirect pages use `<meta http-equiv="refresh">` plus a
`location.replace` script and a plain link, so they work on any static
host (GitHub Pages, Vercel, Netlify, ...) without server support. For
Vercel, the generated `vercel.json` additionally performs server-side
302 redirects.

## Usage

```console
$ cargo run --release                     # generate the site into site/
$ cargo run --release -- --clean          # wipe site/ before generating
$ cargo run --release -- --output-dir out --data-dir data
$ cargo run --release -- --no-progress    # no progress bars (CI logs)
$ cargo run --release -- -v               # debug logging
$ cargo run --release -- add eza https://github.com/eza-community/eza/blob/main/CHANGELOG.md
```

Logging is handled by [spdlog-rs](https://crates.io/crates/spdlog-rs)
(configure it with the `SPDLOG_RS_LEVEL` environment variable), errors
are typed with [snafu](https://crates.io/crates/snafu) and rendered
through [color-eyre](https://crates.io/crates/color-eyre), the CLI is
parsed with [palc](https://crates.io/crates/palc), and progress is
reported with [indicatif](https://crates.io/crates/indicatif).

```console
$ cargo test
$ cargo clippy --all-targets
```

## Continuous integration

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs on every push
and pull request and covers:

- `cargo fmt --all --check` (formatting),
- `cargo clippy --all-targets -- -D warnings`,
- `crate-ci/typos` against [`typos.toml`](typos.toml),
- `cargo test --all-targets`.

## Deployment

### GitHub Pages

A workflow ([`.github/workflows/deploy.yml`](.github/workflows/deploy.yml))
builds the site and publishes it with `actions/deploy-pages`. In the
repository settings, set **Pages → Build and deployment → Source** to
*GitHub Actions*. The site is generated deterministically, so the
workflow is reproducible.

### Vercel

Point a Vercel project at this repository and build with:

```console
$ cargo run --release -- --clean --no-progress --output-dir .vercel-output
```

with output directory `.vercel-output`. The generated `vercel.json`
performs server-side redirects, and `404.html` covers unknown crates.

## Adding a crate

1. Find the changelog URL of the crate.
2. Add a `changelog` file at `data/<first two letters>/<rest>/changelog`
   containing the URL (a trailing newline is fine).
3. Rebuild and open a pull request.

Or use the helper subcommand:

```console
$ cargo run -- add <crate-name> <changelog-url>
```

### Automated crate intake (agent)

Issues filed with the **Changelog redirect request**
([template](.github/ISSUE_TEMPLATE/changelog_redirect.yml)) are handled
automatically by [`.github/workflows/add-crate.yml`](.github/workflows/add-crate.yml):

1. **Validate** — the required `crate` field is checked against
   crates.io. If the crate does not exist, the bot comments and closes
   the issue (`crate-not-found`).
2. **Search** — if the optional `suggested changelog url` is valid and
   reachable it is used directly. Otherwise
   [`.github/scripts/add-crate.sh`](.github/scripts/add-crate.sh) runs a
   free search harness and asks a free LLM to pick the best changelog
   URL for the crate. Candidates are validated with HTTP HEAD requests
   and the search is retried with feedback (up to `MAX_ATTEMPTS`
   times).
3. **PR or human help** — a found URL becomes a pull request that adds
   the `changelog` data file and closes the issue (`Closes #N`); if
   nothing usable is found the issue is labelled `needs-human-help`.

The whole pipeline is free:

- **web search** — [DuckDuckGo](https://duckduckgo.com) HTML endpoint
  (no API key), queried for `<crate> changelog` and `<crate> rust crate`;
- **crate metadata** — the [crates.io JSON API](https://crates.io/api)
  (repository, homepage, documentation links);
- **reasoning** — [OpenRouter](https://openrouter.ai) `:free` models
  (`$0` tokens; the agent picks from the evidence, no paid search, no
  tool calling).

Configure the API key in the repository settings:

| Secret / variable                   | Value                                            |
| ----------------------------------- | ------------------------------------------------ |
| `OPENROUTER_API_KEY` (secret)       | key from <https://openrouter.ai/keys>            |
| `OPENROUTER_MODEL` (variable)       | preferred model, default `nvidia/nemotron-3-ultra-550b-a55b:free` |
| `MAX_ATTEMPTS` (variable)           | search attempts before giving up (default: 20)   |
| `RATE_LIMIT_BACKOFF_SECS` (variable)| sleep after every model is rate-limited (default: 10) |

When a free model is rate-limited (`429`) or unavailable, the agent
automatically falls back to the next model in its list
(`nemotron-3-ultra-550b-a55b:free`, `gpt-oss-20b:free`,
`gemma-4-31b-it:free`, `nemotron-3-super-120b-a12b:free`,
`gemma-4-26b-a4b-it:free`, `nemotron-nano-12b-v2-vl:free`,
`laguna-s-2.1:free`), so a single throttled model does not stall the
workflow. If `OPENROUTER_API_KEY` is missing, the issue is labelled
`needs-human-help` instead of failing.

## License

MIT OR Apache-2.0.
