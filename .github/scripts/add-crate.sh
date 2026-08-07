#!/usr/bin/env bash
#
# Agentic handler for "changelog redirect request" issues.
#
#   1. Uses the requester's suggested URL if it is valid and reachable.
#   2. Otherwise asks a free-tier LLM with web search (Google Gemini,
#      `google_search` tool) to find the best changelog URL for the
#      crate, retrying with feedback when candidates fail validation.
#   3. Opens a PR that adds `data/<first two letters>/<rest>/changelog`
#      and closes the issue, or labels the issue `needs-human-help`.
#
# Environment (set by the workflow):
#   GITHUB_TOKEN        token for gh / git push
#   GITHUB_REPOSITORY   owner/repo
#   ISSUE               issue number
#   CRATE               crate name parsed from the issue body
#   SUGGESTED_URL       optional suggested changelog URL (may be empty)
#   GEMINI_API_KEY      free Google AI Studio API key
#   LLM_MODEL           Gemini model id (default: gemini-2.5-flash)
#   MAX_ATTEMPTS        LLM search attempts before giving up (default: 3)
#
# Exit code is 0 even when the agent gives up; the issue labels carry
# the outcome.

set -euo pipefail

: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${ISSUE:?ISSUE is required}"
: "${CRATE:?CRATE is required}"
: "${GEMINI_API_KEY:?GEMINI_API_KEY is required}"

MODEL="${LLM_MODEL:-gemini-2.5-flash}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-20}"
API_BASE="https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent"

