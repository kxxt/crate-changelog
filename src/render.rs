//! Generation of the static site's HTML, plus deployment helper files.
//!
//! Everything is deterministic: given the same data, the same bytes come
//! out, so the site can be rebuilt reproducibly in CI.
//!
//! Redirect pages work everywhere, no server support needed:
//!
//! - `<meta http-equiv="refresh">` covers static hosts (GitHub Pages),
//! - a tiny `location.replace` script covers browsers that ignore it,
//! - a plain link is the no-JavaScript fallback.

use std::fmt::Write as _;

use crate::data::Crate;

/// Escape a string for safe embedding into HTML text and attributes.
fn escape_html(s: &str) -> String {
    if !s
        .bytes()
        .any(|b| matches!(b, b'&' | b'<' | b'>' | b'"' | b'\''))
    {
        return s.to_owned();
    }
    let mut out = String::with_capacity(s.len());
    for ch in s.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            _ => out.push(ch),
        }
    }
    out
}

/// Join a base URL and a path segment without duplicating slashes.
fn join_url(base: &str, segment: &str) -> String {
    let base = base.trim_end_matches('/');
    format!("{base}/{segment}")
}

/// Wrap HTML in a shared page skeleton.
fn page(title: &str, body: &str, extra_head: &str) -> String {
    format!(
        "<!doctype html>\n\
         <html lang=\"en\">\n\
         <head>\n\
         <meta charset=\"utf-8\">\n\
         <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n\
         <title>{title}</title>\n\
         <style>\n\
         :root {{ color-scheme: light dark; }}\n\
         body {{ font-family: system-ui, -apple-system, sans-serif; line-height: 1.5;\n\
                 max-width: 44rem; margin: 3rem auto; padding: 0 1rem; }}\n\
         a {{ color: #0b7cbb; }}\n\
         code {{ background: #00000022; padding: 0.1em 0.35em; border-radius: 0.3em; }}\n\
         table {{ border-collapse: collapse; width: 100%; }}\n\
         td, th {{ text-align: left; padding: 0.35rem 0.6rem;\n\
                   border-bottom: 1px solid #00000022; }}\n\
         </style>\n\
         {extra_head}\n\
         </head>\n\
         <body>\n{body}\n</body>\n</html>\n"
    )
}

/// The redirect page served at `/<crate>/`.
pub fn redirect_page(krate: &Crate, base_url: &str) -> String {
    let name = escape_html(&krate.name);
    let url = escape_html(&krate.url);
    let canonical = escape_html(&join_url(base_url, &krate.name));

    let head = format!(
        "<meta http-equiv=\"refresh\" content=\"0; url={url}\">\n\
         <link rel=\"canonical\" href=\"{canonical}\">\n\
         <meta name=\"robots\" content=\"noindex\">\n"
    );
    let body = format!(
        "<main>\n\
         <h1>Redirecting to the <code>{name}</code> changelog&hellip;</h1>\n\
         <p>If you are not redirected automatically, <a id=\"go\" href=\"{url}\">follow this link</a>.</p>\n\
         <p><a href=\"{base_url}\">&larr; All crates</a></p>\n\
         </main>\n\
         <script>\n\
         window.setTimeout(function () {{\n\
           window.location.replace(document.getElementById(\"go\").getAttribute(\"href\"));\n\
         }}, 300);\n\
         </script>\n"
    );

    page(
        &format!("Redirecting to the {name} changelog"),
        &body,
        &head,
    )
}

/// The crate index served at `/`.
pub fn index_page(crates: &[Crate], base_url: &str) -> String {
    let mut rows = String::new();
    for krate in crates {
        let name = escape_html(&krate.name);
        let url = escape_html(&krate.url);
        let href = escape_html(&join_url(base_url, &krate.name));
        let _ = writeln!(
            rows,
            "<tr><td><a href=\"{href}\">{name}</a></td><td><a href=\"{url}\">{url}</a></td></tr>"
        );
    }

    let body = format!(
        "<header>\n\
         <h1>crate-changelog</h1>\n\
         <p>Every <code>/&lt;crate&gt;</code> path on this site redirects to that crate's changelog.</p>\n\
         </header>\n\
         <main>\n\
         <input id=\"search\" type=\"search\" placeholder=\"filter crates&hellip;\" autofocus>\n\
         <table>\n\
         <thead><tr><th>Crate</th><th>Changelog</th></tr></thead>\n\
         <tbody id=\"rows\">\n{rows}</tbody>\n\
         </table>\n\
         <p>Missing a crate? Add a <code>data/&lt;first two letters&gt;/&lt;rest&gt;/changelog</code>\n\
         file and rebuild &mdash; see the <a href=\"{base_url}\">index</a> for how.</p>\n\
         </main>\n\
         <script>\n\
         const input = document.getElementById(\"search\");\n\
         input.addEventListener(\"input\", () => {{\n\
           const q = input.value.toLowerCase();\n\
           for (const tr of document.getElementById(\"rows\").children) {{\n\
             tr.hidden = !tr.firstElementChild.textContent.toLowerCase().includes(q);\n\
           }}\n\
         }});\n\
         </script>\n"
    );

    page("crate-changelog", &body, "")
}

