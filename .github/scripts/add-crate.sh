#!/usr/bin/env bash
#
# Agentic handler for "changelog redirect request" issues.
#
#   1. Uses the requester's suggested URL if it is valid and reachable.
#   2. Otherwise gathers evidence with a free search harness and asks a
#      free LLM on OpenRouter to pick the best changelog URL, retrying
#      with feedback when candidates fail validation.
#   3. Opens a PR that adds `data/<first two letters>/<rest>/changelog`
#      and closes the issue, or labels the issue `needs-human-help`.
#
# The whole pipeline is free:
#   - web search: DuckDuckGo HTML endpoint (no API key)
#   - crate metadata: crates.io JSON API (no API key)
#   - reasoning: OpenRouter :free models ($0 tokens, no tools needed)
#
# Environment (set by the workflow):
#   GITHUB_TOKEN        token for gh / git push
#   GITHUB_REPOSITORY   owner/repo
#   ISSUE               issue number
#   CRATE               crate name parsed from the issue body
#   SUGGESTED_URL       optional suggested changelog URL (may be empty)
#   OPENROUTER_API_KEY  OpenRouter API key (free models cost nothing)
#   OPENROUTER_MODEL    preferred OpenRouter model (optional)
#   MAX_ATTEMPTS        search attempts before giving up (default: 20)
#   RATE_LIMIT_BACKOFF_SECS
#                       sleep after every model is rate-limited
#                       (default: 10)
#
# Exit code is 0 even when the agent gives up; the issue labels carry
# the outcome.

set -euo pipefail

: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${ISSUE:?ISSUE is required}"
: "${CRATE:?CRATE is required}"
: "${OPENROUTER_API_KEY:?OPENROUTER_API_KEY is required}"

MAX_ATTEMPTS="${MAX_ATTEMPTS:-20}"
RATE_LIMIT_BACKOFF_SECS="${RATE_LIMIT_BACKOFF_SECS:-10}"
OPENROUTER_API="https://openrouter.ai/api/v1/chat/completions"
DDG_URL="https://html.duckduckgo.com/html/"
UA="Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0"
SEARCH_RESULTS_PER_QUERY=6

comment() { gh issue comment "$ISSUE" --body "$1" >/dev/null; }
label() { gh issue edit "$ISSUE" --add-label "$1" >/dev/null || true; }
info() { printf '\033[36m[agent]\033[0m %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# Free search harness
# ---------------------------------------------------------------------------

# Query DuckDuckGo and print one "TITLE<TAB>URL<TAB>SNIPPET" line per
# result, with redirect links decoded. Returns 1 when nothing came back.
ddg_search() {
    local query="$1" max="${2:-$SEARCH_RESULTS_PER_QUERY}" encoded page
    encoded="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$query")"
    page="$(curl -s --max-time 25 -A "$UA" "${DDG_URL}?q=${encoded}" 2>/dev/null || true)"
    [[ -n "$page" ]] || return 1
    python3 - "$max" "$page" <<'PYEOF'
import html, re, sys, urllib.parse
max_results = int(sys.argv[1])
t = sys.argv[2]
links = re.findall(r'<a rel="nofollow" class="result__a" href="([^"]+)">(.*?)</a>', t, re.S)
snips = re.findall(r'<a class="result__snippet"[^>]*>(.*?)</a>', t, re.S)
for i, (href, title) in enumerate(links[:max_results]):
    u = urllib.parse.parse_qs(urllib.parse.urlparse(href).query).get("uddg", [href])[0]
    u = html.unescape(u)
    title = html.unescape(re.sub(r"<[^>]+>", "", title)).strip()
    snip = ""
    if i < len(snips):
        snip = html.unescape(re.sub(r"<[^>]+>", "", snips[i])).strip()
    print(f"{title}\t{u}\t{snip}")
PYEOF
}

# Fetch crates.io metadata and print "key: value" lines for the fields
# that point at the crate's presence on the web.
crates_meta() {
    local crate="$1" json
    json="$(curl -s --max-time 25 -A "crate-changelog-bot (crate-changelog CI)" \
        "https://crates.io/api/v1/crates/$crate" 2>/dev/null || true)"
    [[ -n "$json" ]] || return 1
    python3 - "$json" <<'PYEOF'
import json, sys
try:
    crate = json.loads(sys.argv[1]).get("crate", {})
except Exception:
    crate = {}
for key in ("repository", "homepage", "documentation"):
    value = crate.get(key)
    if isinstance(value, str) and value:
        print(f"{key}: {value}")
PYEOF
}

# Build the evidence block: crates.io metadata plus web search results.
gather_evidence() {
    local crate="$1" meta search1 search2 url
    printf -- '- crates.io metadata:\n'
    if meta="$(crates_meta "$crate")"; then
        printf '%s\n' "$meta" | sed 's/^/  /'
    else
        printf '  (crates.io metadata unavailable)\n'
    fi

    printf -- '- web search for "%s changelog":\n' "$crate"
    if search1="$(ddg_search "$crate changelog")"; then
        printf '%s\n' "$search1" | awk -F '\t' '{printf "  %d. %s — %s — %s\n", NR, $1, $2, $3}'
    else
        printf '  (no results)\n'
    fi

    printf -- '- web search for "%s rust crate":\n' "$crate"
    if search2="$(ddg_search "$crate rust crate")"; then
        printf '%s\n' "$search2" | awk -F '\t' '{printf "  %d. %s — %s — %s\n", NR, $1, $2, $3}'
    else
        printf '  (no results)\n'
    fi
}

