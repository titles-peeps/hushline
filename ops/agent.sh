#!/usr/bin/env bash
set -euo pipefail

# === Required env (names unchanged) ===
: "${GH_TOKEN:?GH_TOKEN is required}"
export GITHUB_TOKEN="$GH_TOKEN"

# Force Aider to use native Ollama adapter (NOT LiteLLM)
MODEL="${AIDER_MODEL:-ollama_chat/qwen2.5-coder:7b-instruct}"
export OLLAMA_API_BASE="${OLLAMA_API_BASE:-http://127.0.0.1:11434}"

# Make sure LiteLLM cannot hijack calls
unset LITELLM_PROVIDER LITELLM_OLLAMA_BASE OPENAI_API_KEY ANTHROPIC_API_KEY MISTRAL_API_KEY TOGETHER_API_KEY

# --- Args ---
ISSUE_NUM="${1:?usage: ops/agent.sh <issue_number>}"

# --- Tools ---
for b in gh git aider; do
  command -v "$b" >/dev/null || { echo "missing: $b"; exit 1; }
done

# --- Repo detect (fallback kept as requested) ---
REPO="${REPO:-$(git remote get-url origin 2>/dev/null | sed -n 's#.*github.com[:/]\(.*\)#\1#p' | sed 's/\.git$//')}"
REPO="${REPO:-titles-peeps/hushline}"

# --- Fetch issue ---
ISSUE_TITLE="$(gh issue view "$ISSUE_NUM" -R "$REPO" --json title -q .title)"
ISSUE_BODY="$(gh issue view "$ISSUE_NUM" -R "$REPO" --json body  -q .body)"

# --- Default branch ---
DEFAULT_BRANCH="$(gh repo view "$REPO" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || true)"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-$(git remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p')}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"

# --- Branch ---
BR="agent/issue-${ISSUE_NUM}-$(date +%Y%m%d-%H%M%S)"
git fetch origin --prune
git checkout -B "$BR" "origin/$DEFAULT_BRANCH"

# --- Prompt (inline template) ---
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

# --- Try to hint files (generic; no css special-casing) ---
mapfile -t TARGET_FILES < <(
  printf '%s\n' "$ISSUE_BODY" |
  grep -Eo '([A-Za-z0-9._/-]+\.(py|js|ts|tsx|jsx|css|scss|html|jinja2|yml|yaml|sh))' |
  sort -u |
  while read -r f; do [[ -f "$f" ]] && echo "$f"; done
)

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
)

# --- Run Aider once ---
if [[ ${#TARGET_FILES[@]} -gt 0 ]]; then
  aider "${AIDER_ARGS[@]}" --message "$(cat /tmp/agent_prompt.txt)" "${TARGET_FILES[@]}" || true
else
  aider "${AIDER_ARGS[@]}" --message "$(cat /tmp/agent_prompt.txt)" || true
fi

# --- If no changes, comment and exit ---
if git diff --quiet && git diff --cached --quiet; then
  gh issue comment "$ISSUE_NUM" -R "$REPO" -b "Agent attempted patch but produced no changes."
  exit 0
fi

# --- Commit, push, PR ---
git add -A
git commit -m "Agent patch for #${ISSUE_NUM}: ${ISSUE_TITLE}" || true
git push -u origin "$BR"

PR_NUM="$(gh pr list -R "$REPO" --head "$BR" --json number -q '.[0].number' || true)"
if [[ -z "$PR_NUM" ]]; then
  gh pr create -R "$REPO" \
    -t "Agent patch for #${ISSUE_NUM}: ${ISSUE_TITLE}" \
    -b "Automated patch for #${ISSUE_NUM}."
else
  gh pr comment -R "$REPO" "$PR_NUM" -b "Updated patch."
fi

gh issue comment "$ISSUE_NUM" -R "$REPO" -b "Agent created/updated PR from branch \`$BR\`."
