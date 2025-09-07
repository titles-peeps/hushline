#!/usr/bin/env bash
set -euo pipefail

# usage: ops/agent.sh <issue_number>
if [[ $# -ne 1 ]]; then
  echo "usage: ops/agent.sh <issue_number>" >&2
  exit 2
fi

ISSUE="$1"

# --- minimal env & deps ---
: "${GH_TOKEN:?GH_TOKEN missing}"
export GITHUB_TOKEN="$GH_TOKEN"

for b in gh git perl; do
  command -v "$b" >/dev/null || { echo "missing dependency: $b"; exit 1; }
done

# --- repo & branch ---
REPO="$(git config --get remote.origin.url | sed -E 's#.*[:/](.+/.+)\.git#\1#')"
[[ -z "$REPO" ]] && REPO="titles-peeps/hushline"

DEFAULT_BRANCH="$(gh repo view "$REPO" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || true)"
[[ -z "$DEFAULT_BRANCH" ]] && DEFAULT_BRANCH="main"

git fetch origin --prune
BR="agent/issue-${ISSUE}-$(date +%Y%m%d-%H%M%S)"
git checkout -B "$BR" "origin/${DEFAULT_BRANCH}"

# Ensure git identity
git config user.name  >/dev/null 2>&1 || git config user.name  "hushline-agent"
git config user.email >/dev/null 2>&1 || git config user.email "agent@users.noreply.github.com"

# --- get issue text ---
TITLE="$(gh issue view "$ISSUE" -R "$REPO" --json title -q .title)"
BODY_FILE="$(mktemp)"
gh issue view "$ISSUE" -R "$REPO" --json body -q .body > "$BODY_FILE"

trim() { sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

# --- resolve target file ---
# 1) Prefer "Path to file: <path>" or "Path to file:\n`<path>`"
FILE="$(awk '
  BEGIN{ IGNORECASE=1; found=0 }
  /^Path[[:space:]]+to[[:space:]]+file:/ { 
    sub(/^Path[[:space:]]+to[[:space:]]+file:[[:space:]]*/,"");
    gsub(/`/,"");
    print; found=1; exit
  }' "$BODY_FILE" | head -n1 | tr -d "\r" | sed "s/^ *//; s/ *$//")"

# 2) If not found, pick first token that looks like a path and exists
if [[ -z "${FILE:-}" ]]; then
  while IFS= read -r cand; do
    if [[ -f "$cand" ]]; then FILE="$cand"; break; fi
  done < <(grep -Eo '[A-Za-z0-9._/-]+\.[A-Za-z0-9]+' "$BODY_FILE" | sort -u)
fi

# --- extract old/new snippets (first two backticked spans) ---
OLD="$(perl -0777 -ne 'while(/`([^`]+)`/g){print "$1\n"}' "$BODY_FILE" | sed -n '1p' | tr -d "\r")"
NEW="$(perl -0777 -ne 'while(/`([^`]+)`/g){print "$1\n"}' "$BODY_FILE" | sed -n '2p' | tr -d "\r")"

# --- guardrails and helpful comments ---
if [[ -z "${FILE:-}" ]]; then
  gh issue comment "$ISSUE" -R "$REPO" -b "Agent: No file path found in the issue. Please add a line like:
\`Path to file: relative/path/to/file.ext\`"
  exit 0
fi

if [[ ! -f "$FILE" ]]; then
  gh issue comment "$ISSUE" -R "$REPO" -b "Agent: File not found: \`$FILE\`. Please verify the path."
  exit 0
fi

if [[ -z "${OLD:-}" || -z "${NEW:-}" ]]; then
  gh issue comment "$ISSUE" -R "$REPO" -b "Agent: Could not find two backticked snippets in the issue body (old → new). Please provide:
\`\`\`
old code in \`backticks\`
new code in \`backticks\`
\`\`\`"
  exit 0
fi

# --- apply single replacement (first occurrence) ---
TMP="$(mktemp)"
changed=0
perl -0777 -pe '
  BEGIN { $old=$ENV{"OLD"}; $new=$ENV{"NEW"}; $done=0 }
  if (!$done && index($_,$old) >= 0) { s/\Q$old\E/$new/ and $done=1; }
  END { if(!$done){ exit 2 } }
' OLD="$OLD" NEW="$NEW" "$FILE" > "$TMP" || rc=$?

if [[ ${rc:-0} -eq 2 ]]; then
  rm -f "$TMP"
  gh issue comment "$ISSUE" -R "$REPO" -b "Agent: The specified snippet was not found in \`$FILE\`. No changes made."
  exit 0
fi

if ! cmp -s "$FILE" "$TMP"; then
  mv "$TMP" "$FILE"
  changed=1
else
  rm -f "$TMP"
fi

if [[ "$changed" -ne 1 ]]; then
  gh issue comment "$ISSUE" -R "$REPO" -b "Agent: No modifications were necessary."
  exit 0
fi

# --- commit / push / PR ---
git add -A
git commit -m "Agent patch for #${ISSUE}: ${TITLE}"
git push -u origin "$BR"

PR_NUM="$(gh pr list -R "$REPO" --head "$BR" --json number -q '.[0].number')"
if [[ -z "$PR_NUM" ]]; then
  gh pr create -R "$REPO" -t "Agent patch for #${ISSUE}: ${TITLE}" -b "Automated patch for #${ISSUE}."
else
  gh pr comment -R "$REPO" "$PR_NUM" -b "Updated patch."
fi

gh issue comment "$ISSUE" -R "$REPO" -b "Agent created/updated PR from \`$BR\` targeting \`${DEFAULT_BRANCH}\`."