# ---------------------------------------------------------------------------
# LLM helpers (OpenRouter free models)
# ---------------------------------------------------------------------------

# Free-tier models to try, in order: the configured one first, then
# large instruct models. Rate limits and availability vary per model,
# so a throttled one is skipped in favor of the next.
or_models() {
    if [[ -n "${OPENROUTER_MODEL:-}" ]]; then
        printf '%s\n' "$OPENROUTER_MODEL"
    fi
    printf '%s\n' \
        "nvidia/nemotron-3-ultra-550b-a55b:free" \
        "openai/gpt-oss-20b:free" \
        "google/gemma-4-31b-it:free" \
        "nvidia/nemotron-3-super-120b-a12b:free" \
        "google/gemma-4-26b-a4b-it:free" \
        "nvidia/nemotron-nano-12b-v2-vl:free" \
        "poolside/laguna-s-2.1:free"
}

# OpenAI-style chat completions request; no tools, so :free models stay $0.
or_payload() {
    python3 -c '
import json, sys
print(json.dumps({
    "model": sys.argv[1],
    "messages": [{"role": "user", "content": sys.argv[2]}],
    "max_tokens": 1000,
    "temperature": 0.2,
}))' "$1" "$2"
}

or_request() {
    curl -sS --max-time 90 -X POST "$OPENROUTER_API" \
        -H "Authorization: Bearer ${OPENROUTER_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$(or_payload "$1" "$2")" 2>/dev/null || true
}

# Extract the API's error message, prefixed by its HTTP code, if the
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

# Extract a changelog URL from the model's reply. Handles the OpenAI-
# style envelope, markdown-fenced JSON, extra commentary, and a regex
# fallback. Prints the URL, or nothing.
llm_url() {
    python3 - "$1" <<'PYEOF'
import json, re, sys
text = sys.argv[1].strip()
try:
    data = json.loads(text)
    if isinstance(data, dict) and "choices" in data:
        content = data["choices"][0].get("message", {}).get("content")
        if isinstance(content, str) and content:
            text = content
except Exception:
    pass
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

# Ask the free models to pick the best changelog URL from the evidence.
# Prints the URL, or nothing if every model failed or found none.
# Logs errors so failures are visible, and sleeps briefly when every
# model was rate-limited so the next attempt has a chance.
llm_pick_url() {
    local crate="$1" evidence="$2" feedback="${3:-}" prompt model resp error_msg err_lower url rate_limited=""
    prompt="$(cat <<EOF
You maintain crate-changelog, a service that redirects
https://crate-changelog.kxxt.dev/<crate> to that crate's changelog page.

Task: choose the best changelog URL for the Rust crate "$crate" from
the evidence below.

Evidence:
$evidence

Rules:
- The URL must point to a stable, human-readable page with the crate's
  release notes (a CHANGELOG.md / RELEASES.md, or a releases page).
- Prefer a rendered changelog file in the official repository, e.g.
  https://github.com/OWNER/REPO/blob/BRANCH/CHANGELOG.md. A GitHub
  releases page is acceptable when the repository has no changelog
  file. A docs.rs source page is a last resort.
- Only use URLs from the evidence. Do not invent or guess URLs.
$(if [[ -n "$feedback" ]]; then printf '%s' "- The previous candidate failed validation: $feedback. Choose a different URL from the evidence."; fi)

Respond with a single JSON object and nothing else. No markdown, no
code fences, no commentary:
{"changelog_url": "https://..." or null, "reason": "short justification"}
EOF
)"

    for model in $(or_models); do
        resp="$(or_request "$model" "$prompt")"
        error_msg="$(llm_error "$resp")"
        if [[ -n "$error_msg" ]]; then
            err_lower="${error_msg,,}"
            case "$err_lower" in
                # Rate limits / availability: try the next model.
                *"429"* | *rate\ limit* | *quota* | *too\ many\ requests* | *exhausted* | *slow\ down* | *requests\ per\ minute* | *rpm* | *daily\ limit* | *free\ model* | *credits* | *payment* | *balance* | *insufficient* | *not\ found* | *not_found* | *permission* | *deprecated* | *does\ not\ exist* | *access*)
                    rate_limited="1"
                    info "model ${model} unavailable: ${error_msg}"
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
        info "all models unavailable; backing off ${RATE_LIMIT_BACKOFF_SECS}s"
        sleep "$RATE_LIMIT_BACKOFF_SECS"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# URL validation and the main search loop
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

# Resolve the changelog URL: suggested one first, then the evidence +
# LLM loop.
resolve_url() {
    local crate="$1" suggested="$2" attempt evidence feedback="" url

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
        info "gathering evidence (crates.io + web search)"
        evidence="$(gather_evidence "$crate")"
        url="$(llm_pick_url "$crate" "$evidence" "$feedback")"
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
    if gh pr view "$branch" >/dev/null 2>&1; then
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

    # Older gh versions do not support --json on `pr create`; the PR
    # URL it prints is enough to recover the number.
    pr_url="$(gh pr create \
        --title "Add changelog redirect for $CRATE" \
        --body "Adds the changelog redirect for **$CRATE**.

Changelog URL: $url

Closes #$ISSUE" \
        --label changelog-pr \
        --head "$branch")"
    pr_number="$(printf '%s' "$pr_url" | sed -n 's#.*/pull/\([0-9][0-9]*\).*#\1#p')"
    info "opened PR #${pr_number:-?}"
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
