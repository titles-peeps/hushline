#!/bin/bash
set -euo pipefail

# ---------- Inputs ----------
ISSUE_NUMBER="$(jq -r .issue.number "$GITHUB_EVENT_PATH")"
ISSUE_TITLE="$(jq -r .issue.title "$GITHUB_EVENT_PATH")"
ISSUE_BODY="$(jq -r .issue.body  "$GITHUB_EVENT_PATH")"
echo "Agent triggered for issue #${ISSUE_NUMBER}: ${ISSUE_TITLE}"

# ---------- Repo context for prompt ----------
REPO_FILES="$(git ls-files | sed -e 's/^/  - /')"
if [[ -f README.md ]]; then
  README_TAIL="$(tail -n 20 README.md | sed -e 's/^/    /')"
else
  README_TAIL="    <README.md not found>"
fi

# ---------- Build prompt from YAML ----------
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

# ---------- Ollama HTTP helpers ----------
ollama_health() {
  curl -fsS http://127.0.0.1:11434/api/tags >/dev/null
}
ollama_health || { echo "Ollama API not responding"; exit 1; }
ollama pull "$MODEL_NAME" || true

chat_request() {
  local system_msg="$1"
  local user_msg="$2"
  jq -n \
    --arg model "$MODEL_NAME" \
    --arg sys   "$system_msg" \
    --arg usr   "$user_msg" \
    --argjson opts '{"temperature":0,"num_ctx":8192,"repeat_penalty":1.1}' \
    '{model:$model,stream:false,options:$opts,
      messages:[{role:"system",content:$sys},{role:"user",content:$usr}]}' \
  | curl -fsS -X POST http://127.0.0.1:11434/api/chat \
      -H 'Content-Type: application/json' \
      -d @- \
  | jq -r '.message.content // .response // empty'
}

sanitize_ascii() {
  tr -cd '\11\12\15\40-\176'
}

# ---------- Parse payload (sentinels, then fences, else raw) ----------
extract_payload() {
  # 1) sentinels
  awk '
    /^<<<BEGIN_PATCH$/ {inblk=1; next}
    /^END_PATCH>>>$/   { if(inblk){exit 0} }
    { if(inblk) print }
    END{ if(inblk) exit 0; else exit 1 }
  ' > patch.payload 2>/dev/null || true

  if [[ -s patch.payload ]]; then return 0; fi

  # 2) ```diff fences
  awk '/^```diff/{f=1;next} /^```$/{f=0} f' > patch.payload 2>/dev/null || true
  if [[ -s patch.payload ]]; then return 0; fi

  # 3) raw as last resort
  cat > patch.payload
}

# ---------- FILE blocks parser (robust, Python) ----------
apply_file_blocks() {
  python3 - "$@" <<'PY' || exit 1
import os, sys, re, json, subprocess, textwrap

payload = sys.stdin.read()

# Normalize newlines
payload = payload.replace('\r\n','\n').replace('\r','\n')

# Strict FILE block regex
pattern = re.compile(
    r'^FILE:\s+([^\n]+)\n-----BEGIN FILE-----\n(.*?)\n-----END FILE-----\n?',
    re.S | re.M
)

blocks = pattern.findall(payload)
if not blocks:
    print("No FILE blocks matched", file=sys.stderr)
    sys.exit(2)

changed_paths = []
for path, content in blocks:
    path = path.strip()
    if not path or path.startswith('/') or '..' in path.split('/'):
        print(f"Refusing unsafe path: {path}", file=sys.stderr)
        sys.exit(3)
    d = os.path.dirname(path)
    if d and not os.path.isdir(d):
        os.makedirs(d, exist_ok=True)
    with open(path, 'wb') as f:
        f.write(content.encode('utf-8', 'surrogatepass'))
    changed_paths.append(path)

# Stage intent and emit a unified diff
for p in sorted(set(changed_paths)):
    subprocess.run(["git","add","-N","--",p], check=False)

# Capture diff to stdout
diff = subprocess.run(["git","diff"], capture_output=True, text=True).stdout
if not diff.strip():
    print("FILE blocks produced no effective diff", file=sys.stderr)
    sys.exit(4)

sys.stdout.write(diff)
PY
}

# ---------- Apply unified diff with fallbacks ----------
apply_unified_diff() {
  if git apply --check patch.diff 2>/dev/null; then
    git apply patch.diff; echo "Patch applied."; return 0
  fi
  if git apply --check --whitespace=fix patch.diff 2>/dev/null; then
    git apply --whitespace=fix patch.diff; echo "Patch applied with whitespace fix."; return 0
  fi
  if git apply --check --3way patch.diff 2>/dev/null; then
    git apply --3way patch.diff; echo "Patch applied with 3-way merge."; return 0
  fi
  return 1
}

# ---------- Generation + parsing loop (2 passes) ----------
PASS=1
MAX_PASS=2
VALID=0
while (( PASS <= MAX_PASS )); do
  if (( PASS == 1 )); then
    RESP="$(chat_request "$SYSTEM_PROMPT" "$USER_PROMPT" | sanitize_ascii)"
  else
    STRICT_USER=$'Return ONLY FALLBACK FILE blocks wrapped in sentinels.\nFormat:\n<<<BEGIN_PATCH\nFILE: <relative/path>\n-----BEGIN FILE-----\n<entire file content>\n-----END FILE-----\nEND_PATCH>>>\nNo prose.'
    RESP="$(chat_request "$SYSTEM_PROMPT" "$STRICT_USER" | sanitize_ascii)"
  fi

  printf '%s' "$RESP" > model.out

  # Extract payload
  extract_payload < model.out

  # NO_CHANGES?
  if grep -qx 'NO_CHANGES' patch.payload; then
    echo "NO_CHANGES from model; nothing to apply."
    exit 0
  fi

  # If unified diff present, try to apply
  if grep -q '^diff --git ' patch.payload; then
    awk '/^diff --git /{p=1} p' patch.payload > patch.diff
    if apply_unified_diff; then
      VALID=1
      break
    else
      echo "Unified diff present but failed to apply on pass $PASS." >&2
    fi
  else
    # Try FILE blocks
    DIFF_FROM_FILES="$(apply_file_blocks < patch.payload || true)"
    if [[ -n "${DIFF_FROM_FILES:-}" ]]; then
      printf '%s' "$DIFF_FROM_FILES" > patch.diff
      git apply --check patch.diff 2>/dev/null || true
      git apply patch.diff 2>/dev/null || true
      echo "Applied FILE blocks."
      VALID=1
      break
    else
      echo "Malformed or empty FILE blocks on pass $PASS." >&2
    fi
  fi

  PASS=$((PASS+1))
done

if (( ! VALID )); then
  echo "Model output not usable after $MAX_PASS passes. First lines:" >&2
  sed -n '1,80p' model.out >&2
  exit 1
fi

# ---------- Format (user-space) ----------
export PATH="$HOME/.local/bin:$PATH"
python3 -m pip install --user --no-cache-dir black isort >/dev/null 2>&1 || true
command -v isort >/dev/null 2>&1 && isort . || true
command -v black  >/dev/null 2>&1 && black .  || true

# ---------- Commit / push / PR ----------
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
