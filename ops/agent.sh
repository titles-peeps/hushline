#!/usr/bin/env bash
set -euo pipefail
set -x

# usage: ops/agent.sh <issue_number>
if [[ $# -ne 1 ]]; then
  echo "usage: ops/agent.sh <issue_number>" >&2
  exit 2
fi

ISSUE="$1"

# --- Repo autodetect (owner/repo) with safe fallback ---
if REPO_URL="$(git config --get remote.origin.url 2>/dev/null)"; then
  case "$REPO_URL" in
    git@github.com:*.git) REPO="${REPO_URL#git@github.com:}"; REPO="${REPO%.git}";;
    https://github.com/*) REPO="${REPO_URL#https://github.com/}"; REPO="${REPO%.git}";;
    *) REPO="${REPO:-titles-peeps/hushline}";;
  esac
else
  REPO="${REPO:-titles-peeps/hushline}"
fi

# --- Auth / tokens ---
: "${GH_TOKEN:?GH_TOKEN must be set in env}"
export GITHUB_TOKEN="$GH_TOKEN"

# --- Keep Ollama tame on small boxes ---
export OLLAMA_API_BASE="${OLLAMA_API_BASE:-http://127.0.0.1:11434}"
export OLLAMA_HOST="${OLLAMA_HOST:-http://127.0.0.1:11434}"
export OLLAMA_NUM_PARALLEL="${OLLAMA_NUM_PARALLEL:-1}"
export OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-10m}"
export OLLAMA_NUM_CTX="${OLLAMA_NUM_CTX:-2048}"
# Optional: smaller GPU footprint
export OLLAMA_KV_CACHE_TYPE="${OLLAMA_KV_CACHE_TYPE:-cpu}"

# Aider should talk to Ollama directly (avoid LiteLLM indirection)
unset LITELLM_PROVIDER LITELLM_OLLAMA_BASE OPENAI_API_KEY ANTHROPIC_API_KEY

MODEL="${AIDER_MODEL:-ollama_chat/qwen2.5-coder:7b-instruct}"

# --- Sanity checks ---
for bin in gh git aider curl jq; do
  command -v "$bin" >/dev/null || { echo "missing dependency: $bin"; exit 1; }
done

[[ -d .git ]] || { echo "must run in repo root"; exit 1; }
[[ -f ops/agent_prompt.tmpl ]] || { echo "missing ops/agent_prompt.tmpl"; exit 1; }

# Git identity (local-only; workflow usually sets this too)
git config user.name  >/dev/null 2>&1 || git config user.name  "hushline-agent"
git config user.email >/dev/null 2>&1 || git config user.email "agent@users.noreply.github.com"

# --- Fail fast if Ollama is unhappy; also pull model if absent ---
set +e
curl -fsS "$OLLAMA_API_BASE/api/tags" | jq -r '.models[].name' >/dev/null
RC=$?
set -e
if [[ $RC -ne 0 ]]; then
  echo "Ollama not responding; aborting early"
  exit 1
fi

# Ensure the model is locally available
if ! curl -fsS "$OLLAMA_API_BASE/api/tags" | jq -e --arg m "qwen2.5-coder:7b-instruct" '.models[].name | contains($m)' >/dev/null 2>&1; then
  curl -fsS "$OLLAMA_API_BASE/api/pull" \
    -H 'Content-Type: application/json' \
    -d '{"model":"qwen2.5-coder:7b-instruct"}' >/dev/null
fi

# --- Get issue text (full body with newlines preserved) ---
ISSUE_TITLE="$(gh issue view "$ISSUE" -R "$REPO" --json title -q .title)"
ISSUE_BODY="$(gh issue view "$ISSUE" -R "$REPO" --json body  -q .body)"

# --- Default branch detection ---
DEFAULT_BRANCH="$(gh repo view "$REPO" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || true)"
[[ -z "$DEFAULT_BRANCH" ]] && DEFAULT_BRANCH="$(git remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p' || true)"
[[ -z "$DEFAULT_BRANCH" ]] && DEFAULT_BRANCH="main"

# --- New working branch from origin/<default> ---
BR="agent/issue-${ISSUE}-$(date +%Y%m%d-%H%M%S)"
git fetch origin --prune
git checkout -B "$BR" "origin/$DEFAULT_BRANCH"

# --- Build the prompt from template ---
export ISSUE_NUMBER="$ISSUE" ISSUE_TITLE ISSUE_BODY
envsubst < ops/agent_prompt.tmpl > /tmp/agent_prompt.txt

# --- Try to narrow files passed to aider (generic extensions) ---
TARGET_FILES=()
while IFS= read -r f; do
  [[ -f "$f" ]] && TARGET_FILES+=("$f")
done < <(
  printf '%s\n' "$ISSUE_BODY" |
    grep -Eo '([A-Za-z0-9._/-]+\.(py|js|jsx|ts|tsx|css|scss|sass|html|jinja|jinja2|sh|yml|yaml|toml|json|md|ini|cfg))' |
    sort -u
)

# --- Aider args: no playwright, short timeouts, tiny map ---
AIDER_ARGS=(
  --yes
  --no-gitignore
  --model "$MODEL"
  --edit-format udiff
  --timeout 60
  --no-stream
  --disable-playwright
  --map-refresh files
  --map-multiplier-no-files 0
  --map-tokens 256
  --max-chat-history-tokens 512
)

run_aider() {
  if [[ ${#TARGET_FILES[@]} -gt 0 ]]; then
    nice -n 10 ionice -c2 -n7 timeout -k 10 420 aider "${AIDER_ARGS[@]}" \
      --message "$(cat /tmp/agent_prompt.txt)" "${TARGET_FILES[@]}" || true
  else
    nice -n 10 ionice -c2 -n7 timeout -k 10 420 aider "${AIDER_ARGS[@]}" \
      --message "$(cat /tmp/agent_prompt.txt)" || true
  fi
}

# --- First and only pass (Path B keeps it simple) ---
run_aider

# --- Early exit if aider produced nothing (both staged & unstaged) ---
if git diff --quiet && git diff --cached --quiet; then
  if [[ ${#TARGET_FILES[@]} -gt 0 ]]; then
    gh issue comment "$ISSUE" -R "$REPO" -b "Agent attempted patch but produced no changes to: ${TARGET_FILES[*]}."
  else
    gh issue comment "$ISSUE" -R "$REPO" -b "Agent attempted patch but produced no changes."
  fi
  exit 0
fi

# --- Commit & push (no lint/tests in Path B) ---
git add -A
git commit -m "Agent patch for #${ISSUE}: ${ISSUE_TITLE}"
git push -u origin "$BR"

# --- PR create/update ---
EXISTING_PR="$(gh pr list -R "$REPO" --head "$BR" --json number -q '.[0].number')"
if [[ -z "$EXISTING_PR" ]]; then
  gh pr create -R "$REPO" \
    -t "Agent patch for #${ISSUE}: ${ISSUE_TITLE}" \
    -b "Automated patch for #${ISSUE}."
else
  gh pr comment -R "$REPO" "$EXISTING_PR" -b "Updated patch."
fi

# --- Link back to issue ---
gh issue comment "$ISSUE" -R "$REPO" -b "Agent created/updated PR from branch \`$BR\`."
