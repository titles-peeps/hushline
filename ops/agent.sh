#!/bin/bash
set -euo pipefail

ISSUE_NUMBER="$(jq -r .issue.number "$GITHUB_EVENT_PATH")"
ISSUE_TITLE="$(jq -r .issue.title "$GITHUB_EVENT_PATH")"
ISSUE_BODY="$(jq -r .issue.body  "$GITHUB_EVENT_PATH")"
echo "Agent triggered for issue #${ISSUE_NUMBER}: ${ISSUE_TITLE}"

# Repo context for prompt
REPO_FILES="$(git ls-files | sed -e 's/^/  - /')"
if [[ -f README.md ]]; then
  README_TAIL="$(tail -n 20 README.md | sed -e 's/^/    /')"
else
  README_TAIL="    <README.md not found>"
fi

# Load prompt template
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

# Ollama HTTP helpers
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
  # 1) Sentinel-bounded payload
  awk '
    /^<<<BEGIN_PATCH$/ {inblk=1; next}
    /^END_PATCH>>>$/   { if(inblk){exit 0} }
    { if(inblk) print }
    END{ if(inblk) exit 0; else exit 1 }
  ' > patch.payload 2>/dev/null || true

  [[ -s patch.payload ]]
}

parse_and_apply_file_blocks() {
  python3 - "$@" <<'PY' || exit 1
import os, sys, re, subprocess

payload = sys.stdin.read().replace('\r\n','\n').replace('\r','\n')

pattern = re.compile(
    r'^FILE:\s+([^\n]+)\n-----BEGIN FILE-----\n(.*?)\n-----END FILE-----\n?',
    re.S | re.M
)
blocks = pattern.findall(payload)
if not blocks:
    print("No FILE blocks matched", file=sys.stderr)
    sys.exit(2)

changed = []
for path, content in blocks:
    path = path.strip()
    if not path or path.startswith('/') or '..' in path.split('/'):
        print(f"Refusing unsafe path: {path}", file=sys.stderr)
        sys.exit(3)
    d = os.path.dirname(path)
    if d and not os.path.isdir(d):
        os.makedirs(d, exist_ok=True)
    with open(path,'wb') as f:
        f.write(content.encode('utf-8','surrogatepass'))
    changed.append(path)

for p in sorted(set(changed)):
    subprocess.run(["git","add","-N","--",p], check=False)

diff = subprocess.run(["git","diff"], capture_output=True, text=True).stdout
if not diff.strip():
    print("FILE blocks produced no effective diff", file=sys.stderr)
    sys.exit(4)

sys.stdout.write(diff)
PY
}

# Pass 1: normal prompt (already FILE-only)
RESP="$(chat_request "$SYSTEM_PROMPT" "$USER_PROMPT" | sanitize_ascii)"
printf '%s' "$RESP" > model.out

if ! extract_payload < model.out; then
  # Pass 2: ultra-strict user reminder
  STRICT=$'Return ONLY sentinel-wrapped FILE blocks.\nFormat:\n<<<BEGIN_PATCH\nFILE: <relative/path>\n-----BEGIN FILE-----\n<entire file content>\n-----END FILE-----\nEND_PATCH>>>\nNo prose.'
  RESP="$(chat_request "$SYSTEM_PROMPT" "$STRICT" | sanitize_ascii)"
  printf '%s' "$RESP" > model.out
  extract_payload < model.out >/dev/null || true
fi

if ! [[ -s patch.payload ]]; then
  echo "Model output missing sentinels or empty payload. First lines:"
  sed -n '1,60p' model.out
  exit 1
fi

# NO_CHANGES
if grep -qx 'NO_CHANGES' patch.payload; then
  echo "NO_CHANGES from model; nothing to apply."
  exit 0
fi

# Apply FILE blocks
DIFF_FROM_FILES="$(parse_and_apply_file_blocks < patch.payload || true)"
if [[ -z "${DIFF_FROM_FILES:-}" ]]; then
  echo "Malformed or empty FILE blocks."
  sed -n '1,80p' patch.payload
  exit 1
fi

printf '%s' "$DIFF_FROM_FILES" > patch.diff
git apply --check patch.diff 2>/dev/null || true
git apply patch.diff 2>/dev/null || true
echo "Applied FILE blocks."

# Format
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
