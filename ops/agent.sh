#!/bin/bash
set -euo pipefail

# Inputs from GitHub Actions
: "${GITHUB_EVENT_PATH:?missing GITHUB_EVENT_PATH}"
: "${AGENT_TOKEN:?missing AGENT_TOKEN}"
: "${GITHUB_REPOSITORY:?missing GITHUB_REPOSITORY}"   # e.g. scidsg/hushline
GITHUB_API_URL_DEFAULT="https://api.github.com"
GITHUB_API="${GITHUB_API_URL:-$GITHUB_API_URL_DEFAULT}"

ISSUE_NUMBER="$(jq -r .issue.number "$GITHUB_EVENT_PATH")"
ISSUE_TITLE="$(jq -r .issue.title "$GITHUB_EVENT_PATH")"
ISSUE_BODY="$(jq -r .issue.body  "$GITHUB_EVENT_PATH")"

echo "Agent for issue #${ISSUE_NUMBER}: ${ISSUE_TITLE}"

# Build prompt from YAML
SYSTEM_PROMPT=""
USER_TEMPLATE=""
section=""
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" =~ ^system: ]]; then section="system"; continue
  elif [[ "$line" =~ ^user: ]]; then section="user"; continue; fi
  trimmed="${line#  }"
  if [[ "$section" == "system" ]]; then SYSTEM_PROMPT+="${trimmed}"$'\n'
  elif [[ "$section" == "user"   ]]; then USER_TEMPLATE+="${trimmed}"$'\n'
  fi
done < ops/agent_prompt.yml

USER_PROMPT="${USER_TEMPLATE//\$ISSUE_TITLE/$ISSUE_TITLE}"
USER_PROMPT="${USER_PROMPT//\$ISSUE_BODY/$ISSUE_BODY}"

MODEL_NAME="qwen2.5-coder:7b-instruct"

# Ensure Ollama is up; if not, comment and exit 0
if ! curl -fsS http://127.0.0.1:11434/api/tags >/dev/null; then
  curl -fsS -X POST \
    -H "Authorization: token ${AGENT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg body ":warning: Agent could not reach local Ollama (127.0.0.1:11434)." '{body:$body}')" \
    "${GITHUB_API}/repos/${GITHUB_REPOSITORY}/issues/${ISSUE_NUMBER}/comments" >/dev/null || true
  exit 0
fi

# Pull model if needed (non-fatal if already present)
ollama pull "$MODEL_NAME" || true

# Call Ollama chat API (expect raw unified diff or NO_CHANGES)
REQUEST_JSON=$(jq -n \
  --arg model "$MODEL_NAME" \
  --arg sys "$SYSTEM_PROMPT" \
  --arg usr "$USER_PROMPT" \
  --argjson opts '{"temperature":0,"num_ctx":8192}' \
  '{model:$model,stream:false,options:$opts,
    messages:[{role:"system",content:$sys},{role:"user",content:$usr}]}')

RAW_RESPONSE="$(curl -fsS -X POST http://127.0.0.1:11434/api/chat \
  -H 'Content-Type: application/json' \
  -d "$REQUEST_JSON" \
  | jq -r '.message.content // .response // ""')"

# Sanitize to printable text
RESP="$(printf '%s' "$RAW_RESPONSE" | tr -cd '\11\12\15\40-\176')"

# Quick accept: NO_CHANGES -> comment and exit green
if printf '%s' "$RESP" | grep -qx 'NO_CHANGES'; then
  curl -fsS -X POST \
    -H "Authorization: token ${AGENT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg b "Agent: no change needed (NO_CHANGES)." '{body:$b}')" \
    "${GITHUB_API}/repos/${GITHUB_REPOSITORY}/issues/${ISSUE_NUMBER}/comments" >/dev/null || true
  exit 0
fi

# Extract unified diff
# Accept either raw unified diff or a single ```diff fenced block
if printf '%s' "$RESP" | grep -q '^```diff'; then
  awk '/^```diff/{f=1;next} /^```$/{f=0} f' <<<"$RESP" > patch.body || true
else
  printf '%s' "$RESP" > patch.body
fi

# Keep from first "diff --git"
awk '/^diff --git /{p=1} p' patch.body > patch.diff || true

