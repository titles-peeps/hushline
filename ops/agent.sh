#!/bin/bash
set -euo pipefail

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
  # 1) sentinels
  awk '
    /^<<<BEGIN_PATCH$/ {inblk=1; next}
    /^END_PATCH>>>$/   { if(inblk){exit 0} }
    { if(inblk) print }
    END{ if(inblk) exit 0; else exit 1 }
  ' > patch.payload 2>/dev/null || true
  [[ -s patch.payload ]] && return 0

  # 2) first code fence (any)
  awk '
    BEGIN{f=0}
    /^```/ { if(f==0){f=1; next} else if(f==1){f=2; exit} }
    { if(f==1) print }
  ' model.out > patch.payload 2>/dev/null || true
  [[ -s patch.payload ]] && return 0

  # 3) whole body
  cp model.out patch.payload
}

# FILE blocks parser -> working-tree changes -> diff
parse_and_apply_file_blocks() {
  python3 - "$@" <<'PY' || exit 1
import os, sys, re, subprocess
payload = sys.stdin.read().replace('\r\n','\n').replace('\r','\n')
pat = re.compile(r'^FILE:\s+([^\n]+)\n-----BEGIN FILE-----\n(.*?)\n-----END FILE-----\n?', re.S|re.M)
blocks = pat.findall(payload)
if not blocks:
    print("No FILE blocks matched", file=sys.stderr); sys.exit(2)
changed=[]
for path, content in blocks:
    path=path.strip()
    if not path or path.startswith('/') or '..' in path.split('/'):
        print(f"Refusing unsafe path: {path}", file=sys.stderr); sys.exit(3)
    d=os.path.dirname(path)
    if d and not os.path.isdir(d): os.makedirs(d, exist_ok=True)
    with open(path,'wb') as f: f.write(content.encode('utf-8','surrogatepass'))
    changed.append(path)
for p in sorted(set(changed)):
    subprocess.run(["git","add","-N","--",p], check=False)
diff = subprocess.run(["git","diff"], capture_output=True, text=True).stdout
if not diff.strip():
    print("FILE blocks produced no effective diff", file=sys.stderr); sys.exit(4)
sys.stdout.write(diff)
PY
}

# Deterministic fallback: update brand color when LLM gives nothing usable
brand_color_fallback() {
  COLOR="$(python3 - <<'PY'
import os,re,sys
txt=os.environ.get("ISSUE_TITLE","")+" "+os.environ.get("ISSUE_BODY","")
m=re.search(r'#(?:[0-9a-fA-F]{6}|[0-9a-fA-F]{3})\\b',txt)
if not m: m=re.search(r'rgb\$begin:math:text$\\\\s*\\\\d+\\\\s*,\\\\s*\\\\d+\\\\s*,\\\\s*\\\\d+\\\\s*\\$end:math:text$',txt)
if not m: m=re.search(r'hsl\$begin:math:text$\\\\s*\\\\d+\\\\s*,\\\\s*\\\\d+%\\\\s*,\\\\s*\\\\d+%\\\\s*\\$end:math:text$',txt)
print(m.group(0) if m else(""))
PY
)"
  [[ -z "${COLOR}" ]] && return 1

  echo "Fallback: attempting brand color update to ${COLOR}"

  # Candidate files and patterns
  mapfile -t files < <(git ls-files | grep -E '\.(css|scss|sass|less|js|ts|jsx|tsx|svelte|vue|json|toml|yaml|yml)$' || true)

  # Heuristics: replace variables or explicit colors commonly used for brand
  python3 - "$COLOR" "${files[@]}" <<'PY'
import sys, re, os, io
new_color=sys.argv[1]
paths=sys.argv[2:]
# patterns: CSS var, Tailwind theme, DaisyUI, generic primary/brand tokens, hex literals
var_names=[r'--brand[-_]?color', r'--primary[-_]?color', r'--accent[-_]?color']
keys=[r'brand(Color)?', r'primary(Color)?', r'accent(Color)?', r'brand_[a-z]+', r'PRIMARY(_COLOR)?']
hex_pat=r'#[0-9A-Fa-f]{3,6}\b'
made_change=False
for p in paths:
    try:
        with open(p,'r',encoding='utf-8',errors='surrogatepass') as f: txt=f.read()
    except Exception:
        continue
    orig=txt
    # 1) CSS variables
    for vn in var_names:
        txt=re.sub(r'('+vn+r'\s*:\s*)([^;]+)(;)', r'\1'+new_color+r'\3', txt)
    # 2) JSON-like/TOML/YAML theme keys
    for k in keys:
        # "brand": "#112233" or brand: "#112233"
        txt=re.sub(r'("'+k+r'"|\b'+k+r')\s*[:=]\s*("?)'+hex_pat+r'("?)', r'\1: "'+new_color+r'"', txt)
    # 3) Tailwind-like theme.colors.primary = '#hex'
    txt=re.sub(r'(theme\.colors\.(primary|brand)\s*=\s*)(["\'])'+hex_pat+r'(["\'])', r'\1"'+new_color+r'"', txt)
    if txt!=orig:
        with open(p,'w',encoding='utf-8',errors='surrogatepass') as f: f.write(txt)
        made_change=True
if not made_change:
    sys.exit(2)
PY
  rc=$?
  [[ $rc -ne 0 ]] && return 1

  # Build diff
  git add -N .
  git diff > patch.diff || true
  [[ -s patch.diff ]] || return 1

  # Apply diff to index/WT uniformly
  git apply --check patch.diff 2>/dev/null || true
  git apply patch.diff 2>/dev/null || true
  echo "Fallback brand color update applied."
  return 0
}

# Pass 1: LLM
RESP="$(chat_request "$SYSTEM_PROMPT" "$USER_PROMPT" | sanitize_ascii)"
printf '%s' "$RESP" > model.out
extract_payload

if grep -qx 'NO_CHANGES' patch.payload 2>/dev/null; then
  echo "NO_CHANGES from model; nothing to apply."
  exit 0
fi

# Try FILE blocks
DIFF_FROM_FILES="$(parse_and_apply_file_blocks < patch.payload || true)" || true
if [[ -z "${DIFF_FROM_FILES:-}" ]]; then
  # Pass 2: strict reminder
  STRICT=$'Return only FILE blocks as specified. No prose.'
  RESP="$(chat_request "$SYSTEM_PROMPT" "$STRICT" | sanitize_ascii)"
  printf '%s' "$RESP" > model.out
  extract_payload
  DIFF_FROM_FILES="$(parse_and_apply_file_blocks < patch.payload || true)" || true
fi

if [[ -z "${DIFF_FROM_FILES:-}" ]]; then
  if echo "$ISSUE_TITLE $ISSUE_BODY" | grep -qiE 'brand color|primary color|accent color'; then
    if brand_color_fallback; then
      DIFF_FROM_FILES="$(cat patch.diff)"
    fi
  fi
fi

if [[ -z "${DIFF_FROM_FILES:-}" ]]; then
  echo "LLM output unusable and fallback not applicable."
  sed -n '1,80p' model.out || true
  exit 1
fi

printf '%s' "$DIFF_FROM_FILES" > patch.diff

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
