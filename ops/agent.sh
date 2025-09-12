#!/bin/bash
set -euo pipefail
: "${GITHUB_EVENT_PATH:?missing}"
: "${AGENT_TOKEN:?missing}"
ISSUE_NUMBER="$(jq -r .issue.number "$GITHUB_EVENT_PATH")"
ISSUE_TITLE="$(jq -r .issue.title "$GITHUB_EVENT_PATH")"
ISSUE_BODY="$(jq -r .issue.body  "$GITHUB_EVENT_PATH")"
echo "Agent(MVP) for issue #${ISSUE_NUMBER}: ${ISSUE_TITLE}"
BODY_PAYLOAD="$(printf '%s' "$ISSUE_BODY" | awk '/^<<<BEGIN_PATCH$/{ib=1;next}/^END_PATCH>>>$/{if(ib){exit 0}}{if(ib)print}END{if(ib)exit 0;else exit 1}' 2>/dev/null || true)"
if [[ -z "$BODY_PAYLOAD" ]]; then
  BODY_PAYLOAD="$(printf '%s' "$ISSUE_BODY" | awk 'BEGIN{f=0}/^```/{if(f==0){f=1;next}else if(f==1){f=2;exit}}{if(f==1)print}' 2>/dev/null || true)"
fi
if [[ -z "$BODY_PAYLOAD" ]]; then BODY_PAYLOAD="$ISSUE_BODY"; fi
DIFF_OUT="$(python3 - "$BODY_PAYLOAD" <<'PY' || true
import os, sys, re, subprocess
payload = sys.argv[1].replace('\r\n','\n').replace('\r','\n')
pat = re.compile(r'^FILE:\s+([^\n]+)\n-----BEGIN FILE-----\n(.*?)\n-----END FILE-----\n?', re.S|re.M)
blocks = pat.findall(payload)
if not blocks: sys.exit(10)
changed=set()
for path, content in blocks:
    p=path.strip()
    if not p or p.startswith('/') or '..' in p.split('/'): sys.exit(11)
    d=os.path.dirname(p)
    if d and not os.path.isdir(d): os.makedirs(d, exist_ok=True)
    with open(p,'wb') as f: f.write(content.encode('utf-8','surrogatepass'))
    changed.add(p)
for p in sorted(changed): subprocess.run(["git","add","-N","--",p], check=False)
diff = subprocess.run(["git","diff"], capture_output=True, text=True).stdout
if not diff.strip(): sys.exit(12)
sys.stdout.write(diff)
PY
)"
if [[ -z "$DIFF_OUT" ]]; then echo "No actionable FILE blocks; skipping."; exit 0; fi
printf '%s' "$DIFF_OUT" > patch.diff
git apply --check patch.diff 2>/dev/null || true
git apply patch.diff 2>/dev/null || true
BRANCH_NAME="agent-issue-${ISSUE_NUMBER}"
git config user.name "Hushline Agent Bot"
git config user.email "titles-peeps@users.noreply.github.com"
git checkout -b "$BRANCH_NAME" 2>/dev/null || git checkout "$BRANCH_NAME"
git add -A
if git diff --cached --quiet; then echo "Nothing to commit."; exit 0; fi
git commit -m "Fix(#${ISSUE_NUMBER}): ${ISSUE_TITLE}"
git push "https://x-access-token:${AGENT_TOKEN}@github.com/titles-peeps/hushline.git" "$BRANCH_NAME"
PR_TITLE="Fix: ${ISSUE_TITLE}"
PR_BODY="Closes #${ISSUE_NUMBER} (automated MVP agent)."
API_JSON=$(printf '%s' "{\"head\":\"titles-peeps:${BRANCH_NAME}\",\"base\":\"main\",\"title\":\"${PR_TITLE//\"/\\\"}\",\"body\":\"${PR_BODY//\"/\\\"}\"}")
RES=$(curl -s -X POST -H "Authorization: token ${AGENT_TOKEN}" -H "Content-Type: application/json" -d "${API_JSON}" "https://api.github.com/repos/scidsg/hushline/pulls")
URL=$(echo "$RES" | jq -r .html_url 2>/dev/null || echo "")
[[ -n "$URL" && "$URL" != "null" ]] && echo "PR: $URL" || { echo "$RES"; exit 1; }
