#!/bin/bash
set -euo pipefail

# --- read issue context from GitHub event payload ---
ISSUE_NUMBER="$(jq -r .issue.number "$GITHUB_EVENT_PATH")"
ISSUE_TITLE="$(jq -r .issue.title "$GITHUB_EVENT_PATH")"
ISSUE_BODY="$(jq -r .issue.body "$GITHUB_EVENT_PATH")"

echo "Agent triggered for issue #${ISSUE_NUMBER}: ${ISSUE_TITLE}"

# --- minimal repo context for the prompt ---
REPO_FILES="$(git ls-files | sed -e 's/^/  - /')"
if [[ -f README.md ]]; then
  README_TAIL="$(tail -n 20 README.md | sed -e 's/^/    /')"
else
  README_TAIL="    <README.md not found>"
fi

# --- build prompt from YAML template (system + user) ---
SYSTEM_PROMPT=""
USER_TEMPLATE=""
section=""

while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" =~ ^system: ]]; then section="system"; continue
  elif [[ "$line" =~ ^user: ]]; then section="user"; continue; fi
  trimmed="${line#  }"
  if [[ "$section" == "system" ]]; then
    SYSTEM_PROMPT+="${trimmed}"$'\n'
  elif [[ "$section" == "user" ]]; then
    USER_TEMPLATE+="${trimmed}"$'\n'
  fi
done < ops/agent_prompt.yml

USER_PROMPT="${USER_TEMPLATE//\$ISSUE_TITLE/$ISSUE_TITLE}"
USER_PROMPT="${USER_PROMPT//\$ISSUE_BODY/$ISSUE_BODY}"
USER_PROMPT="${USER_PROMPT//\$REPO_FILES/$REPO_FILES}"
USER_PROMPT="${USER_PROMPT//\$README_TAIL/$README_TAIL}"

FINAL_PROMPT="${SYSTEM_PROMPT}
${USER_PROMPT}"

# --- model invocation (Ollama reads prompt from stdin) ---
MODEL_NAME="qwen2.5-coder:7b-instruct"
echo "Pulling LLM model ($MODEL_NAME) if not already present..."
ollama pull "$MODEL_NAME" || true

echo "Running LLM to generate output..."
echo -e "$FINAL_PROMPT" | ollama run "$MODEL_NAME" > model.out

# --- helpers ---
extract_unified_diff() {
  # Accept raw diff or ```diff fenced block
  if grep -q '^```diff' model.out; then
    awk '/^```diff/{f=1;next} /^```$/{f=0} f' model.out > patch.body || true
  else
    cp model.out patch.body
  fi
  awk '/^diff --git /{p=1} p' patch.body > patch.diff || true
  [[ -s patch.diff ]] && grep -q '^diff --git ' patch.diff
}

apply_unified_diff() {
  git apply --check patch.diff
  git apply patch.diff
  echo "Patch applied."
}

apply_file_blocks() {
  # Parse FILE blocks and write contents
  # Format:
  # FILE: path
  # -----BEGIN FILE-----
  # <content...>
  # -----END FILE-----
  rm -f .agent.changed.list
  awk '
    /^FILE: /{ if(infile){print "ERROR"; exit 1}; path=substr($0,7); next }
    /^-----BEGIN FILE-----$/ { if(length(path)==0){print "ERROR"; exit 1}; infile=1; content=""; next }
    /^-----END FILE-----$/ { 
      print path >> ".agent.changed.list"
      nextfile=path
      gsub(/\r$/,"",content)
      # Defer actual writing to shell; print marker with NUL separators to avoid escaping issues
      printf("WRITE\0%s\0%s\0\n", nextfile, content)
      infile=0; path=""; content=""; next
    }
    { if(infile){ content = content $0 "\n" } }
    END{ if(infile){ print "ERROR"; exit 1 } }
  ' model.out > .agent.write.stream || { echo "Malformed FILE blocks"; return 1; }

  # Perform writes
  python3 - <<'PY'
import os,sys
data=sys.stdin.buffer.read().split(b'\0')
# format: "WRITE", path, content, "\n" ... repeated
i=0
while i+3 <= len(data):
    token=data[i].decode(errors="ignore")
    if token!="WRITE": break
    path=data[i+1].decode()
    content=data[i+2]
    i+=3
    d=os.path.dirname(path)
    if d and not os.path.isdir(d):
        os.makedirs(d, exist_ok=True)
    with open(path,'wb') as f:
        f.write(content)
PY
  < .agent.write.stream

  # Stage intent and build a diff snapshot for logging
  if [[ -f .agent.changed.list ]]; then
    sort -u .agent.changed.list | while read -r p; do
      [[ -n "$p" ]] && git add -N -- "$p" || true
    done
  fi
  git diff > patch.diff || true
  [[ -s patch.diff ]]
}

# --- try unified diff first; otherwise fallback to FILE blocks; else NO_CHANGES ---
if grep -qx 'NO_CHANGES' model.out; then
  echo "NO_CHANGES from model; nothing to apply."
  exit 0
fi

if extract_unified_diff; then
  if apply_unified_diff; then
    MODE="diff"
  else
    echo "git apply failed for unified diff"
    exit 1
  fi
else
  if apply_file_blocks; then
    MODE="files"
    echo "Applied FILE blocks and built working-tree diff."
  else
    echo "Model output not usable (neither valid diff nor valid FILE blocks). First lines:"
    sed -n '1,60p' model.out
    exit 1
  fi
fi

# --- format code (user-space tools) ---
export PATH="$HOME/.local/bin:$PATH"
python3 -m pip install --user --no-cache-dir black isort >/dev/null 2>&1 || true
command -v isort >/dev/null 2>&1 && isort . || true
command -v black >/dev/null 2>&1 && black . || true

# --- commit, push, PR ---
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
