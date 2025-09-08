#!/usr/bin/env bash
set -euo pipefail

# --- required env (names unchanged) ---
: "${GH_TOKEN:?GH_TOKEN is required}"
export GITHUB_TOKEN="$GH_TOKEN"

# Explicit Ollama + LiteLLM wiring so Aider never guesses
export OLLAMA_API_BASE="${OLLAMA_API_BASE:-http://127.0.0.1:11434}"
export LITELLM_PROVIDER="${LITELLM_PROVIDER:-ollama}"

# Model naming Aider/LiteLLM expects for POST /api/chat
MODEL="${AIDER_MODEL:-ollama_chat/qwen2.5-coder:7b-instruct}"

ISSUE_NUM="${1:?usage: ops/agent.sh <issue_number>}"

# Ensure tools
for b in gh git aider; do
  command -v "$b" >/dev/null || { echo "missing: $b"; exit 1; }
done

# Detect repo from git remote; fallback
REPO="${REPO:-$(git remote get-url origin 2>/dev/null \
  | sed -n 's#.*github.com[:/]\(.*\.git\)#\1#p' \
  | sed 's/\.git$//')}"
REPO="${REPO:-titles-peeps/hushline}"

# Fetch issue data (preserve newlines)
ISSUE_TITLE="$(gh issue view "$ISSUE_NUM" -R "$REPO" --json title -q .title)"
ISSUE_BODY="$(gh issue view "$ISSUE_NUM" -R "$REPO" --json body  -q .body)"

# Default branch
DEFAULT_BRANCH="$(gh repo view "$REPO" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || true)"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-$(git remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p')}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"

# Create a working branch from default
BR="agent/issue-${ISSUE_NUM}-$(date +%Y%m%d-%H%M%S)"
git fetch origin --prune
git checkout -B "$BR" "origin/$DEFAULT_BRANCH"

# Minimal prompt
: > /tmp/agent_prompt.txt
envsubst < ops/agent_prompt.tmpl > /tmp/agent_prompt.txt

# Try to hint Aider with any file paths mentioned in the issue body (generic)
mapfile -t TARGET_FILES < <(
  printf '%s\n' "$ISSUE_BODY" |
  grep -Eo '([A-Za-z0-9._/-]+\.(py|js|ts|tsx|jsx|css|scss|html|jinja2|yml|yaml|sh|toml|json))' |
  sort -u |
  while read -r f; do [[ -f "$f" ]] && echo "$f"; done
)

# Aider args - force the base to Ollama explicitly so LiteLLM knows where to go
AIDER_ARGS=(
  --yes
  --no-gitignore
  --model "$MODEL"
  --edit-format udiff
  --timeout 90
  --no-stream
  --openai-api-base "$OLLAMA_API_BASE"
  --map-refresh files
  --map-multiplier-no-files 0
  --map-tokens 256
  --max-chat-history-tokens 768
  --disable-playwright
)

# Single pass; lower CPU/IO priority to reduce crash risk
if [[ ${#TARGET_FILES[@]} -gt 0 ]]; then
  nice -n 10 ionice -c2 -n7 aider "${AIDER_ARGS[@]}" \
    --message "$(cat /tmp/agent_prompt.txt)" "${TARGET_FILES[@]}" || true
else
  nice -n 10 ionice -c2 -n7 aider "${AIDER_ARGS[@]}" \
    --message "$(cat /tmp/agent_prompt.txt)" || true
fi

# If nothing changed, note & exit quietly
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
