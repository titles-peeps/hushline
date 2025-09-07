#!/bin/bash
set -euo pipefail

# Debug logging (uncomment for verbose output)
# set -x

# 1. Extract issue details from GitHub event JSON
ISSUE_NUMBER="$(jq -r .issue.number "$GITHUB_EVENT_PATH")"
ISSUE_TITLE="$(jq -r .issue.title "$GITHUB_EVENT_PATH")"
ISSUE_BODY="$(jq -r .issue.body "$GITHUB_EVENT_PATH")"

echo "Agent triggered for issue #${ISSUE_NUMBER}: $ISSUE_TITLE"

# 2. Read prompt template and substitute issue details
SYSTEM_PROMPT=""
USER_TEMPLATE=""
current_section=""

while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" =~ ^system: ]]; then
    current_section="system"
    continue
  elif [[ "$line" =~ ^user: ]]; then
    current_section="user"
    continue
  fi

  # Remove leading two spaces from prompt lines (YAML indentation)
  trimmed="${line#  }"
  if [[ "$current_section" == "system" ]]; then
    SYSTEM_PROMPT+="${trimmed}"$'\n'
  elif [[ "$current_section" == "user" ]]; then
    USER_TEMPLATE+="${trimmed}"$'\n'
  fi
done < ops/agent_prompt.yml

# Substitute placeholders in user template with actual issue data
# (Ensure literal '$' in USER_TEMPLATE is preserved for substitution)
ph_title="\$ISSUE_TITLE"
ph_body="\$ISSUE_BODY"
USER_PROMPT="${USER_TEMPLATE//$ph_title/$ISSUE_TITLE}"
USER_PROMPT="${USER_PROMPT//$ph_body/$ISSUE_BODY}"

# Compose final prompt (system + user text)
FINAL_PROMPT="${SYSTEM_PROMPT}\n${USER_PROMPT}"

# 3. Ensure the model is available, then run the model to get a patch diff
MODEL_NAME="qwen2.5-coder:7b-instruct"
echo "Pulling LLM model ($MODEL_NAME) if not already present..."
ollama pull "$MODEL_NAME" || true

echo "Running LLM to generate code patch..."
ollama generate -m "$MODEL_NAME" -p "$FINAL_PROMPT" > patch.diff

# Remove any markdown code fences that might be present in model output
sed -i.bak -e 's/^```diff//; s/^```//; s/```$//' patch.diff || true

# 4. Check and apply the patch
if ! git apply --check patch.diff; then
  echo "❌ The proposed patch could not be applied cleanly. Exiting."
  exit 1
fi
git apply patch.diff
echo "✅ Patch applied to the working directory."

# 5. Format code (Python black and isort for imports)
echo "Formatting code with black and isort..."
pip install --no-cache-dir black isort >/dev/null 2>&1
isort . && black .

# 6. Commit and push changes to a new branch on the fork
BRANCH_NAME="agent-issue-${ISSUE_NUMBER}"
git config user.name "Hushline Agent Bot"
git config user.email "titles-peeps@users.noreply.github.com"
git checkout -b "$BRANCH_NAME"
git add -A
git commit -m "Fix(#${ISSUE_NUMBER}): $ISSUE_TITLE"

echo "Pushing branch '$BRANCH_NAME' to fork..."
git push "https://x-access-token:${AGENT_TOKEN}@github.com/titles-peeps/hushline.git" "$BRANCH_NAME" || {
  echo "❌ Failed to push changes to fork. Exiting."
  exit 1
}

# 7. Create a pull request on the main repository
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
