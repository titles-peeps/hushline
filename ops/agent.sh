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
    -d "$(jq -n --arg body "Agent could not reach local Ollama (127.0.0.1:11434)." '{body:$body}')" \
    "${GITHUB_API}/repos/${GITHUB_REPOSITORY}/issues/${ISSUE_NUMBER}/comments" >/dev/null || true
  exit 0
fi

ollama pull "$MODEL_NAME" || true

chat_once() {
  local sys="$1" usr="$2"
  jq -n --arg model "$MODEL_NAME" --arg sys "$sys" --arg usr "$usr" \
        --argjson opts '{"temperature":0,"num_ctx":8192}' \
        '{model:$model,stream:false,options:$opts,
          messages:[{role:"system",content:$sys},{role:"user",content:$usr}]}' \
  | curl -fsS -X POST http://127.0.0.1:11434/api/chat \
      -H 'Content-Type: application/json' \
      -d @- \
  | jq -r '.message.content // .response // ""'
}

sanitize_ascii() { tr -cd '\11\12\15\40-\176'; }

extract_diff() {
  # Accept raw diff or ```diff fenced
  if grep -q '^```diff' <<<"$1"; then
    awk '/^```diff/{f=1;next} /^```$/{f=0} f' <<<"$1"
  else
    printf '%s' "$1"
  fi | awk '/^diff --git /{p=1} p'
}

apply_diff_with_fallbacks() {
  local diff_file="$1"
  if git apply --check "$diff_file" 2>/dev/null; then
    git apply "$diff_file"; return 0
  fi
  if git apply --check --whitespace=fix "$diff_file" 2>/dev/null; then
    git apply --whitespace=fix "$diff_file"; return 0
  fi
  if git apply --check --3way "$diff_file" 2>/dev/null; then
    git apply --3way "$diff_file"; return 0
  fi
  return 1
}

# Pass 1: ask for unified diff
RAW1="$(chat_once "$SYSTEM_PROMPT" "$USER_PROMPT" | sanitize_ascii)"
if printf '%s' "$RAW1" | grep -qx 'NO_CHANGES'; then
  curl -fsS -X POST \
    -H "Authorization: token ${AGENT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg b "Agent: no change needed (NO_CHANGES)." '{body:$b}')" \
    "${GITHUB_API}/repos/${GITHUB_REPOSITORY}/issues/${ISSUE_NUMBER}/comments" >/dev/null || true
  exit 0
fi

DIFF1="$(extract_diff "$RAW1")"
printf '%s' "$DIFF1" > patch.diff || true

if [[ -s patch.diff ]] && grep -q '^diff --git ' patch.diff; then
  if apply_diff_with_fallbacks patch.diff; then
    applied_mode="diff"
  else
    # Capture target paths from failed diff for the FILE-block retry prompt
    mapfile -t TARGETS < <(grep -E '^diff --git a/.* b/.*$' patch.diff | awk '{print $3}' | sed 's|b/||')
    applied_mode=""
  fi
else
  TARGETS=()
  applied_mode=""
fi

# Pass 2 (only if diff failed): ask for FILE blocks with full contents for specific files
if [[ -z "${applied_mode:-}" ]]; then
  # Build a strict follow-up asking for FILE blocks for the paths in TARGETS (if any).
  TARGET_HINT=""
  if ((${#TARGETS[@]} > 0)); then
    TARGET_HINT=$'\nFiles to return in full (exact paths):\n'
    for p in "${TARGETS[@]}"; do TARGET_HINT+=" - ${p}\n"; done
  fi

  STRICT_USER=$'The previous diff did not apply.\nReturn FULL FILE CONTENTS ONLY using FILE blocks, one per file, no prose:\n'\
$'FILE: <relative/path>\n-----BEGIN FILE-----\n<entire file content>\n-----END FILE-----\n'\
"${TARGET_HINT}"

  RAW2="$(chat_once "$SYSTEM_PROMPT" "$STRICT_USER" | sanitize_ascii)"
  printf '%s' "$RAW2" > model.raw

  # Extract FILE blocks and write files
  python3 - <<'PY' || true
import os, sys, re, subprocess, json
raw = open('model.raw','r',encoding='utf-8',errors='surrogatepass').read()
raw = raw.replace('\r\n','\n').replace('\r','\n')
pat = re.compile(
    r'^FILE:\s+([^\n]+)\n-----BEGIN FILE-----\n(.*?)\n-----END FILE-----\n?',
    re.S|re.M
)
blocks = pat.findall(raw)
if not blocks:
    sys.exit(10)
changed=set()
for path, content in blocks:
    path = path.strip()
    if not path or path.startswith('/') or '..' in path.split('/'):
        continue
    d = os.path.dirname(path)
    if d and not os.path.isdir(d):
        os.makedirs(d, exist_ok=True)
    with open(path,'wb') as f:
        f.write(content.encode('utf-8','surrogatepass'))
    changed.add(path)
for p in sorted(changed):
    subprocess.run(["git","add","-N","--",p], check=False)
diff = subprocess.run(["git","diff"], capture_output=True, text=True).stdout
open('patch.from_files.diff','w',encoding='utf-8',errors='surrogatepass').write(diff)
PY

  if [[ -s patch.from_files.diff ]]; then
    git apply --check patch.from_files.diff 2>/dev/null || true
    git apply patch.from_files.diff 2>/dev/null || true
    applied_mode="files"
  fi
fi

# If nothing applied, comment and exit green
if [[ -z "${applied_mode:-}" ]]; then
  preview="$(sed -n '1,80p' patch.diff 2>/dev/null || true)"
  [[ -z "$preview" ]] && preview="$(sed -n '1,60p' model.raw 2>/dev/null || true)"
  curl -fsS -X POST \
    -H "Authorization: token ${AGENT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg b "Agent could not apply changes from the model. Diagnostic preview:\n\`\`\`\n$preview\n\`\`\`" '{body:$b}')" \
    "${GITHUB_API}/repos/${GITHUB_REPOSITORY}/issues/${ISSUE_NUMBER}/comments" >/dev/null || true
  exit 0
fi

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
    -d "$(jq -n --arg b "Agent applied edits but nothing was staged; aborting PR." '{body:$b}')" \
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