comment() { gh issue comment "$ISSUE" --body "$1" >/dev/null; }
label() { gh issue edit "$ISSUE" --add-label "$1" >/dev/null || true; }
info() { printf '\033[36m[agent]\033[0m %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

is_http_url() { [[ "$1" == http://* || "$1" == https://* ]]; }

# Resolve the canonical data path for a crate, mirroring src/data.rs.
shard_path() {
    local name="$1"
    if ((${#name} <= 2)); then
        printf 'data/%s/changelog' "$name"
    else
        printf 'data/%s/%s/changelog' "${name:0:2}" "${name:2}"
    fi
}

# A URL is usable when it answers to HEAD with 2xx/3xx; 405 means the
# server rejects HEAD, which is fine, and 000 means the check failed.
url_reachable() {
    local url="$1" code
    code="$(curl -sSIL --max-time 25 -A "crate-changelog-bot" -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)"
    [[ "$code" =~ ^(200|201|204|301|302|307|308|405)$ ]]
}

# Ask the model (with Google Search grounding) for a changelog URL.
# Prints the URL, or nothing if the model found none / the API failed.
llm_find_url() {
    local crate="$1" feedback="${2:-}" prompt payload resp url
    prompt="$(cat <<EOF
You maintain crate-changelog, a service that redirects
https://crate-changelog.kxxt.dev/<crate> to that crate's changelog page.

Task: find the best changelog URL for the Rust crate "$crate".

Requirements:
- The URL must point to a stable, human-readable page with the crate's
  release notes (a CHANGELOG.md / RELEASES.md, or a releases page).
- Prefer the official upstream repository. If you need its location,
  use web search (the crates.io page https://crates.io/crates/$crate is
  a good starting point).
- Prefer the rendered changelog file on the web, e.g.
  https://github.com/OWNER/REPO/blob/BRANCH/CHANGELOG.md; a GitHub
  releases page is acceptable when the repository has no changelog
  file. A docs.rs source page is a last resort.
- Use web search to confirm the URL actually contains changelog
  content. Do not invent URLs.
$(if [[ -n "$feedback" ]]; then printf '%s' "- The previous candidate failed validation: $feedback. Find a different, correct URL."; fi)

Respond with JSON only:
{"changelog_url": "https://..." or null, "reason": "short justification"}
EOF
)"

    payload="$(python3 -c '
import json, sys
print(json.dumps({
    "contents": [{"parts": [{"text": sys.argv[1]}]}],
    "tools": [{"google_search": {}}],
    "generationConfig": {"responseMimeType": "application/json", "temperature": 0.2},
}))' "$prompt")"
    resp="$(curl -sS --max-time 60 -X POST "$API_BASE?key=$GEMINI_API_KEY" \
        -H "Content-Type: application/json" -d "$payload" 2>/dev/null || true)"
    url="$(printf '%s' "$resp" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    text = data["candidates"][0]["content"]["parts"][0]["text"]
    parsed = json.loads(text)
    u = parsed.get("changelog_url")
    print(u if isinstance(u, str) else "")
except Exception:
    print("")
')"
    printf '%s' "$url"
}

# Resolve the changelog URL: suggested one first, then the LLM loop.
resolve_url() {
    local crate="$1" suggested="$2" attempt feedback="" url

    if [[ -n "$suggested" ]]; then
        if is_http_url "$suggested" && url_reachable "$suggested"; then
            info "using the suggested URL: $suggested"
            printf '%s\n' "$suggested"
            return 0
        fi
        comment "The suggested URL \`$suggested\` is not usable (not an http(s) URL or not reachable), so I searched for one."
    fi

    for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
        info "search attempt $attempt/$MAX_ATTEMPTS for $crate"
        url="$(llm_find_url "$crate" "$feedback")"
        if [[ -z "$url" ]] || ! is_http_url "$url"; then
            feedback="the model returned no usable URL"
            continue
        fi
        if ! url_reachable "$url"; then
            feedback="the URL $url is not reachable"
            continue
        fi
        info "found $url (attempt $attempt)"
        printf '%s\n' "$url"
        return 0
    done

    info "gave up after $MAX_ATTEMPTS attempts"
    return 1
}

# Add the data file and open a PR that closes the issue.
open_pr() {
    local url="$1" path branch pr_number
    path="$(shard_path "$CRATE")"

    if [[ -f "$path" ]]; then
        comment "**$CRATE** is already tracked (see \`$path\`). Closing."
        gh issue close "$ISSUE" --reason completed >/dev/null
        info "already tracked at $path"
        return 0
    fi

    branch="changelog/$CRATE"
    if gh pr view "$branch" --json number -q .number >/dev/null 2>&1; then
        info "PR for branch $branch already exists; nothing to do"
        return 0
    fi

    mkdir -p "$(dirname "$path")"
    printf '%s\n' "$url" >"$path"

    git config user.name "github-actions[bot]"
    git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
    git switch -c "$branch"
    git add "$path"
    git commit -m "Add changelog redirect for $CRATE" -q
    git push "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" \
        "HEAD:refs/heads/$branch" -q

    pr_number="$(gh pr create \
        --title "Add changelog redirect for $CRATE" \
        --body "Adds the changelog redirect for **$CRATE**.

Changelog URL: $url

Closes #$ISSUE" \
        --label changelog-pr \
        --head "$branch" \
        --json number -q .number)"
    info "opened PR #$pr_number"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if [[ ! "$CRATE" =~ ^[a-zA-Z0-9_-]{1,64}$ ]]; then
    comment "The crate name \`$CRATE\` is not a valid crates.io name (1-64 chars of \`[a-zA-Z0-9_-]\`)."
    label needs-human-help
    exit 0
fi

# Nothing to do when the crate is already tracked.
tracked_path="$(shard_path "$CRATE")"
if [[ -f "$tracked_path" ]]; then
    comment "**$CRATE** is already tracked (see \`$tracked_path\`). Closing."
    gh issue close "$ISSUE" --reason completed >/dev/null
    info "already tracked at $tracked_path"
    exit 0
fi

if url="$(resolve_url "$CRATE" "$SUGGESTED_URL")"; then
    open_pr "$url"
    label agent-done
else
    label needs-human-help
    comment "I could not find a changelog URL for **$CRATE** after $MAX_ATTEMPTS search attempts. A human should take a look (check \`$CRATE\` on [crates.io](https://crates.io/crates/$CRATE))."
    info "labeled issue #$ISSUE as needs-human-help"
fi
