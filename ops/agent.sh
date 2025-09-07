#!/usr/bin/env bash
set -euo pipefail

# --- required env (names unchanged) ---
: "${GH_TOKEN:?GH_TOKEN is required}"
export GITHUB_TOKEN="$GH_TOKEN"

# --- force native Ollama (never LiteLLM) ---
unset LITELLM_PROVIDER LITELLM_OLLAMA_BASE OPENAI_API_KEY ANTHROPIC_API_KEY
export OLLAMA_API_BASE="${OLLAMA_API_BASE:-http://127.0.0.1:11434}"
export OLLAMA_HOST="${OLLAMA_HOST:-$OLLAMA_API_BASE}"

# Model: accept env, but rewrite colon form to slash form defensively
MODEL="${AIDER_MODEL:-ollama_chat/qwen2.5-coder:7b-instruct}"
MODEL="${MODEL/ollama:/ollama_chat/}"

# Args
ISSUE_NUM="${1:?usage: ops/agent.sh <issue_number>}"

# Detect repo from git remote; fallback to titles-peeps/hushline
REPO="${REPO:-$(git remote get-url origin 2>/dev/null \
       | sed -n 's#.*github.com[:/]\(.*\.git\)#\1#p' \
       | sed 's/\.git$//')}"
REPO="${REPO:-titles-peeps/hushline}"

# Ensure tools
for b in gh git aider curl jq; do
  command -v "$b" >/dev/null || { echo "missing: $b"; exit 1; }
done

# Quick Ollama health
if ! curl -fsS "$OLLAMA_API_BASE/api/tags" >/dev/null; then
  echo "Ollama not reachable at $OLLAMA_API_BASE"; exit 1
fi

# Fetch issue data (preserve newlines)
ISSUE_TITLE="$(gh issue view "$ISSUE_NUM" -R "$REPO" --json title -q .title)"
ISSUE_BODY="$(gh issue view "$ISSUE_NUM" -R "$REPO" --json body  -q .body)"

# Determine default branch
DEFAULT_BRANCH="$(gh repo view "$REPO" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || true)"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-$(git remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p')}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"

# Create working branch
BR="agent/issue-${ISSUE_NUM}-$(date +%Y%m%d-%H%M%S)"
git fetch origin --prune
git checkout -B "$BR" "origin/$DEFAULT_BRANCH"

# Minimal prompt
cat > /tmp/agent_prompt.txt <<EOF
You are the Hush Line code assistant. Work only in this repository.

Issue #: ${ISSUE_NUM}
Title: ${ISSUE_TITLE}

Task:
- Make the smallest necessary change to implement the issue.
- Follow repo conventions; no new services/env vars.
- Output unified diffs only (no prose).

Context:
${ISSUE_BODY}
EOF

# Hint Aider with any paths mentioned (generic; no language special-casing)
mapfile -t TARGET_FILES < <(printf '%s\n' "$ISSUE_BODY" \
  | grep -Eo '([A-Za-z0-9._/-]+\.[A-Za-z0-9]+)' \
  | sort -u \
  | while read -r f; do [[ -f "$f" ]] && echo "$f"; done)

AIDER_ARGS=(
  --yes
  --no-gitignore
  --model "$MODEL"
  --edit-format udiff
  --timeout 90
  --no-stream
  --map-refresh files
  --map-multiplier-no-files 0
  --map-tokens 256
  --max-chat-history-tokens 768
  --no-show-model-warnings
)

# Run aider (single pass)
if [[ ${#TARGET_FILES[@]} -gt 0 ]]; then
  aider "${AIDER_ARGS[@]}" --message "$(cat /tmp/agent_prompt.txt)" "${TARGET_FILES[@]}" || true
else
  aider "${AIDER_ARGS[@]}" --message "$(cat /tmp/agent_prompt.txt)" || true
fi

# If nothing changed, just note it and exit cleanly
if git diff --quiet && git diff --cached --quiet; then
  gh issue comment "$ISSUE_NUM" -R "$REPO" -b "Agent attempted patch but produced no changes."
  exit 0
fi

# Commit, push, PR
git add -A
git commit -m "Agent patch for #${ISSUE_NUM}: ${ISSUE_TITLE}" || true
git push -u origin "$BR"

PR_NUM="$(gh pr list -R "$REPO" --head "$BR" --json number -q '.[0].number' || true)"
if [[ -z "$PR_NUM" ]]; then
  gh pr create -R "$REPO" -t "Agent patch for #${ISSUE_NUM}: ${ISSUE_TITLE}" -b "Automated patch for #${ISSUE_NUM}."
else
  gh pr comment -R "$REPO" "$PR_NUM" -b "Updated patch."
fi

gh issue comment "$ISSUE_NUM" -R "$REPO" -b "Agent created/updated PR from branch \`$BR\`."
