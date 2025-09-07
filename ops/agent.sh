#!/usr/bin/env bash
set -euo pipefail

# usage: ops/agent.sh <issue_number>
if [[ $# -ne 1 ]]; then
  echo "usage: ops/agent.sh <issue_number>" >&2
  exit 2
fi

ISSUE="$1"

# --- config (minimal) ---
REPO="${REPO:-$(git remote get-url origin 2>/dev/null | sed -nE 's#.*/([^/]+/[^/.]+)(\.git)?$#\1#p')}"
REPO="${REPO:-titles-peeps/hushline}"

# Required: GH_TOKEN must be provided by workflow secrets
: "${GH_TOKEN:?GH_TOKEN is required}"
export GITHUB_TOKEN="$GH_TOKEN"

# Aider+Ollama
export OLLAMA_API_BASE="${OLLAMA_API_BASE:-http://127.0.0.1:11434}"
AIDER_MODEL="${AIDER_MODEL:-ollama_chat/qwen2.5-coder:7b-instruct}"

# Make Aider as gentle as possible
AIDER_ARGS=(
  --yes
  --no-gitignore
  --model "$AIDER_MODEL"
  --edit-format udiff
  --timeout 60
  --no-stream
  --map-refresh files
  --map-multiplier-no-files 0
  --map-tokens 256
  --max-chat-history-tokens 512
  --disable-playwright
)

# --- ensure we’re in a repo root ---
[[ -d .git ]] || { echo "run from repo root"; exit 1; }
[[ -f ops/agent_prompt.tmpl ]] || { echo "missing ops/agent_prompt.tmpl"; exit 1; }

# --- light Ollama warmup (don’t hang if down) ---
curl -fsS "$OLLAMA_API_BASE/api/tags" >/dev/null || true

# --- fetch issue data (preserve newlines) ---
ISSUE_TITLE="$(gh issue view "$ISSUE" -R "$REPO" --json title -q .title)"
ISSUE_BODY="$(gh issue view "$ISSUE" -R "$REPO" --json body  -q .body)"

# --- base branch & working branch ---
DEFAULT_BRANCH="$(gh repo view "$REPO" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || true)"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-$(git remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p')}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"

BR="agent/issue-${ISSUE}-$(date +%Y%m%d-%H%M%S)"
git fetch origin --prune
git checkout -B "$BR" "origin/$DEFAULT_BRANCH"

# --- build prompt for the LLM ---
export ISSUE_NUMBER="$ISSUE" ISSUE_TITLE ISSUE_BODY
envsubst < ops/agent_prompt.tmpl > /tmp/agent_prompt.txt

# If the issue mentions paths, pass those files to Aider (keeps repo-map small)
TARGET_FILES=()
while IFS= read -r f; do
  [[ -f "$f" ]] && TARGET_FILES+=("$f")
done < <(printf '%s\n' "$ISSUE_BODY" | grep -Eo '([A-Za-z0-9._/-]+\.(py|js|ts|tsx|jsx|css|scss|sass|html|jinja2|yml|yaml|toml|json|md|sh))' | sort -u)

# --- run LLM edit once (LLM is the only mechanism; no fallbacks) ---
if [[ ${#TARGET_FILES[@]} -gt 0 ]]; then
  timeout -k 5 180 aider "${AIDER_ARGS[@]}" --message "$(cat /tmp/agent_prompt.txt)" "${TARGET_FILES[@]}" || true
else
  timeout -k 5 180 aider "${AIDER_ARGS[@]}" --message "$(cat /tmp/agent_prompt.txt)" || true
fi

# --- if nothing changed, post a comment and exit ---
if git diff --quiet && git diff --cached --quiet; then
  gh issue comment "$ISSUE" -R "$REPO" -b "Agent ran the LLM but produced no changes."
  exit 0
fi

# --- commit/push/PR (no tests/linters here) ---
git add -A
git -c user.name="hushline-agent" -c user.email="agent@users.noreply.github.com" \
  commit -m "Agent patch for #${ISSUE}: ${ISSUE_TITLE}"

git push -u origin "$BR"

EXISTING_PR="$(gh pr list -R "$REPO" --head "$BR" --json number -q '.[0].number')"
if [[ -z "$EXISTING_PR" ]]; then
  gh pr create -R "$REPO" \
    -t "Agent patch for #${ISSUE}: ${ISSUE_TITLE}" \
    -b "Automated patch for #${ISSUE}."
else
  gh pr comment -R "$REPO" "$EXISTING_PR" -b "Agent updated the patch."
fi

gh issue comment "$ISSUE" -R "$REPO" -b "Agent created/updated PR from branch \`$BR\`."
