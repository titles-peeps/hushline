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

# Ensure Ollama is up; if not, post a diagnostic comment and exit 0 (no failure)
if ! curl -fsS http://127.0.0.1:11434/api/tags >/dev/null; then
  DIAG="Local Ollama API is not reachable on 127.0.0.1:11434."
  echo "$DIAG"
  curl -fsS -X POST \
    -H "Authorization: token ${AGENT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg body ":warning: Agent could not run locally.\n\n$DIAG" '{body:$body}')" \
    "${GITHUB_API}/repos/${GITHUB_REPOSITORY}/issues/${ISSUE_NUMBER}/comments" >/dev/null || true
  exit 0
fi

# Make sure model is present (non-fatal if already pulled)
ollama pull "$MODEL_NAME" || true

# Call Ollama chat API (no special formatting expected)
REQUEST_JSON=$(jq -n \
  --arg model "$MODEL_NAME" \
  --arg sys "$SYSTEM_PROMPT" \
  --arg usr "$USER_PROMPT" \
  --argjson opts '{"temperature":0.2,"num_ctx":8192}' \
  '{model:$model,stream:false,options:$opts,
    messages:[{role:"system",content:$sys},{role:"user",content:$usr}]}' )

RAW_RESPONSE="$(curl -fsS -X POST http://127.0.0.1:11434/api/chat \
  -H 'Content-Type: application/json' \
  -d "$REQUEST_JSON" \
  | jq -r '.message.content // .response // ""')"

# Sanitize to printable text; if empty, note that explicitly
RESPONSE_CLEAN="$(printf '%s' "$RAW_RESPONSE" | tr -cd '\11\12\15\40-\176')"
if [[ -z "$RESPONSE_CLEAN" ]]; then
  RESPONSE_CLEAN="(Agent produced no textual output.)"
fi

# Post the agent’s response as an issue comment
COMMENT_BODY=$(
  jq -n --arg out "$RESPONSE_CLEAN" --arg model "$MODEL_NAME" --arg title "$ISSUE_TITLE" '
    { body:
        ("### Agent response\n\n" +
         "**Model:** " + $model + "\n\n" +
         $out)
    }'
)

curl -fsS -X POST \
  -H "Authorization: token ${AGENT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$COMMENT_BODY" \
  "${GITHUB_API}/repos/${GITHUB_REPOSITORY}/issues/${ISSUE_NUMBER}/comments" >/dev/null

echo "Comment posted."
