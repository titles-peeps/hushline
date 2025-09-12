#!/bin/bash
set -euo pipefail

# Inputs
ISSUE_NUMBER="$(jq -r .issue.number "$GITHUB_EVENT_PATH")"
ISSUE_TITLE="$(jq -r .issue.title "$GITHUB_EVENT_PATH")"
ISSUE_BODY="$(jq -r .issue.body  "$GITHUB_EVENT_PATH")"
echo "Agent triggered for issue #${ISSUE_NUMBER}: ${ISSUE_TITLE}"

# Repo context
REPO_FILES="$(git ls-files | sed -e 's/^/  - /')"
if [[ -f README.md ]]; then
  README_TAIL="$(tail -n 20 README.md | sed -e 's/^/    /')"
else
  README_TAIL="    <README.md not found>"
fi

# Build prompt from YAML
SYSTEM_PROMPT=""
USER_TEMPLATE=""
section=""
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" =~ ^system: ]]; then section="system"; continue
  elif [[ "$line" =~ ^user: ]]; then section="user"; continue; fi
  trimmed="${line#  }"
  if [[ "$section" == "system" ]]; then SYSTEM_PROMPT+="${trimmed}"$'\n'
  elif [[ "$section" == "user" ]]; then USER_TEMPLATE+="${trimmed}"$'\n'
  fi
done < ops/agent_prompt.yml

USER_PROMPT="${USER_TEMPLATE//\$ISSUE_TITLE/$ISSUE_TITLE}"
USER_PROMPT="${USER_PROMPT//\$ISSUE_BODY/$ISSUE_BODY}"
USER_PROMPT="${USER_PROMPT//\$REPO_FILES/$REPO_FILES}"
USER_PROMPT="${USER_PROMPT//\$README_TAIL/$README_TAIL}"

# Model
MODEL_NAME="qwen2.5-coder:7b-instruct"
ollama pull "$MODEL_NAME" || true

# Health check
curl -fsS http://127.0.0.1:11434/api/tags >/dev/null

# Compose chat request (stream:false for clean JSON)
SYSTEM_JSON=$(printf '%s' "$SYSTEM_PROMPT" | jq -Rs .)
USER_JSON=$(printf '%s' "$USER_PROMPT"   | jq -Rs .)

