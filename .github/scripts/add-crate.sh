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
#   LLM_MODEL           preferred Gemini model id (optional; defaults
#                       are tried in order when unset or unavailable)
#   MAX_ATTEMPTS        search attempts before giving up (default: 20)
#   RATE_LIMIT_BACKOFF_SECS
#                       sleep after every candidate is rate-limited
#                       (default: 10)
#
# Exit code is 0 even when the agent gives up; the issue labels carry
# the outcome.

set -euo pipefail

: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${ISSUE:?ISSUE is required}"
: "${CRATE:?CRATE is required}"
: "${GEMINI_API_KEY:?GEMINI_API_KEY is required}"

MAX_ATTEMPTS="${MAX_ATTEMPTS:-20}"
API_BASE="https://generativelanguage.googleapis.com/v1beta/models"

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

# Models to try, in order: the explicitly configured model first, then
# known free-tier models that support the google_search tool.
llm_candidates() {
    if [[ -n "${LLM_MODEL:-}" ]]; then
        printf '%s\n' "$LLM_MODEL"
    fi
    # Free-tier flash models with independent rate-limit buckets, so a
    # throttled model is skipped in favor of the next one.
    printf '%s\n' \
        "gemini-2.5-flash" \
        "gemini-2.5-flash-lite" \
        "gemini-3.6-flash" \
        "gemini-2.0-flash" \
        "gemini-2.0-flash-lite"
}

# Build the JSON request body from the prompt. No responseMimeType here:
# combining JSON output mode with google_search grounding is rejected by
# some models, so the model is asked for JSON in-band instead.
llm_payload() {
    python3 -c '
import json, sys
print(json.dumps({
    "contents": [{"parts": [{"text": sys.argv[1]}]}],
    "tools": [{"google_search": {}}],
    "generationConfig": {"temperature": 0.2},
}))' "$1"
}

# Extract the model's error message, prefixed by its HTTP code, if the
# response is an error envelope. Prints e.g. "429 Quota exceeded ...".
llm_error() {
    python3 - "$1" <<'PYEOF'
import json, sys
try:
    err = json.loads(sys.argv[1]).get("error")
    if isinstance(err, dict):
        print(f"{err.get('code', '')} {err.get('message', '')}".strip())
    else:
        print("")
except Exception:
    print("")
PYEOF
}

# Extract a changelog URL from a model response. Handles the plain JSON
# envelope, markdown-fenced JSON, extra commentary, and a regex
# fallback. Prints the URL, or nothing.
llm_url() {
    python3 - "$1" <<'PYEOF'
import json, re, sys
text = sys.argv[1].strip()
try:
    data = json.loads(text)
    if isinstance(data, dict) and "candidates" in data:
        parts = data["candidates"][0].get("content", {}).get("parts", [])
        inner = "".join(p.get("text", "") for p in parts if isinstance(p, dict))
        if inner:
            text = inner
except Exception:
    pass
# Strip markdown code fences if the model wrapped its JSON anyway.
text = re.sub(r"```(?:json)?\s*", "", text)
text = re.sub(r"\s*```", "", text).strip()
url = ""
m = re.search(r"\{.*\}", text, re.S)
if m:
    try:
        u = json.loads(m.group(0)).get("changelog_url")
        if isinstance(u, str):
            url = u
    except Exception:
        pass
if not url:
    m = re.search(r'"changelog_url"\s*:\s*"([^"]+)"', text)
    if m:
        url = m.group(1)
print(url)
PYEOF
}

# Ask the model (with Google Search grounding) for a changelog URL.
# Prints the URL, or nothing if the model found none / every model
# failed. Falls back across llm_candidates() when a model is
# rate-limited or unavailable, and logs API errors so failures are
# visible. When every candidate is throttled, sleeps briefly so the
# next attempt has a chance.
llm_find_url() {
    local crate="$1" feedback="${2:-}" prompt model resp error_msg err_lower url rate_limited=""
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

Respond with a single JSON object and nothing else. No markdown, no
code fences, no commentary:
{"changelog_url": "https://..." or null, "reason": "short justification"}
EOF
)"

    for model in $(llm_candidates); do
        resp="$(curl -sS --max-time 60 -X POST \
            "${API_BASE}/${model}:generateContent?key=${GEMINI_API_KEY}" \
            -H "Content-Type: application/json" \
            -d "$(llm_payload "$prompt")" 2>/dev/null || true)"

        error_msg="$(llm_error "$resp")"
        if [[ -n "$error_msg" ]]; then
            err_lower="${error_msg,,}"
            case "$err_lower" in
                # Rate limits: try the next model instead of failing.
                *"429"* | *rate\ limit* | *quota* | *too\ many\ requests* | *exhausted* | *slow\ down*)
                    rate_limited="1"
                    info "rate limit on ${model}: ${error_msg}"
                    continue
                    ;;
                # Model availability issues fall through as well.
                *not\ found* | *not_found* | *permission* | *deprecated* | *does\ not\ exist* | *access*)
                    info "api error with ${model}: ${error_msg}"
                    continue
                    ;;
                # Anything else will not be fixed by another model.
                *)
                    info "api error with ${model}: ${error_msg}"
                    return 0
                    ;;
            esac
        fi

        url="$(llm_url "$resp")"
        if [[ -n "$url" ]]; then
            printf '%s' "$url"
            return 0
        fi
        info "model ${model} returned no usable URL"
        return 0
    done

    if [[ -n "$rate_limited" ]]; then
        info "all models rate limited; backing off ${RATE_LIMIT_BACKOFF_SECS:-10}s"
        sleep "${RATE_LIMIT_BACKOFF_SECS:-10}"
    fi
    return 0
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
