#!/usr/bin/env bash
set -euo pipefail

# usage: ops/agent.sh <issue_number>
if [[ $# -ne 1 ]]; then
  echo "usage: ops/agent.sh <issue_number>" >&2
  exit 2
fi

ISSUE="$1"

# --- Minimal env & deps ---
: "${GH_TOKEN:?GH_TOKEN missing}"
export GITHUB_TOKEN="$GH_TOKEN"

# Point EVERYONE at the same Ollama endpoint:
export OLLAMA_API_BASE="${OLLAMA_API_BASE:-http://127.0.0.1:11434}"
export OLLAMA_HOST="${OLLAMA_HOST:-$OLLAMA_API_BASE}"
# LiteLLM expects this exact var name for Ollama
export LITELLM_OLLAMA_BASE="${LITELLM_OLLAMA_BASE:-$OLLAMA_API_BASE}"

# Model: the aider-native Ollama chat driver
AIDER_MODEL="${AIDER_MODEL:-ollama_chat/qwen2.5-coder:7b-instruct}"

for bin in gh git aider; do
  command -v "$bin" >/dev/null || { echo "missing dependency: $bin"; exit 1; }
done

# --- Repo & branch ---
REPO="$(git config --get remote.origin.url | sed -E 's#.*[:/](.+/.+)\.git#\1#')"
[[ -z "${REPO}" ]] && REPO="titles-peeps/hushline"

DEFAULT_BRANCH="$(gh repo view "$REPO" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || true)"
[[ -z "$DEFAULT_BRANCH" ]] && DEFAULT_BRANCH="main"

git fetch origin --prune
BR="agent/issue-${ISSUE}-$(date +%Y%m%d-%H%M%S)"
git checkout -B "$BR" "origin/${DEFAULT_BRANCH}"

# --- Tiny prompt ---
TITLE="$(gh issue view "$ISSUE" -R "$REPO" --json title -q .title)"
BODY="$(gh issue view "$ISSUE"  -R "$REPO" --json body  -q .body)"

cat > /tmp/agent_prompt.txt <<EOF
You are the Hush Line code assistant. Work only in this repository.

Task:
- Make the change requested in the referenced issue.
- Keep the diff minimal.
- Output unified diffs only (no prose).
- Edit only existing files.

Title: ${TITLE}

Body:
${BODY}
EOF

# Optional: pass any explicit file paths found in the issue body,
# so aider doesn't have to consider the whole tree.
mapfile -t TARGETS < <(printf "%s" "$BODY" | grep -Eo '([A-Za-z0-9._/-]+\.(py|js|ts|tsx|jsx|css|scss|html|jinja2|sh|yml|yaml))' | sort -u || true)
EXISTING_TARGETS=()
for f in "${TARGETS[@]:-}"; do
  [[ -f "$f" ]] && EXISTING_TARGETS+=("$f")
done

AIDER_ARGS=(
  --yes
  --no-gitignore
  --model "$AIDER_MODEL"
  --edit-format udiff
  --timeout 120
)

if (( ${#EXISTING_TARGETS[@]} > 0 )); then
  aider "${AIDER_ARGS[@]}" --message "$(cat /tmp/agent_prompt.txt)" "${EXISTING_TARGETS[@]}" || true
else
  aider "${AIDER_ARGS[@]}" --message "$(cat /tmp/agent_prompt.txt)" || true
fi

# If nothing changed, exit cleanly with a comment.
if git diff --quiet && git diff --cached --quiet; then
  gh issue comment "$ISSUE" -R "$REPO" -b "Agent attempted a patch but produced no changes."
  exit 0
fi

# Commit & PR
git add -A
git commit -m "Agent patch for #${ISSUE}: ${TITLE}" || true
git push -u origin "$BR"

EXISTING_PR="$(gh pr list -R "$REPO" --head "$BR" --json number -q '.[0].number')"
if [[ -z "$EXISTING_PR" ]]; then
  gh pr create -R "$REPO" -t "Agent patch for #${ISSUE}: ${TITLE}" -b "Automated patch for #${ISSUE}."
else
  gh pr comment -R "$REPO" "$EXISTING_PR" -b "Updated patch."
fi

gh issue comment "$ISSUE" -R "$REPO" -b "Agent created/updated PR from \`$BR\`."
