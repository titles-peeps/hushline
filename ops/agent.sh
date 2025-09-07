#!/usr/bin/env bash
set -euo pipefail
set -x

# usage: ops/agent.sh <issue_number>
if [[ $# -ne 1 ]]; then
  echo "usage: ops/agent.sh <issue_number>" >&2
  exit 2
fi

ISSUE="$1"
REPO="${REPO:-titles-peeps/hushline}"

: "${GH_TOKEN:?GH_TOKEN must be set in env}"
export GITHUB_TOKEN="$GH_TOKEN"

# Stable Ollama endpoint + tame resource usage
export OLLAMA_API_BASE="${OLLAMA_API_BASE:-http://127.0.0.1:11434}"
export OLLAMA_HOST="${OLLAMA_HOST:-http://127.0.0.1:11434}"
export OLLAMA_NUM_PARALLEL=1
export OLLAMA_KEEP_ALIVE=10m
export AIDER_ANALYTICS_DISABLE=1

# Force Aider to native ollama provider (never Litellm), ignore local overrides
unset LITELLM_PROVIDER LITELLM_OLLAMA_BASE OPENAI_API_KEY ANTHROPIC_API_KEY
unset AIDER_MODEL AIDER_WEAK_MODEL AIDER_EDITOR_MODEL AIDER_EDITOR_EDIT_FORMAT
MODEL="${AIDER_MODEL_OVERRIDE:-ollama_chat/qwen2.5-coder:7b-instruct}"

# Repo root and prompt template
[[ -d .git ]] || { echo "must run in repo root"; exit 1; }
[[ -f ops/agent_prompt.tmpl ]] || { echo "missing ops/agent_prompt.tmpl"; exit 1; }

# Git identity
git config user.name  >/dev/null 2>&1 || git config user.name  "hushline-agent"
git config user.email >/dev/null 2>&1 || git config user.email "agent@users.noreply.github.com"

# Deps
for bin in gh git aider curl jq perl; do
  command -v "$bin" >/dev/null || { echo "missing dependency: $bin"; exit 1; }
done

# Ollama health check
set +e
curl -fsS "${OLLAMA_API_BASE}/api/tags" | jq -r .models[0].name >/dev/null
HEALTH_RC=$?
set -e
[[ $HEALTH_RC -ne 0 ]] && { echo "ollama health check failed"; exit 1; }

# Issue data (preserve newlines)
ISSUE_TITLE="$(gh issue view "$ISSUE" -R "$REPO" --json title -q .title)"
ISSUE_BODY="$(gh issue view "$ISSUE" -R "$REPO" --json body  -q .body)"

# Branch off default
DEFAULT_BRANCH="$(gh repo view "$REPO" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || true)"
[[ -z "$DEFAULT_BRANCH" ]] && DEFAULT_BRANCH="$(git remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p' || true)"
[[ -z "$DEFAULT_BRANCH" ]] && DEFAULT_BRANCH="main"

BR="agent/issue-${ISSUE}-$(date +%Y%m%d-%H%M%S)"
git fetch origin --prune
git checkout -B "$BR" "origin/$DEFAULT_BRANCH"

# Build prompt
export ISSUE_NUMBER="$ISSUE" ISSUE_TITLE ISSUE_BODY
envsubst < ops/agent_prompt.tmpl > /tmp/agent_prompt.txt

# Detect explicit files referenced in the issue
TARGET_FILES=()
while IFS= read -r f; do
  [[ -f "$f" ]] && TARGET_FILES+=("$f")
done < <(echo "$ISSUE_BODY" | grep -Eo '([A-Za-z0-9._/-]+\.(scss|css|py|js|ts|html|jinja2|sh|yml|yaml|md|txt|json|toml|ini))' | sort -u)

# Aider settings: force model via a temp model-settings file (ignores local configs)
MSF="$(mktemp)"
cat > "$MSF" <<YAML
model: ${MODEL}
YAML

AIDER_ARGS=(
  --yes
  --no-gitignore
  --model "$MODEL"
  --model-settings-file "$MSF"
  --no-show-model-warnings
  --edit-format udiff
  --timeout 60
  --no-stream
  --disable-playwright
  --map-refresh files
  --map-multiplier-no-files 0
  --map-tokens 256
  --max-chat-history-tokens 512
)

AIDER_LOG="$(mktemp)"
run_aider() {
  if [[ ${#TARGET_FILES[@]} -gt 0 ]]; then
    nice -n 10 ionice -c2 -n7 timeout -k 10 420 \
      aider "${AIDER_ARGS[@]}" --message "$(cat /tmp/agent_prompt.txt)" "${TARGET_FILES[@]}" \
      | tee "$AIDER_LOG" || true
  else
    nice -n 10 ionice -c2 -n7 timeout -k 10 420 \
      aider "${AIDER_ARGS[@]}" --message "$(cat /tmp/agent_prompt.txt)" \
      | tee "$AIDER_LOG" || true
  fi
}

run_aider

# ------------------------------
# Generic fallback patcher
# ------------------------------
# Heuristics:
#   1) Try to extract "old" from 'currently defined as: `...`'
#      and "new" from 'Expected Outcome: `...`'.
#   2) Else, take the FIRST and SECOND inline code snippets (backticked).
#
extract_inline_code_first() {
  perl -0777 -ne 'while(/`([^`]+)`/g){ print "$1\n"; exit 0 }' <<<"$ISSUE_BODY" 2>/dev/null || true
}
extract_inline_code_second() {
  perl -0777 -ne 'my $c=0; while(/`([^`]+)`/g){ $c++; if($c==2){ print "$1\n"; exit 0 } }' <<<"$ISSUE_BODY" 2>/dev/null || true
}
extract_old_from_phrase() {
  perl -0777 -ne 'if(/currently\s+defined\s+as:\s*`([^`]+)`/i){ print "$1\n" }' <<<"$ISSUE_BODY" 2>/dev/null || true
}
extract_new_from_phrase() {
  perl -0777 -ne 'if(/Expected\s+Outcome:.*?`([^`]+)`/is){ print "$1\n" }' <<<"$ISSUE_BODY" 2>/dev/null || true
}

OLD_SNIP="$(extract_old_from_phrase)"
NEW_SNIP="$(extract_new_from_phrase)"

if [[ -z "${OLD_SNIP}" || -z "${NEW_SNIP}" ]]; then
  # Fallback to first/second inline code
  [[ -z "$OLD_SNIP" ]] && OLD_SNIP="$(extract_inline_code_first || true)"
  [[ -z "$NEW_SNIP" ]] && NEW_SNIP="$(extract_inline_code_second || true)"
fi

# If Aider errored with litellm provider OR made no changes, try generic literal patch
NEED_FALLBACK=0
if grep -q "LLM Provider NOT provided" "$AIDER_LOG"; then
  NEED_FALLBACK=1
fi
if git diff --quiet; then
  NEED_FALLBACK=1
fi

if [[ "$NEED_FALLBACK" -eq 1 && -n "${OLD_SNIP:-}" && -n "${NEW_SNIP:-}" && ${#TARGET_FILES[@]} -gt 0 ]]; then
  echo "Attempting generic fallback replacement in referenced files…"
  for f in "${TARGET_FILES[@]}"; do
    if grep -Fq -- "$OLD_SNIP" "$f"; then
      # Literal, global replacement OLD -> NEW
      perl -0777 -pe 'BEGIN{$old=$ENV{OLD};$new=$ENV{NEW}} s/\Q$old\E/$new/g' \
        OLD="$OLD_SNIP" NEW="$NEW_SNIP" -i "$f" || true
      git add "$f" || true
    fi
  done
fi

# If still no changes, report and exit
if git diff --quiet; then
  if (( ${#TARGET_FILES[@]} )); then
    gh issue comment "$ISSUE" -R "$REPO" -b "Agent attempted patch but produced no changes to: ${TARGET_FILES[*]}."
  else
    gh issue comment "$ISSUE" -R "$REPO" -b "Agent attempted patch but found no referenced files to modify."
  fi
  exit 0
fi

# ------------------------------
# Lint loop (no Docker -> skip)
# ------------------------------
lint_once() {
  local log=/tmp/lint.log rc=0
  if [[ -S /var/run/docker.sock ]] && groups "$(whoami)" | grep -q docker; then
    if [[ -f Makefile ]] && grep -qE '^[[:space:]]*lint:' Makefile; then
      set +e; make lint > /dev/null 2> "$log"; rc=$?; set -e
    else
      echo "no make lint" > "$log"; rc=0
    fi
  else
    echo "no docker, skipping dockerized lint" > "$log"; rc=0
  fi
  echo "$log:$rc"
}

for attempt in 1 2; do
  out_rc="$(lint_once)"; log="${out_rc%:*}"; rc="${out_rc##*:}"
  if [[ "$rc" -eq 0 ]]; then break; fi
  FEEDBACK="$(tail -n 200 "$log")"
  printf '%s\n' "Fix these lint errors. Change only what's needed.

\`\`\`
${FEEDBACK}
\`\`\`
" > /tmp/agent_feedback.txt
  timeout -k 10 180 aider "${AIDER_ARGS[@]}" --message "$(cat /tmp/agent_feedback.txt)" || true
  git add -A || true
  git commit -m "agent: lint fix attempt $attempt" || true
done

# ------------------------------
# Tests (skip for frontend-only/text-only changes)
# ------------------------------
run_tests=true
current_head="$(git rev-parse --abbrev-ref HEAD)"
changed_files="$(git diff --name-only "origin/$DEFAULT_BRANCH"..."$current_head")"
if grep -qE '\.(scss|css|js|ts|html|jinja2|yml|yaml|md|txt)$' <<<"$changed_files" && ! grep -qE '\.py($| )' <<<"$changed_files"; then
  run_tests=false
fi

RC=0
if $run_tests && command -v pytest >/dev/null 2>&1; then
  export DATABASE_URL="${DATABASE_URL:-sqlite:///./test.db}"
  set +e; timeout -k 10 600 pytest -q; RC=$?; set -e
fi

# Commit & push
git add -A
git commit -m "Agent patch for #${ISSUE} (${ISSUE_TITLE}) (tests rc=${RC})" || true
git push -u origin "$BR"

# PR
EXISTING_PR="$(gh pr list -R "$REPO" --head "$BR" --json number -q '.[0].number')"
if [[ -z "$EXISTING_PR" ]]; then
  gh pr create -R "$REPO" -t "Agent patch for #${ISSUE}: ${ISSUE_TITLE}" -b "Automated patch for #${ISSUE}. Test exit code: ${RC}."
else
  gh pr comment -R "$REPO" "$EXISTING_PR" -b "Updated patch. Test exit code: ${RC}."
fi

gh issue comment "$ISSUE" -R "$REPO" -b "Agent created/updated PR from branch \`$BR\`. Test exit code: ${RC}."
