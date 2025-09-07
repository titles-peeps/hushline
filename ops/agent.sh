#!/usr/bin/env bash
set -euo pipefail

# usage: ops/agent.sh <issue_number>
if [[ $# -ne 1 ]]; then
  echo "usage: ops/agent.sh <issue_number>" >&2
  exit 2
fi

: "${GH_TOKEN:?GH_TOKEN is required}"
export GITHUB_TOKEN="$GH_TOKEN"

ISSUE="$1"

# Prefer repo from git remote; fallback to titles-peeps/hushline
REPO="${REPO:-$(git remote get-url origin 2>/dev/null | sed -nE 's#.*github.com[:/]+([^/]+/[^/.]+)(\.git)?$#\1#p')}"
REPO="${REPO:-titles-peeps/hushline}"

# Model/endpoint (native Ollama path; avoids LiteLLM)
export OLLAMA_API_BASE="${OLLAMA_API_BASE:-http://127.0.0.1:11434}"
MODEL="${AIDER_MODEL:-ollama_chat/qwen2.5-coder:7b-instruct}"

# Basic deps
for b in gh git aider; do
  command -v "$b" >/dev/null || { echo "Missing dependency: $b" >&2; exit 1; }
done

# Ensure repo root and prompt template
[[ -d .git ]] || { echo "Run from repo root"; exit 1; }
[[ -f ops/agent_prompt.tmpl ]] || {
  cat > ops/agent_prompt.tmpl <<'TPL'
You are the Hush Line code assistant. Work only in this repository.

Issue #: ${ISSUE_NUMBER}
Title: ${ISSUE_TITLE}

Task:
- If change is backend/auth/CSP/crypto-critical:
  * Add minimal pytest tests and implement the smallest fix.
- If change is styles/markup/static-only:
  * Implement directly (no tests required).
- Preserve public APIs and security posture (CSP, TOTP, Tor, crypto).
- Follow repo conventions (pytest, Black/isort). No new services/env vars.

Output rules:
- Return unified diffs only (no prose).

Context (issue body follows):
${ISSUE_BODY}
TPL
}

# Fetch issue details
ISSUE_TITLE="$(gh issue view "$ISSUE" -R "$REPO" --json title -q .title)"
ISSUE_BODY="$(gh issue view "$ISSUE" -R "$REPO" --json body  -q .body)"

# Default branch
DEFAULT_BRANCH="$(gh repo view "$REPO" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || true)"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-$(git remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p')}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"

# Create work branch
git fetch origin --prune
BR="agent/issue-${ISSUE}-$(date +%Y%m%d-%H%M%S)"
git checkout -B "$BR" "origin/${DEFAULT_BRANCH}"

# Build prompt
export ISSUE_NUMBER="$ISSUE" ISSUE_TITLE ISSUE_BODY
envsubst < ops/agent_prompt.tmpl > /tmp/agent_prompt.txt

# Try to extract explicit file paths from the issue body (generic)
TARGET_FILES=()
while IFS= read -r f; do
  [[ -f "$f" ]] && TARGET_FILES+=("$f")
done < <(echo "$ISSUE_BODY" | grep -Eo '([A-Za-z0-9._/-]+\.(py|js|ts|jsx|tsx|css|scss|sass|html|jinja2|sh|yml|yaml|toml|json))' | sort -u)

# Aider args (kept small & simple)
AIDER_ARGS=(
  --yes
  --no-gitignore
  --model "$MODEL"
  --edit-format udiff
  --timeout 90
  --no-stream
  --map-refresh files
  --map-multiplier-no-files 0
  --map-tokens 512
  --max-chat-history-tokens 1024
)

# Run aider (with target files when we have them)
if [[ ${#TARGET_FILES[@]} -gt 0 ]]; then
  aider "${AIDER_ARGS[@]}" --message "$(cat /tmp/agent_prompt.txt)" "${TARGET_FILES[@]}" || true
else
  aider "${AIDER_ARGS[@]}" --message "$(cat /tmp/agent_prompt.txt)" || true
fi

# If no changes, say so and exit cleanly
if git diff --quiet && git diff --cached --quiet; then
  gh issue comment "$ISSUE" -R "$REPO" -b "Agent attempted patch but produced no changes."
  exit 0
fi

# Commit & push
git add -A
git commit -m "Agent patch for #${ISSUE}: ${ISSUE_TITLE}" || true
git push -u origin "$BR"

# Create PR
EXISTING_PR="$(gh pr list -R "$REPO" --head "$BR" --json number -q '.[0].number')"
if [[ -z "$EXISTING_PR" ]]; then
  gh pr create -R "$REPO" \
    -t "Agent patch for #${ISSUE}: ${ISSUE_TITLE}" \
    -b "Automated patch for #${ISSUE}."
else
  gh pr comment -R "$REPO" "$EXISTING_PR" -b "Updated patch."
fi

# Link PR on the issue
gh issue comment "$ISSUE" -R "$REPO" -b "Agent created/updated PR from branch \`$BR\`."
