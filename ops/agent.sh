#!/bin/bash
set -euo pipefail

ISSUE_NUMBER="$(jq -r .issue.number "$GITHUB_EVENT_PATH")"
ISSUE_TITLE="$(jq -r .issue.title "$GITHUB_EVENT_PATH")"
ISSUE_BODY="$(jq -r .issue.body  "$GITHUB_EVENT_PATH")"
echo "Agent triggered for issue #${ISSUE_NUMBER}: ${ISSUE_TITLE}"

REPO_FILES="$(git ls-files | sed -e 's/^/  - /')"
if [[ -f README.md ]]; then
  README_TAIL="$(tail -n 20 README.md | sed -e 's/^/    /')"
else
  README_TAIL="    <README.md not found>"
fi

# ---------- helper: parse FILE blocks (stdin) and emit working-tree diff ----------
parse_and_apply_file_blocks() {
  python3 - "$@" <<'PY' || exit 1
import os, sys, re, subprocess
payload = sys.stdin.read().replace('\r\n','\n').replace('\r','\n')

# Strict FILE block format
pat = re.compile(r'^FILE:\s+([^\n]+)\n-----BEGIN FILE-----\n(.*?)\n-----END FILE-----\n?', re.S|re.M)
blocks = pat.findall(payload)
if not blocks:
    sys.exit(2)  # no matches

changed=set()
for path, content in blocks:
    path = path.strip()
    if not path or path.startswith('/') or '..' in path.split('/'):
        sys.exit(3)  # unsafe path
    d = os.path.dirname(path)
    if d and not os.path.isdir(d):
        os.makedirs(d, exist_ok=True)
    with open(path,'wb') as f:
        f.write(content.encode('utf-8','surrogatepass'))
    changed.add(path)

for p in sorted(changed):
    subprocess.run(["git","add","-N","--",p], check=False)

diff = subprocess.run(["git","diff"], capture_output=True, text=True).stdout
if not diff.strip():
    sys.exit(4)  # no effective diff
sys.stdout.write(diff)
PY
}

# ---------- BODY-FIRST FALLBACK ----------
# If the issue body itself contains valid FILE blocks, use them directly and skip the model entirely.
BODY_PAYLOAD_RAW="$(printf '%s' "$ISSUE_BODY")"
# Extract from sentinels if present
BODY_PAYLOAD="$(printf '%s' "$BODY_PAYLOAD_RAW" | awk '
  /^<<<BEGIN_PATCH$/ {inblk=1; next}
  /^END_PATCH>>>$/   { if(inblk){exit 0} }
  { if(inblk) print }
  END{ if(inblk) exit 0; else exit 1 }
' || true)"