REQ=$(jq -n --arg model "$MODEL_NAME" \
            --arg sys   "$SYSTEM_PROMPT" \
            --arg usr   "$USER_PROMPT" \
            --argjson opts '{"temperature":0,"num_ctx":8192}' '
{
  model: $model,
  stream: false,
  options: $opts,
  messages: [
    {role:"system", content:$sys},
    {role:"user",   content:$usr}
  ]
}')

# Call Ollama chat API
curl -fsS -X POST http://127.0.0.1:11434/api/chat \
  -H 'Content-Type: application/json' \
  -d "$REQ" \
  | jq -r '.message.content' > model.raw

# Sanitize control chars; keep TAB, LF, CR, and printable ASCII
tr -cd '\11\12\15\40-\176' < model.raw > model.out

# Extract between sentinels
awk '
  /^<<<BEGIN_PATCH$/ {in=1; next}
  /^END_PATCH>>>$/   {if(in){exit 0}}
  { if(in) print }
  END{ if(in) exit 1 }
' model.out > patch.payload || true

if ! [[ -s patch.payload ]]; then
  echo "Model output missing sentinels or empty payload. First lines:"
  sed -n '1,60p' model.out
  exit 1
fi

# Accept NO_CHANGES
if grep -qx 'NO_CHANGES' patch.payload; then
  echo "NO_CHANGES from model; nothing to apply."
  exit 0
fi

# Try unified diff first
if grep -q '^diff --git ' patch.payload; then
  awk '/^diff --git /{p=1} p' patch.payload > patch.diff
  if git apply --check patch.diff 2>/dev/null; then
    git apply patch.diff
    echo "Patch applied."
  elif git apply --check --whitespace=fix patch.diff 2>/dev/null; then
    git apply --whitespace=fix patch.diff
    echo "Patch applied with whitespace fix."
  elif git apply --check --3way patch.diff 2>/dev/null; then
    git apply --3way patch.diff
    echo "Patch applied with 3-way merge."
  else
    echo "Unified diff present but failed to apply. Aborting."
    sed -n '1,80p' patch.diff
    exit 1
  fi
else
  # FALLBACK FILE blocks
  rm -f .agent.changed.list .agent.write.stream
  awk '
    BEGIN{ok=0}
    /^FILE: /{ if(infile){exit 2}; path=substr($0,7); next }
    /^-----BEGIN FILE-----$/ { if(length(path)==0){exit 2}; infile=1; content=""; next }
    /^-----END FILE-----$/ {
      print path >> ".agent.changed.list"
      printf("WRITE\0%s\0%s\0\n", path, content) >> ".agent.write.stream"
      infile=0; path=""; content=""; ok=1; next
    }
    { if(infile){ content = content $0 "\n" } }
    END{ if(infile){exit 2}; exit ok?0:1 }
  ' patch.payload || { echo "Malformed FILE blocks."; exit 1; }

  python3 - <<'PY' < .agent.write.stream
import os,sys
data=sys.stdin.buffer.read().split(b'\0')
i=0
while i+3 <= len(data):
    if data[i] != b'WRITE': break
    path=data[i+1].decode()
    content=data[i+2]
    i+=3
    d=os.path.dirname(path)
    if d and not os.path.isdir(d):
        os.makedirs(d, exist_ok=True)
    with open(path,'wb') as f:
        f.write(content)
PY

  if [[ -f .agent.changed.list ]]; then
    sort -u .agent.changed.list | while read -r p; do
      [[ -n "$p" ]] && git add -N -- "$p" || true
    done
  fi
  git diff > patch.diff || true
  if ! [[ -s patch.diff ]]; then
    echo "No effective changes from FILE blocks."
    exit 1
  fi
  # Apply the constructed diff so downstream tooling sees changes uniformly
  git apply --check patch.diff || true
  git apply patch.diff || true
  echo "Applied FILE blocks."
fi

# Format (user-space)
export PATH="$HOME/.local/bin:$PATH"
python3 -m pip install --user --no-cache-dir black isort >/dev/null 2>&1 || true
command -v isort >/dev/null 2>&1 && isort . || true
command -v black  >/dev/null 2>&1 && black .  || true

# Commit / push / PR
BRANCH_NAME="agent-issue-${ISSUE_NUMBER}"
git config user.name "Hushline Agent Bot"
git config user.email "titles-peeps@users.noreply.github.com"
git checkout -b "$BRANCH_NAME"
git add -A
git commit -m "Fix(#${ISSUE_NUMBER}): ${ISSUE_TITLE}"

echo "Pushing branch '$BRANCH_NAME' to fork..."
git push "https://x-access-token:${AGENT_TOKEN}@github.com/titles-peeps/hushline.git" "$BRANCH_NAME"

PR_TITLE="Fix: ${ISSUE_TITLE}"
PR_BODY="Closes #${ISSUE_NUMBER} (automated AI PR)."
API_JSON=$(printf '%s' "{\"head\":\"titles-peeps:${BRANCH_NAME}\",\"base\":\"main\",\"title\":\"${PR_TITLE//\"/\\\"}\",\"body\":\"${PR_BODY//\"/\\\"}\"}")
RESPONSE=$(curl -s -X POST -H "Authorization: token ${AGENT_TOKEN}" -H "Content-Type: application/json" -d "${API_JSON}" "https://api.github.com/repos/scidsg/hushline/pulls")
PR_URL=$(echo "$RESPONSE" | jq -r .html_url 2>/dev/null || echo "")
[[ -n "$PR_URL" && "$PR_URL" != "null" ]] && echo "PR: $PR_URL" || { echo "$RESPONSE"; exit 1; }
