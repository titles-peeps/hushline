#!/usr/bin/env bash
set -euo pipefail

# usage: ops/agent.sh <issue_number>
if [[ $# -ne 1 ]]; then
  echo "usage: ops/agent.sh <issue_number>" >&2
  exit 2
fi

ISSUE="$1"

# --- Config & environment ----------------------------------------------------

: "${GH_TOKEN:?GH_TOKEN must be set (provided by Actions as GITHUB_TOKEN)}"
export GITHUB_TOKEN="$GH_TOKEN"

# Prefer autodetected repo from origin; fallback
REPO="${REPO:-$(git config --get remote.origin.url 2>/dev/null | sed -E 's#.*[:/](.+/.+)\.git#\1#')}"
REPO="${REPO:-titles-peeps/hushline}"

# Use native Ollama provider. No LiteLLM.
export OLLAMA_API_BASE="${OLLAMA_API_BASE:-http://127.0.0.1:11434}"
export OLLAMA_HOST="${OLLAMA_HOST:-http://127.0.0.1:11434}"
unset LITELLM_PROVIDER LITELLM_OLLAMA_BASE OPENAI_API_KEY ANTHROPIC_API_KEY

MODEL="${AIDER_MODEL:-ollama_chat/qwen2.5-coder:7b-instruct}"

# Minimal, steady Aider args
AIDER_ARGS=(
  --yes
  --no-gitignore
  --model "$MODEL"
  --edit-format udiff
  --timeout 120
  --no-stream
  --disable-playwright
  --map-refresh files
  --map-multiplier-no-files 0
  --map-tokens 512
  --max-chat-history-tokens 1024
)

# Ensure repo root
[[ -d .git ]] || { echo "must run in repo root"; exit 1; }

# Ensure prompt template exists
if [[ ! -f ops/agent_prompt.tmpl ]]; then
  cat > ops/agent_prompt.tmpl <<'TMPL'
You are the Hush Line code assistant. Work only in this repository.

Issue #: ${ISSUE_NUMBER}
Title: ${ISSUE_TITLE}

Task:
- Implement the requested change minimally.
- Prefer direct file edits when possible.
- Preserve public APIs and security posture (CSP, TOTP, Tor, crypto).
- Use repository conventions. No new services/env vars.

Output rules:
- Return unified diffs only (no prose).

Context:
${ISSUE_BODY}
TMPL
fi

# Git identity (safe default)
git config user.name  >/dev/null 2>&1 || git config user.name  "hushline-agent"
git config user.email >/dev/null 2>&1 || git config user.email "agent@users.noreply.github.com"

# --- Fetch issue & branch off default ---------------------------------------

ISSUE_TITLE="$(gh issue view "$ISSUE" -R "$REPO" --json title -q .title)"
ISSUE_BODY="$(gh issue view "$ISSUE" -R "$REPO" --json body  -q .body)"

DEFAULT_BRANCH="$(gh repo view "$REPO" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || true)"
[[ -z "$DEFAULT_BRANCH" ]] && DEFAULT_BRANCH="$(git remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p')"
[[ -z "$DEFAULT_BRANCH" ]] && DEFAULT_BRANCH="main"

git fetch origin --prune
BR="agent/issue-${ISSUE}-$(date +%Y%m%d-%H%M%S)"
git checkout -B "$BR" "origin/$DEFAULT_BRANCH"

# --- Build the system prompt -------------------------------------------------

export ISSUE_NUMBER="$ISSUE" ISSUE_TITLE ISSUE_BODY
envsubst < ops/agent_prompt.tmpl > /tmp/agent_prompt.txt

# Try to detect target file paths in the issue body (generic, multi-language)
TARGET_FILES=()
while IFS= read -r f; do
  [[ -f "$f" ]] && TARGET_FILES+=("$f")
done < <(
  printf '%s' "$ISSUE_BODY" |
  grep -Eo '([A-Za-z0-9._/-]+\.(py|js|ts|tsx|jsx|css|scss|sass|html|jinja2|sh|yml|yaml|toml|json|ini|cfg|md))' |
  sort -u
)

# --- Warmup Ollama model non-blocking ---------------------------------------

(
  model="$MODEL"
  model="${model#*/}"    # remove "ollama_chat/"
  model="${model#ollama/}"
  model="${model:-qwen2.5-coder:7b-instruct}"
  curl -fsS -X POST "$OLLAMA_API_BASE/api/pull" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"$model\"}" >/dev/null 2>&1 || true
) &

# --- Run Aider once (keep it simple) ----------------------------------------

run_aider() {
  if [[ ${#TARGET_FILES[@]} -gt 0 ]]; then
    timeout -k 10 360 aider "${AIDER_ARGS[@]}" \
      --message "$(cat /tmp/agent_prompt.txt)" "${TARGET_FILES[@]}" || true
  else
    timeout -k 10 360 aider "${AIDER_ARGS[@]}" \
      --message "$(cat /tmp/agent_prompt.txt)" || true
  fi
}

run_aider

# If no changes staged or working tree changes → bail with comment
if git diff --quiet && git diff --cached --quiet; then
  # If we detected specific files, mention them; else generic message
  if [[ ${#TARGET_FILES[@]} -gt 0 ]]; then
    gh issue comment "$ISSUE" -R "$REPO" -b "Agent attempted patch but produced no changes to: ${TARGET_FILES[*]}."
  else
    gh issue comment "$ISSUE" -R "$REPO" -b "Agent attempted patch but produced no changes."
  fi
  exit 0
fi

# --- Commit & push; open PR --------------------------------------------------

git add -A
git commit -m "Agent patch for #${ISSUE}: ${ISSUE_TITLE}" || true
git push -u origin "$BR"

EXISTING_PR="$(gh pr list -R "$REPO" --head "$BR" --json number -q '.[0].number')"
if [[ -z "$EXISTING_PR" ]]; then
  gh pr create -R "$REPO" \
    -t "Agent patch for #${ISSUE}: ${ISSUE_TITLE}" \
    -b "Automated patch for #${ISSUE}."
else
  gh pr comment -R "$REPO" "$EXISTING_PR" -b "Updated patch."
fi

gh issue comment "$ISSUE" -R "$REPO" \
  -b "Agent created/updated PR from branch \`$BR\`."