if [[ -z "${BODY_PAYLOAD}" ]]; then
  # Extract the first code-fenced block if provided
  BODY_PAYLOAD="$(printf '%s' "$BODY_PAYLOAD_RAW" | awk '
    BEGIN{f=0}
    /^```/ { if(f==0){f=1; next} else if(f==1){f=2; exit} }
    { if(f==1) print }
  ' || true)"
fi

if [[ -z "${BODY_PAYLOAD}" ]]; then
  # Fallback to raw body
  BODY_PAYLOAD="$BODY_PAYLOAD_RAW"
fi

if echo "$BODY_PAYLOAD" | grep -qE '^FILE:\s+'; then
  if DIFF_FROM_BODY="$(printf '%s' "$BODY_PAYLOAD" | parse_and_apply_file_blocks 2>/dev/null)"; then
    printf '%s' "$DIFF_FROM_BODY" > patch.diff
    git apply --check patch.diff 2>/dev/null || true
    git apply patch.diff 2>/dev/null || true
    echo "Applied FILE blocks from issue body."
    GOTO_COMMIT=1
  else
    echo "Issue body contained FILE blocks but produced no effective diff. Continuing to model."
    GOTO_COMMIT=0
  fi
else
  GOTO_COMMIT=0
fi

# ---------- If BODY path succeeded, skip LLM and commit; otherwise call model ----------
if [[ "${GOTO_COMMIT}" != "1" ]]; then
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
  USER_PROMPT="${USER_PROMPT//\$REPO_FILES/$REPO_FILES}"
  USER_PROMPT="${USER_PROMPT//\$README_TAIL/$README_TAIL}"

  MODEL_NAME="qwen2.5-coder:7b-instruct"

  # Ollama HTTP
  curl -fsS http://127.0.0.1:11434/api/tags >/dev/null
  ollama pull "$MODEL_NAME" || true

  chat_request() {
    local sys="$1" usr="$2"
    jq -n \
      --arg model "$MODEL_NAME" \
      --arg sys   "$sys" \
      --arg usr   "$usr" \
      --argjson opts '{"temperature":0,"num_ctx":8192,"repeat_penalty":1.1}' \
      '{model:$model,stream:false,options:$opts,
        messages:[{role:"system",content:$sys},{role:"user",content:$usr}]}' \
    | curl -fsS -X POST http://127.0.0.1:11434/api/chat \
        -H 'Content-Type: application/json' \
        -d @- \
    | jq -r '.message.content // .response // empty'
  }

  sanitize_ascii() { tr -cd '\11\12\15\40-\176'; }

  extract_payload() {
    # sentinels
    awk '
      /^<<<BEGIN_PATCH$/ {ib=1; next}
      /^END_PATCH>>>$/   { if(ib){exit 0} }
      { if(ib) print }
      END{ if(ib) exit 0; else exit 1 }
    ' > patch.payload 2>/dev/null || true
    [[ -s patch.payload ]] && return 0
    # first code fence
    awk '
      BEGIN{f=0}
      /^```/ { if(f==0){f=1; next} else if(f==1){f=2; exit} }
      { if(f==1) print }
    ' model.out > patch.payload 2>/dev/null || true
    [[ -s patch.payload ]] && return 0
    # whole body
    cp model.out patch.payload
  }

  # Generate
  RESP="$(chat_request "$SYSTEM_PROMPT" "$USER_PROMPT" | sanitize_ascii)"
  printf '%s' "$RESP" > model.out
  extract_payload

  # NO_CHANGES -> green exit
  if grep -qx 'NO_CHANGES' patch.payload 2>/dev/null; then
    echo "NO_CHANGES from model; nothing to apply."
    exit 0
  fi

  # Try FILE blocks from model
  if DIFF_FROM_FILES="$(parse_and_apply_file_blocks < patch.payload 2>/dev/null)"; then
    printf '%s' "$DIFF_FROM_FILES" > patch.diff
    git apply --check patch.diff 2>/dev/null || true
    git apply patch.diff 2>/dev/null || true
    echo "Applied FILE blocks from model."
    GOTO_COMMIT=1
  else
    echo "No actionable FILE blocks; skipping without error."
    exit 0
  fi
fi

# ---------- Commit / push / PR (only if we actually changed something) ----------
export PATH="$HOME/.local/bin:$PATH"
python3 -m pip install --user --no-cache-dir black isort >/dev/null 2>&1 || true
command -v isort >/dev/null 2>&1 && isort . || true
command -v black  >/dev/null 2>&1 && black .  || true

BRANCH_NAME="agent-issue-${ISSUE_NUMBER}"
git config user.name "Hushline Agent Bot"
git config user.email "titles-peeps@users.noreply.github.com"
git checkout -b "$BRANCH_NAME" 2>/dev/null || git checkout "$BRANCH_NAME"

git add -A
if git diff --cached --quiet; then
  echo "No staged changes; nothing to commit."
  exit 0
fi

git commit -m "Fix(#${ISSUE_NUMBER}): ${ISSUE_TITLE}"
git push "https://x-access-token:${AGENT_TOKEN}@github.com/titles-peeps/hushline.git" "$BRANCH_NAME"

PR_TITLE="Fix: ${ISSUE_TITLE}"
PR_BODY="Closes #${ISSUE_NUMBER} (automated AI PR)."
API_JSON=$(printf '%s' "{\"head\":\"titles-peeps:${BRANCH_NAME}\",\"base\":\"main\",\"title\":\"${PR_TITLE//\"/\\\"}\",\"body\":\"${PR_BODY//\"/\\\"}\"}")
RESPONSE=$(curl -s -X POST -H "Authorization: token ${AGENT_TOKEN}" -H "Content-Type: application/json" -d "${API_JSON}" "https://api.github.com/repos/scidsg/hushline/pulls")
PR_URL=$(echo "$RESPONSE" | jq -r .html_url 2>/dev/null || echo "")
[[ -n "$PR_URL" && "$PR_URL" != "null" ]] && echo "PR: $PR_URL" || { echo "$RESPONSE"; exit 1; }
