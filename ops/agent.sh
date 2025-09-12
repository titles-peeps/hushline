#!/bin/bash
set -euo pipefail

ISSUE_NUMBER="$(jq -r .issue.number "$GITHUB_EVENT_PATH")"
ISSUE_TITLE="$(jq -r .issue.title "$GITHUB_EVENT_PATH")"
ISSUE_BODY="$(jq -r .issue.body "$GITHUB_EVENT_PATH")"

echo "Agent triggered for issue #${ISSUE_NUMBER}: $ISSUE_TITLE"

SYSTEM_PROMPT=""
USER_TEMPLATE=""
current_section=""

while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" =~ ^system: ]]; then
    current_section="system"; continue
  elif [[ "$line" =~ ^user: ]]; then
    current_section="user"; continue
  fi
  trimmed="${line#  }"
  if [[ "$current_section" == "system" ]]; then
    SYSTEM_PROMPT+="${trimmed}"$'\n'
  elif [[ "$current_section" == "user" ]]; then
    USER_TEMPLATE+="${trimmed}"$'\n'
  fi
done < ops/agent_prompt.yml

ph_title="\$ISSUE_TITLE"
ph_body="\$ISSUE_BODY"
USER_PROMPT="${USER_TEMPLATE//$ph_title/$ISSUE_TITLE}"
USER_PROMPT="${USER_PROMPT//$ph_body/$ISSUE_BODY}"

FINAL_PROMPT="${SYSTEM_PROMPT}\n${USER_PROMPT}"

MODEL_NAME="qwen2.5-coder:7b-instruct"
echo "Pulling LLM model ($MODEL_NAME) if not already present..."
ollama pull "$MODEL_NAME" || true

echo "Running LLM to generate code patch..."
ollama generate -m "$MODEL_NAME" -p "$FINAL_PROMPT" > patch.diff

sed -i.bak -e 's/^```diff//; s/^```//; s/```$//' patch.diff || true

if ! git apply --check patch.diff; then
  echo "❌ The proposed patch could not be applied cleanly. Exiting."
  exit 1
fi
git apply patch.diff
echo "✅ Patch applied to the working directory."

echo "Formatting code with black and isort..."
export PATH="$HOME/.local/bin:$PATH"
python3 -m pip install --user --no-cache-dir black isort >/dev/null 2>&1 || true
isort . && black .

BRANCH_NAME="agent-issue-${ISSUE_NUMBER}"
git config user.name "Hushline Agent Bot"
git config user.email "titles-peeps@users.noreply.github.com"
git checkout -b "$BRANCH_NAME"
git add -A
git commit -m "Fix(#${ISSUE_NUMBER}): $ISSUE_TITLE"

echo "Pushing branch '$BRANCH_NAME' to fork..."
git push "https://x-access-token:${AGENT_TOKEN}@github.com/titles-peeps/hushline.git" "$BRANCH_NAME"

PR_TITLE="Fix: $ISSUE_TITLE"
PR_BODY="Closes #${ISSUE_NUMBER} (automated AI PR)."

echo "Creating pull request on main repo..."
API_JSON=$(printf '%s' \
  "{\"head\":\"titles-peeps:${BRANCH_NAME}\",\"base\":\"main\"," \
  "\"title\":\"${PR_TITLE//\"/\\\"}\",\"body\":\"${PR_BODY//\"/\\\"}\"}")
RESPONSE=$(curl -s -X POST -H "Authorization: token ${AGENT_TOKEN}" \
           -H "Content-Type: application/json" \
           -d "${API_JSON}" \
           "https://api.github.com/repos/scidsg/hushline/pulls")

PR_URL=$(echo "$RESPONSE" | jq -r .html_url 2>/dev/null || echo "")
if [[ -n "$PR_URL" && "$PR_URL" != "null" ]]; then
  echo "✅ Pull request created: $PR_URL"
else
  echo "❌ Failed to create pull request. Response: $RESPONSE"
  exit 1
fi
