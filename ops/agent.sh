#!/usr/bin/env bash
set -euo pipefail

# usage: ops/agent.sh <issue_number>
[[ $# -eq 1 ]] || { echo "usage: ops/agent.sh <issue_number>" >&2; exit 2; }
ISSUE="$1"

: "${GH_TOKEN:?GH_TOKEN must be set}"
export GITHUB_TOKEN="$GH_TOKEN"

# Use native Ollama model (avoid litellm paths)
MODEL="${AIDER_MODEL:-ollama:qwen2.5-coder:7b-instruct}"
export OLLAMA_API_BASE="${OLLAMA_API_BASE:-http://127.0.0.1:11434}"

# Repo autodetect; fallback
REPO="${REPO:-$(git config --get remote.origin.url 2>/dev/null | sed -E 's#.*[:/](.+/.+)\.git#\1#')}"
REPO="${REPO:-titles-peeps/hushline}"

# Minimal git identity
git config user.name  >/dev/null 2>&1 || git config user.name  "hushline-agent"
git config user.email >/dev/null 2>&1 || git config user.email "agent@users.noreply.github.com"

# Fetch issue text
ISSUE_TITLE="$(gh issue view "$ISSUE" -R "$REPO" --json title -q .title)"
ISSUE_BODY="$(gh issue view "$ISSUE" -R "$REPO" --json body  -q .body)"

# Default branch
DEFAULT_BRANCH="$(gh repo view "$REPO" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || true)"
[[ -z "$DEFAULT_BRANCH" ]] && DEFAULT_BRANCH="main"

# Create working branch
git fetch origin --prune
BR="agent/issue-${ISSUE}-$(date +%Y%m%d-%H%M%S)"
git checkout -B "$BR" "origin/$DEFAULT_BRANCH"

# Prepare a tiny prompt
cat > /tmp/agent_prompt.txt <<'TXT'
You are the Hush Line code assistant. Work only in this repository.

Do exactly what the issue requests with the smallest possible change.
Return unified diffs only (no prose).

Issue:
TXT
{
  printf 'Title: %s\n\n' "$ISSUE_TITLE"
  printf '%s\n' "$ISSUE_BODY"
} >> /tmp/agent_prompt.txt

# Run Aider once; keep it short and synchronous
timeout -k 10 300 aider \
  --yes \
  --no-gitignore \
  --model "$MODEL" \
  --edit-format udiff \
  --no-stream \
  --timeout 120 \
  --message "$(cat /tmp/agent_prompt.txt)" || true

# If nothing changed, comment and exit
if git diff --quiet && git diff --cached --quiet; then
  gh issue comment "$ISSUE" -R "$REPO" -b "Agent ran; no changes produced."
  exit 0
fi

# Commit & push
git add -A
git commit -m "Agent patch for #${ISSUE}: ${ISSUE_TITLE}" || true
git push -u origin "$BR"

# Open PR (or update)
PR="$(gh pr list -R "$REPO" --head "$BR" --json number -q '.[0].number')"
if [[ -z "$PR" ]]; then
  gh pr create -R "$REPO" -t "Agent patch for #${ISSUE}: ${ISSUE_TITLE}" -b "Automated patch for #${ISSUE}."
else
  gh pr comment -R "$REPO" "$PR" -b "Updated patch."
fi

gh issue comment "$ISSUE" -R "$REPO" -b "Agent opened PR from branch \`$BR\`."