/// The error page served for unknown crates at `/404.html`.
pub fn not_found_page(crates: &[Crate], base_url: &str) -> String {
    let mut list = String::new();
    for krate in crates {
        let name = escape_html(&krate.name);
        let href = escape_html(&join_url(base_url, &krate.name));
        let _ = writeln!(list, "<li><a href=\"{href}\">{name}</a></li>");
    }

    let body = format!(
        "<main>\n\
         <h1>No changelog data for <code id=\"missing\">this crate</code></h1>\n\
         <p>We don't have a changelog entry for it yet. This site is generated from a small\n\
         data source: each crate maps to the file\n\
         <code>data/&lt;first two letters&gt;/&lt;rest&gt;/changelog</code>, whose content is the\n\
         changelog URL. For <code>tracexec</code> that is\n\
         <code>data/tr/acexec/changelog</code>.</p>\n\
         <p>To add a crate, open a pull request against the\n\
         <a href=\"https://github.com/kxxt/crate-changelog\">crate-changelog repository</a> adding\n\
         such a file, or open an issue asking for it.</p>\n\
         <p><a href=\"{base_url}\">&larr; Back to the index</a></p>\n\
         <h2>Known crates</h2>\n\
         <input id=\"search\" type=\"search\" placeholder=\"filter crates&hellip;\">\n\
         <ul id=\"crates\">\n{list}</ul>\n\
         </main>\n\
         <script>\n\
         const path = decodeURIComponent(location.pathname).replace(/^\\/+|\\/+$/g, \"\");\n\
         const missing = document.getElementById(\"missing\");\n\
         if (path) missing.textContent = path.split(\"/\")[0];\n\
         const input = document.getElementById(\"search\");\n\
         input.addEventListener(\"input\", () => {{\n\
           const q = input.value.toLowerCase();\n\
           for (const li of document.getElementById(\"crates\").children) {{\n\
             li.hidden = !li.textContent.toLowerCase().includes(q);\n\
           }}\n\
         }});\n\
         </script>\n"
    );

    page(
        "crate not found - crate-changelog",
        &body,
        "<meta name=\"robots\" content=\"noindex\">",
    )
}

/// Vercel configuration with server-side redirects (takes precedence over
/// the static pages when deployed on Vercel).
pub fn vercel_config(crates: &[Crate]) -> String {
    let mut entries = String::new();
    let last = crates.len().saturating_sub(1);
    for (i, krate) in crates.iter().enumerate() {
        let comma = if i == last { "" } else { "," };
        let _ = writeln!(
            entries,
            "    {{ \"source\": \"/{}\", \"destination\": \"{}\", \"statusCode\": 302 }}{comma}",
            krate.name, krate.url
        );
    }
    format!(
        "{{\n  \"$schema\": \"https://openapi.vercel.sh/vercel.json\",\n  \"redirects\": [\n{entries}  ]\n}}\n"
    )
}

/// Netlify-style redirects, also understood by other hosts.
pub fn netlify_redirects(crates: &[Crate]) -> String {
    let mut out = String::new();
    for krate in crates {
        let _ = writeln!(out, "/{} {} 302", krate.name, krate.url);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn krate(name: &str, url: &str) -> Crate {
        Crate {
            name: name.to_owned(),
            url: url.to_owned(),
            source: PathBuf::new(),
        }
    }

    #[test]
    fn escape_leaves_plain_text_alone() {
        assert_eq!(escape_html("tracexec"), "tracexec");
    }

    #[test]
    fn escape_handles_special_chars() {
        assert_eq!(
            escape_html(r#"<a href="x">&'"#),
            "&lt;a href=&quot;x&quot;&gt;&amp;&#39;"
        );
    }

    #[test]
    fn redirect_page_has_meta_refresh_and_fallback() {
        let page = redirect_page(
            &krate("tracexec", "https://example.com/CHANGELOG.md"),
            "https://base.dev/",
        );
        assert!(page.contains(
            "http-equiv=\"refresh\" content=\"0; url=https://example.com/CHANGELOG.md\""
        ));
        assert!(page.contains("follow this link"));
        assert!(page.contains("rel=\"canonical\" href=\"https://base.dev/tracexec\""));
        assert!(page.contains("noindex"));
    }

    #[test]
    fn vercel_config_has_no_trailing_comma() {
        let two = vercel_config(&[krate("a", "https://a"), krate("b", "https://b")]);
        assert_eq!(
            two.matches("},").count(),
            1,
            "only the first entry may carry a comma"
        );
        assert!(two.contains("\"source\": \"/a\""));

        let one = vercel_config(&[krate("a", "https://a")]);
        assert_eq!(one.matches("},").count(), 0);
    }

    #[test]
    fn netlify_redirects_lines() {
        let out = netlify_redirects(&[krate("a", "https://a"), krate("b", "https://b")]);
        assert_eq!(out, "/a https://a 302\n/b https://b 302\n");
    }
}
