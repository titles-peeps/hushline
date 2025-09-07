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

export OLLAMA_API_BASE="${OLLAMA_API_BASE:-http://127.0.0.1:11434}"
export OLLAMA_HOST="${OLLAMA_HOST:-$OLLAMA_API_BASE}"
export LITELLM_OLLAMA_BASE="${LITELLM_OLLAMA_BASE:-$OLLAMA_API_BASE}"

AIDER_MODEL="${AIDER_MODEL:-ollama_chat/qwen2.5-coder:7b-instruct}"

for b in gh git; do
  command -v "$b" >/dev/null || { echo "missing dependency: $b"; exit 1; }
done
command -v aider >/dev/null || AIDER_MISSING=1

# --- repo & branch ---
REPO="$(git config --get remote.origin.url | sed -E 's#.*[:/](.+/.+)\.git#\1#')"
[[ -z "$REPO" ]] && REPO="titles-peeps/hushline"

DEFAULT_BRANCH="$(gh repo view "$REPO" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || true)"
[[ -z "$DEFAULT_BRANCH" ]] && DEFAULT_BRANCH="main"

git fetch origin --prune
BR="agent/issue-${ISSUE}-$(date +%Y%m%d-%H%M%S)"
git checkout -B "$BR" "origin/${DEFAULT_BRANCH}"

# --- get issue text ---
TITLE="$(gh issue view "$ISSUE" -R "$REPO" --json title -q .title)"
BODY="$(gh issue view "$ISSUE"  -R "$REPO" --json body  -q .body)"

# --- deterministic patch path (no LLM) ---
# 1) first file-like token
FILE="$(printf '%s' "$BODY" | grep -Eo '[A-Za-z0-9._/-]+\.[A-Za-z0-9]+' | head -n1 || true)"
# 2) first two backticked code snippets (inline or fenced)
#    - grab the first two occurrences between backticks `
OLD_SNIP="$(printf '%s' "$BODY" | perl -0777 -ne 'while(/`([^`]+)`/g){print "$1\n"}' | sed -n '1p' || true)"
NEW_SNIP="$(printf '%s' "$BODY" | perl -0777 -ne 'while(/`([^`]+)`/g){print "$1\n"}' | sed -n '2p' || true)"

did_change=0
if [[ -n "${FILE:-}" && -f "$FILE" && -n "${OLD_SNIP:-}" && -n "${NEW_SNIP:-}" ]]; then
  # replace the first occurrence only; preserve file if no match
  tmp="$(mktemp)"
  perl -0777 -pe '
    BEGIN{ $old=$ENV{"OLD"}; $new=$ENV{"NEW"}; $done=0 }
    if(!$done && index($_,$old) >= 0){
      s/\Q$old\E/$new/ and $done=1;
    }
  ' OLD="$OLD_SNIP" NEW="$NEW_SNIP" "$FILE" > "$tmp" || true

  if ! cmp -s "$FILE" "$tmp"; then
    mv "$tmp" "$FILE"
    did_change=1
  else
    rm -f "$tmp"
  fi
fi

# --- fallback to Aider if no change and aider exists ---
if [[ "$did_change" -eq 0 ]]; then
  if [[ -z "${AIDER_MISSING:-}" ]]; then
    # minimal prompt
    PROMPT_FILE="$(mktemp)"
    cat > "$PROMPT_FILE" <<EOF
You are the Hush Line code assistant. Work only in this repository.

Task:
- Make the change requested in the referenced issue.
- Keep the diff minimal.
- Output unified diffs only (no prose).
- Edit only existing files.

Title: ${TITLE}

Body:
${BODY}
EOF

    AARGS=( --yes --no-gitignore --model "$AIDER_MODEL" --edit-format udiff --timeout 600 )
    if [[ -n "${FILE:-}" && -f "$FILE" ]]; then
      aider "${AARGS[@]}" --message "$(cat "$PROMPT_FILE")" "$FILE" || true
    else
      aider "${AARGS[@]}" --message "$(cat "$PROMPT_FILE")" || true
    fi
  else
    echo "aider not installed; skipping LLM fallback" >&2
  fi
fi

# --- no changes? tell the issue and exit gracefully ---
if git diff --quiet && git diff --cached --quiet; then
  gh issue comment "$ISSUE" -R "$REPO" -b "Agent attempted a patch but produced no changes."
  exit 0
fi

# --- commit / push / PR ---
git add -A
git commit -m "Agent patch for #${ISSUE}: ${TITLE}" || true
git push -u origin "$BR"

EXISTING_PR="$(gh pr list -R "$REPO" --head "$BR" --json number -q '.[0].number')"
if [[ -z "$EXISTING_PR" ]]; then
  gh pr create -R "$REPO" -t "Agent patch for #${ISSUE}: ${TITLE}" -b "Automated patch for #${ISSUE}."
else
  gh pr comment -R "$REPO" "$EXISTING_PR" -b "Updated patch."
fi

gh issue comment "$ISSUE" -R "$REPO" -b "Agent created/updated PR from \`$BR\`."
