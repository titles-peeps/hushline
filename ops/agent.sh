# (paste the full script above)
#!/usr/bin/env bash
set -euo pipefail

ISSUE="${1:-}"
if [[ -z "$ISSUE" ]]; then
  echo "Usage: $0 <issue-number>"
  exit 1
fi

# Detect repo from origin remote
REPO="${REPO:-$(git remote get-url origin | sed -E 's#(git@|https://)github.com[:/](.+)\.git#\2#')}"
: "${REPO:=titles-peeps/hushline}"

# Environment setup
unset LITELLM_PROVIDER LITELLM_OLLAMA_BASE OPENAI_API_KEY ANTHROPIC_API_KEY
export OLLAMA_API_BASE="${OLLAMA_API_BASE:-http://127.0.0.1:11434}"
MODEL="ollama_chat/qwen2.5-coder:7b-instruct"

# Pre-flight Ollama health check
if ! curl -s --max-time 5 "$OLLAMA_API_BASE/api/version" >/dev/null; then
  echo "Ollama not reachable at $OLLAMA_API_BASE"
fi

# Ensure repo root
[[ -d .git ]] || { echo "must run in repo root"; exit 1; }

# Git identity
git config user.name  >/dev/null 2>&1 || git config user.name  "hushline-agent"
git config user.email >/dev/null 2>&1 || git config user.email "agent@users.noreply.github.com"

# Fetch issue
ISSUE_TITLE="$(gh issue view "$ISSUE" -R "$REPO" --json title -q '.title')"
ISSUE_BODY="$(gh issue view "$ISSUE" -R "$REPO" --json body  -q '.body')"

# Default branch
DEFAULT_BRANCH="$(gh repo view "$REPO" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || true)"
: "${DEFAULT_BRANCH:=main}"

# New branch
BR="agent/issue-${ISSUE}-$(date +%Y%m%d-%H%M%S)"
git fetch origin --prune
git checkout -B "$BR" "origin/$DEFAULT_BRANCH"

# Prompt for aider
cat > /tmp/agent_prompt.txt <<EOF
Issue #$ISSUE: $ISSUE_TITLE

$ISSUE_BODY
EOF

AIDER_ARGS=(
  --yes
  --no-gitignore
  --model "$MODEL"
  --edit-format udiff
  --timeout 480
  --no-stream
  --map-tokens 512
  --max-chat-history-tokens 1024
)

# Run aider
set +e
timeout -k 10 600 aider "${AIDER_ARGS[@]}" --message "$(cat /tmp/agent_prompt.txt)"
rc=$?
set -e

# Check changes
if git diff --quiet; then
  echo "No changes from aider, trying fallback"

  TARGET_FILES=$(grep -Eo '([A-Za-z0-9._/-]+\.(css|scss|py|ts|js|yml|yaml|html|sh))' <<<"$ISSUE_BODY" || true)
  OLD=$(echo "$ISSUE_BODY" | sed -n '/Problem:/,/Expected Outcome:/p' | sed -n 's/.*`$begin:math:text$.*$end:math:text$`.*/\1/p' | head -1)
  NEW=$(echo "$ISSUE_BODY" | sed -n '/Expected Outcome:/,/Path to file:/p' | sed -n 's/.*`$begin:math:text$.*$end:math:text$`.*/\1/p' | head -1)

  if [[ -n "$TARGET_FILES" && -n "$OLD" && -n "$NEW" ]]; then
    for f in $TARGET_FILES; do
      if [[ -f "$f" ]] && grep -qF "$OLD" "$f"; then
        sed -i "s|$OLD|$NEW|g" "$f"
        echo "Applied fallback patch in $f"
      fi
    done
  fi
fi

# Commit if changes exist
if ! git diff --quiet; then
  git add -u
  git commit -m "agent: resolve #$ISSUE – $ISSUE_TITLE"
  git push -u origin "$BR"

  if ! gh pr list -R "$REPO" --head "$BR" --json number -q '.[0].number' >/dev/null; then
    gh pr create -R "$REPO" --head "$BR" --base "$DEFAULT_BRANCH" --title "[Agent] $ISSUE_TITLE (#$ISSUE)" --body "Automated changes for issue #$ISSUE"
  else
    gh pr comment -R "$REPO" "$ISSUE" --body "Agent updated branch $BR for issue #$ISSUE"
  fi
else
  gh issue comment -R "$REPO" "$ISSUE" --body "Agent found no changes to make."
fi