if ! [[ -s patch.diff ]] || ! grep -q '^diff --git ' patch.diff; then
  # Comment diagnostic and exit green
  head_preview="$(printf '%s' "$RESP" | sed -n '1,60p')"
  curl -fsS -X POST \
    -H "Authorization: token ${AGENT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg b "Agent output did not contain a usable unified diff. First lines:\n\n\`\`\`\n$head_preview\n\`\`\`" '{body:$b}')" \
    "${GITHUB_API}/repos/${GITHUB_REPOSITORY}/issues/${ISSUE_NUMBER}/comments" >/dev/null || true
  exit 0
fi

# Try to apply the patch with fallbacks
apply_ok=0
if git apply --check patch.diff 2>/dev/null; then
  git apply patch.diff; apply_ok=1
elif git apply --check --whitespace=fix patch.diff 2>/dev/null; then
  git apply --whitespace=fix patch.diff; apply_ok=1
elif git apply --check --3way patch.diff 2>/dev/null; then
  git apply --3way patch.diff; apply_ok=1
fi

if [[ "$apply_ok" != "1" ]]; then
  fail_preview="$(sed -n '1,80p' patch.diff)"
  curl -fsS -X POST \
    -H "Authorization: token ${AGENT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg b "Agent produced a diff but it did not apply cleanly.\n\nFirst lines:\n\`\`\`diff\n$fail_preview\n\`\`\`" '{body:$b}')" \
    "${GITHUB_API}/repos/${GITHUB_REPOSITORY}/issues/${ISSUE_NUMBER}/comments" >/dev/null || true
  exit 0
fi

# Optional formatting (best-effort, silent)
export PATH="$HOME/.local/bin:$PATH"
python3 -m pip install --user --no-cache-dir black isort >/dev/null 2>&1 || true
command -v isort >/dev/null 2>&1 && isort . >/dev/null 2>&1 || true
command -v black  >/dev/null 2>&1 && black .  >/dev/null 2>&1 || true

# Commit, push, open PR
BRANCH_NAME="agent-issue-${ISSUE_NUMBER}"
git config user.name "Hushline Agent Bot"
git config user.email "titles-peeps@users.noreply.github.com"
git checkout -b "$BRANCH_NAME"

git add -A
if git diff --cached --quiet; then
  curl -fsS -X POST \
    -H "Authorization: token ${AGENT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg b "Agent patch applied but no staged changes were detected; nothing to commit." '{body:$b}')" \
    "${GITHUB_API}/repos/${GITHUB_REPOSITORY}/issues/${ISSUE_NUMBER}/comments" >/dev/null || true
  exit 0
fi

git commit -m "Fix(#${ISSUE_NUMBER}): ${ISSUE_TITLE}"
git push "https://x-access-token:${AGENT_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" "$BRANCH_NAME"

PR_TITLE="Fix: ${ISSUE_TITLE}"
PR_BODY="Closes #${ISSUE_NUMBER}."
API_JSON=$(jq -n --arg head "$BRANCH_NAME" --arg base "main" --arg title "$PR_TITLE" --arg body "$PR_BODY" \
  '{head:$head, base:$base, title:$title, body:$body}')

RESPONSE=$(curl -fsS -X POST \
  -H "Authorization: token ${AGENT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$API_JSON" \
  "${GITHUB_API}/repos/${GITHUB_REPOSITORY}/pulls")

PR_URL=$(echo "$RESPONSE" | jq -r .html_url 2>/dev/null || echo "")
if [[ -n "$PR_URL" && "$PR_URL" != "null" ]]; then
  curl -fsS -X POST \
    -H "Authorization: token ${AGENT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg b "Opened PR: $PR_URL" '{body:$b}')" \
    "${GITHUB_API}/repos/${GITHUB_REPOSITORY}/issues/${ISSUE_NUMBER}/comments" >/dev/null || true
  echo "PR: $PR_URL"
else
  curl -fsS -X POST \
    -H "Authorization: token ${AGENT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg b "Failed to open PR. API response:\n\`\`\`\n$RESPONSE\n\`\`\`" '{body:$b}')" \
    "${GITHUB_API}/repos/${GITHUB_REPOSITORY}/issues/${ISSUE_NUMBER}/comments" >/dev/null || true
fi
