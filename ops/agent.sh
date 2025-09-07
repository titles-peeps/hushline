#!/usr/bin/env bash
set -euo pipefail
set -x

# usage: ops/agent.sh <issue_number>
if [[ $# -ne 1 ]]; then
  echo "usage: ops/agent.sh <issue_number>" >&2
  exit 2
fi

ISSUE="$1"

# --- Minimal config -----------------------------------------------------------

# GitHub token (required by gh). Accept both GH_TOKEN or GITHUB_TOKEN.
: "${GH_TOKEN:=${GITHUB_TOKEN:-}}"
: "${GH_TOKEN:?GH_TOKEN (or GITHUB_TOKEN) must be set}"
export GITHUB_TOKEN="$GH_TOKEN"

# Detect repo "owner/name" from origin, allow override via REPO env, fallback.
if [[ -z "${REPO:-}" ]]; then
  # Works for both SSH and HTTPS remotes
  origin="$(git remote get-url origin 2>/dev/null || true)"
  if [[ "$origin" =~ github.com[:/]+([^/]+)/([^/.]+)(\.git)?$ ]]; then
    REPO="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  else
    REPO="titles-peeps/hushline"
  fi
fi

# Use native Ollama provider in Aider; avoid LiteLLM entirely.
unset LITELLM_PROVIDER LITELLM_OLLAMA_BASE OPENAI_API_KEY ANTHROPIC_API_KEY
export OLLAMA_API_BASE="${OLLAMA_API_BASE:-http://127.0.0.1:11434}"
export OLLAMA_HOST="${OLLAMA_HOST:-http://127.0.0.1:11434}"

# Model shortcut (Aider understands this provider alias)
MODEL="${AIDER_MODEL:-ollama_chat/qwen2.5-coder:7b-instruct}"

# Keep Aider simple & predictable on small boxes
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

# --- Preconditions ------------------------------------------------------------

# Must run at repo root with template
[[ -d .git ]] || { echo "must run in repo root"; exit 1; }
[[ -f ops/agent_prompt.tmpl ]] || { echo "missing ops/agent_prompt.tmpl"; exit 1; }

# Minimal deps
for bin in gh git aider curl jq; do
  command -v "$bin" >/dev/null || { echo "missing dependency: $bin"; exit 1; }
done

# Git identity (don’t fail if already set)
git config user.name  >/dev/null 2>&1 || git config user.name  "hushline-agent"
git config user.email >/dev/null 2>&1 || git config user.email "agent@users.noreply.github.com"

# Quick Ollama health; ensure model present (best-effort)
set +e
curl -fsS "$OLLAMA_API_BASE/api/tags" | jq -e .models >/dev/null
if [[ $? -ne 0 ]]; then
  echo "ollama not healthy at $OLLAMA_API_BASE"
  exit 1
fi
# pull model name without the "ollama_chat/" prefix
plain="${MODEL#ollama_chat/}"
curl -fsS "$OLLAMA_API_BASE/api/tags" | jq -e --arg m "$plain" '.models[].name | contains($m)' >/dev/null || \
  curl -fsS "$OLLAMA_API_BASE/api/pull" -H 'Content-Type: application/json' -d "{\"model\":\"${plain}\"}" >/dev/null
set -e

# --- Issue & branch -----------------------------------------------------------

ISSUE_TITLE="$(gh issue view "$ISSUE" -R "$REPO" --json title -q .title)"
ISSUE_BODY="$(gh issue view "$ISSUE" -R "$REPO" --json body  -q .body)"

DEFAULT_BRANCH="$(gh repo view "$REPO" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || true)"
[[ -z "$DEFAULT_BRANCH" ]] && DEFAULT_BRANCH="$(git remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p' || true)"
[[ -z "$DEFAULT_BRANCH" ]] && DEFAULT_BRANCH="main"

BR="agent/issue-${ISSUE}-$(date +%Y%m%d-%H%M%S)"
git fetch origin --prune
git checkout -B "$BR" "origin/$DEFAULT_BRANCH"

# Build the prompt from template
export ISSUE_NUMBER="$ISSUE" ISSUE_TITLE ISSUE_BODY
envsubst < ops/agent_prompt.tmpl > /tmp/agent_prompt.txt

# Optionally pass files mentioned in the issue (very generic, but safe)
TARGET_FILES=()
while IFS= read -r f; do
  [[ -f "$f" ]] && TARGET_FILES+=("$f")
done < <(printf "%s\n" "$ISSUE_BODY" | grep -Eo '([A-Za-z0-9._/-]+\.[A-Za-z0-9]+)' | sort -u)

# --- Single aider pass --------------------------------------------------------

if [[ ${#TARGET_FILES[@]} -gt 0 ]]; then
  timeout -k 10 420 aider "${AIDER_ARGS[@]}" --message "$(cat /tmp/agent_prompt.txt)" "${TARGET_FILES[@]}" || true
else
  timeout -k 10 420 aider "${AIDER_ARGS[@]}" --message "$(cat /tmp/agent_prompt.txt)" || true
fi

# --- Create PR or report no-op -----------------------------------------------

# If nothing changed at all, comment & exit cleanly
if git diff --quiet && git diff --cached --quiet; then
  # If user specified files, check those specifically to be extra clear
  if [[ ${#TARGET_FILES[@]} -gt 0 ]]; then
    gh issue comment "$ISSUE" -R "$REPO" -b "Agent attempted patch but produced no changes to: ${TARGET_FILES[*]}."
  else
    gh issue comment "$ISSUE" -R "$REPO" -b "Agent attempted patch but no changes were made."
  fi
  exit 0
fi

git add -A
git commit -m "Agent patch for #${ISSUE}: ${ISSUE_TITLE}" || true
git push -u origin "$BR"

EXISTING_PR="$(gh pr list -R "$REPO" --head "$BR" --json number -q '.[0].number')"
if [[ -z "$EXISTING_PR" ]]; then
  gh pr create -R "$REPO" -t "Agent patch for #${ISSUE}: ${ISSUE_TITLE}" -b "Automated patch for #${ISSUE}."
else
  gh pr comment -R "$REPO" "$EXISTING_PR" -b "Updated patch."
fi

gh issue comment "$ISSUE" -R "$REPO" -b "Agent created/updated PR from branch \`$BR\`."
