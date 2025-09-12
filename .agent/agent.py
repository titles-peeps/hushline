#!/usr/bin/env python3
import os
import sys
import time
import json
import yaml
import shlex
import queue
import signal
import base64
import hashlib
import logging
import pathlib
import subprocess
import textwrap
import re
from datetime import datetime, timezone

from typing import List, Dict, Any, Optional

# ---------- Logging ----------
logging.basicConfig(
    level=os.environ.get("AGENT_LOGLEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("hushline-agent")

# ---------- Constants ----------
ROOT = pathlib.Path(__file__).resolve().parents[1]
AGENT_DIR = ROOT / ".agent"
STATE_DIR = AGENT_DIR / "_state"
STATE_DIR.mkdir(parents=True, exist_ok=True)
STATE_FILE = STATE_DIR / "state.json"
PROMPT_TEMPLATE_FILE = AGENT_DIR / "prompt_template.md"
CONFIG_FILE = AGENT_DIR / "config.yaml"

DEFAULT_POLL_SECONDS = 60

# ---------- Utilities ----------
def run(cmd, cwd=ROOT, check=True, env=None, capture_output=True) -> subprocess.CompletedProcess:
    if isinstance(cmd, str):
        cmd_list = shlex.split(cmd)
    else:
        cmd_list = cmd
    log.debug("RUN %s", " ".join(shlex.quote(c) for c in cmd_list))
    return subprocess.run(
        cmd_list,
        cwd=str(cwd),
        check=check,
        env=env or os.environ.copy(),
        capture_output=capture_output,
        text=True,
    )

def slugify(s: str) -> str:
    s = s.lower()
    s = re.sub(r"[^a-z0-9\-._/]+", "-", s)
    s = re.sub(r"-+", "-", s)
    return s.strip("-")[:60] or "change"

def load_yaml(path: pathlib.Path) -> dict:
    with path.open("r", encoding="utf-8") as f:
        return yaml.safe_load(f)

def save_json(path: pathlib.Path, obj: dict) -> None:
    tmp = path.with_suffix(".tmp")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2, sort_keys=True)
    tmp.replace(path)

def load_state() -> dict:
    if STATE_FILE.exists():
        with STATE_FILE.open("r", encoding="utf-8") as f:
            return json.load(f)
    return {"processed_issues": {}, "last_run": None}

def save_state(state: dict):
    state["last_run"] = datetime.now(timezone.utc).isoformat()
    save_json(STATE_FILE, state)

def gh_headers(token: str) -> Dict[str, str]:
    return {
        "Authorization": f"token {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "hushline-local-agent/1.0",
    }

def http_get(url: str, token: str) -> dict:
    import requests
    r = requests.get(url, headers=gh_headers(token), timeout=30)
    r.raise_for_status()
    return r.json()

def http_post(url: str, token: str, payload: dict) -> dict:
    import requests
    r = requests.post(url, headers=gh_headers(token), json=payload, timeout=60)
    r.raise_for_status()
    return r.json()

def http_patch(url: str, token: str, payload: dict) -> dict:
    import requests
    r = requests.patch(url, headers=gh_headers(token), json=payload, timeout=60)
    r.raise_for_status()
    return r.json()

def ensure_clean_main(remote="origin", default_branch="main"):
    # Hard reset working copy to remote main
    run(f"git fetch {remote} {default_branch}")
    run(f"git checkout {default_branch}")
    run(f"git reset --hard {remote}/{default_branch}")
    run("git clean -fdx")

def create_ephemeral_remote(token: str, owner: str, repo: str, name="agent-origin"):
    # Do not persist token in the normal origin URL. Create ephemeral remote and delete after push.
    try:
        run(f"git remote remove {name}", check=False)
    except Exception:
        pass
    url = f"https://x-access-token:{token}@github.com/{owner}/{repo}.git"
    run(["git", "remote", "add", name, url])
    return name

def delete_ephemeral_remote(name="agent-origin"):
    run(f"git remote remove {name}", check=False)

def list_repo_files() -> List[str]:
    res = run("git ls-files")
    return [line.strip() for line in res.stdout.splitlines() if line.strip()]

def ripgrep(patterns: List[str], max_files=8) -> List[str]:
    # Best-effort keyword search to pick candidate files
    try:
        pat = r"|".join(re.escape(p) for p in patterns if len(p) >= 3)
        if not pat:
            return []
        res = run(["rg", "-n", "--no-ignore", "--hidden", "-g", "!*.lock", pat], check=False)
        hits = []
        for line in res.stdout.splitlines():
            path = line.split(":", 1)[0]
            if path not in hits and len(hits) < max_files:
                hits.append(path)
        return hits
    except Exception:
        return []

def read_files(paths: List[str], max_bytes=160_000) -> str:
    chunks = []
    total = 0
    for p in paths:
        pth = ROOT / p
        if not pth.exists() or not pth.is_file():
            continue
        try:
            with pth.open("r", encoding="utf-8", errors="ignore") as f:
                data = f.read()
        except Exception:
            continue
        header = f"\n=== FILE:{p} ===\n"
        block = header + data
        sz = len(block.encode("utf-8"))
        if total + sz > max_bytes:
            break
        chunks.append(block)
        total += sz
    return "".join(chunks)

def build_prompt(issue: dict, candidate_files: List[str]) -> str:
    with PROMPT_TEMPLATE_FILE.open("r", encoding="utf-8") as f:
        tpl = f.read()
    files_blob = read_files(candidate_files)
    issue_blob = f"# Issue #{issue['number']}: {issue['title']}\n\n{issue.get('body','').strip()}\n"
    return tpl.replace("{{ISSUE}}", issue_blob).replace("{{FILES}}", files_blob)

def call_ollama(model: str, prompt: str, options: dict) -> str:
    import requests
    url = os.environ.get("OLLAMA_URL", "http://localhost:11434/api/generate")
    payload = {
        "model": model,
        "prompt": prompt,
        "stream": False,
        "options": options or {},
    }
    r = requests.post(url, json=payload, timeout=600)
    r.raise_for_status()
    data = r.json()
    # /api/generate returns {"response": "..."} possibly with trailing metadata
    return data.get("response", "")

def extract_unified_diff(text: str) -> str:
    # Accept fenced ```diff or ```patch or raw unified diff
    fence = re.search(r"```(?:diff|patch)?\s*(.*?)```", text, flags=re.DOTALL | re.IGNORECASE)
    if fence:
        return fence.group(1).strip()
    # Fallback: try to detect lines starting with ---/+++ and @@
    if re.search(r"^---\s", text, flags=re.MULTILINE) and re.search(r"^\+\+\+\s", text, flags=re.MULTILINE):
        return text.strip()
    return ""

def parse_changed_files_from_diff(diff_text: str) -> List[str]:
    files = []
    for m in re.finditer(r"^\+\+\+\s+b/(.+)$", diff_text, flags=re.MULTILINE):
        files.append(m.group(1))
    # Sometimes diff uses a/ and b/ prefixes; strip if present
    files = [f.split("\t")[0] for f in files]
    return list(dict.fromkeys(files))

def apply_diff(diff_text: str) -> None:
    # Write diff to temp and apply via git apply --index to stage changes
    tmp = STATE_DIR / "change.diff"
    tmp.write_text(diff_text, encoding="utf-8")
    # --whitespace=fix reduces churn
    run(["git", "apply", "--index", "--whitespace=fix", str(tmp)])

def run_checks() -> str:
    logs = []
    def exec_log(cmd):
        try:
            p = run(cmd, check=True)
            logs.append(f"$ {cmd}\n{p.stdout}\n{p.stderr}")
            return True
        except subprocess.CalledProcessError as e:
            logs.append(f"$ {cmd}\n{e.stdout}\n{e.stderr}")
            return False

    # Python: poetry/pytest
    if (ROOT / "poetry.lock").exists():
        exec_log("python3 -m pip install -U pip")
        exec_log("python3 -m pip install -U poetry")
        if not exec_log("poetry install --no-root -q"):
            return "\n\n".join(logs)
        exec_log("poetry run pytest -q")
    elif (ROOT / "pyproject.toml").exists() or (ROOT / "tests").exists():
        exec_log("python3 -m pip install -U pip pytest -q")
        exec_log("pytest -q")

    # Pre-commit if configured
    if (ROOT / ".pre-commit-config.yaml").exists():
        exec_log("python3 -m pip install -U pre-commit")
        exec_log("pre-commit run --all-files -v || true")

    return "\n\n".join(logs)

def gh_api_base(owner: str, repo: str) -> str:
    return f"https://api.github.com/repos/{owner}/{repo}"

def list_open_agent_issues(owner: str, repo: str, token: str) -> List[dict]:
    url = f"{gh_api_base(owner, repo)}/issues?state=open&labels=agent&per_page=50"
    return http_get(url, token)

def get_issue(owner: str, repo: str, token: str, number: int) -> dict:
    url = f"{gh_api_base(owner, repo)}/issues/{number}"
    return http_get(url, token)

def create_branch(branch: str, base="main"):
    run(f"git checkout -b {branch} {base}")

def commit_all(message: str):
    run("git add -A")
    run(['git', '-c', 'user.name=HushLine Agent', '-c', 'user.email=bot@hushline.app',
         'commit', '-m', message, '--signoff'])

def push_branch(remote: str, branch: str):
    run(f"git push -u {remote} {branch}")

def open_pr(owner: str, repo: str, token: str, branch: str, title: str, body: str) -> dict:
    payload = {"title": title, "head": branch, "base": "main", "body": body, "maintainer_can_modify": True}
    return http_post(f"{gh_api_base(owner, repo)}/pulls", token, payload)

def add_issue_comment(owner: str, repo: str, token: str, number: int, body: str) -> None:
    http_post(f"{gh_api_base(owner, repo)}/issues/{number}/comments", token, {"body": body})

def ack_issue(owner: str, repo: str, token: str, number: int) -> None:
    try:
        add_issue_comment(owner, repo, token, number, "Agent: received. Working.")
    except Exception as e:
        log.warning("Failed to ack issue #%s: %s", number, e)

def minimal_branch_name(issue: dict) -> str:
    return f"agent/issue-{issue['number']}-{slugify(issue['title'])}"

def format_pr_body(issue: dict, plan_text: str, checks_log: str, changed_files: List[str]) -> str:
    summary = textwrap.dedent(f"""
    ## Summary
    Automated minimal patch for #{issue['number']}.

    ## Context
    {issue.get('body','').strip()}

    ## Changes
    {'\n'.join(f'- {p}' for p in changed_files) or '(see diff)'}

    ## Validation
    - CI runs on this PR via `.github/workflows/agent-ci.yml`.
    - Local preflight logs:

    <details><summary>Logs</summary>

    ```
    {checks_log.strip()}
    ```

    </details>

    ## Notes
    - Generated by local Jetson-based agent using a quantized on-device model.
    """).strip()
    # Include agent plan if present (truncated)
    plan_text = plan_text.strip()
    if plan_text:
        plan_text = re.sub(r"```.*?```", "[…diff omitted…]", plan_text, flags=re.DOTALL)
        plan_text = plan_text[:4000]
        summary += f"\n\n<details><summary>Agent plan</summary>\n\n{plan_text}\n\n</details>"
    summary += f"\n\nCloses #{issue['number']}."
    return summary

def choose_candidate_files(issue: dict) -> List[str]:
    # Combine heuristic search + important files
    words = re.findall(r"[A-Za-z_]{4,}", f"{issue.get('title','')} {issue.get('body','')}")
    keywords = list(dict.fromkeys([w.lower() for w in words]))[:12]
    candidates = ripgrep(keywords, max_files=8)

    # Ensure core files exist in context to keep answers grounded to this repo
    must_consider = [
        "pyproject.toml", "package.json", "README.md",
        "hushline/__init__.py", "hushline", "tests",
    ]
    for p in must_consider:
        if (ROOT / p).exists() and p not in candidates:
            candidates.append(p)
    # Deduplicate and keep files only
    out = []
    for c in candidates:
        p = ROOT / c
        if p.is_file():
            out.append(c)
    return out[:10]

def process_issue(cfg: dict, issue: dict, token: str) -> None:
    owner, repo = cfg["repo_owner"], cfg["repo_name"]
    model = cfg.get("model", "qwen2.5-coder:7b")
    options = cfg.get("ollama_options", {"temperature": 0.1, "num_ctx": 4096})

    log.info("Processing issue #%s: %s", issue["number"], issue["title"])
    ack_issue(owner, repo, token, issue["number"])
    ensure_clean_main(default_branch=cfg.get("default_branch", "main"))

    branch = minimal_branch_name(issue)
    create_branch(branch, base=cfg.get("default_branch", "main"))

    candidate_files = choose_candidate_files(issue)
    prompt = build_prompt(issue, candidate_files)
    llm_out = call_ollama(model, prompt, options)

    diff = extract_unified_diff(llm_out)
    if not diff:
        raise RuntimeError("LLM did not return a unified diff. Aborting.")

    changed_files = parse_changed_files_from_diff(diff)
    if not changed_files:
        log.warning("No changed files detected in diff; proceeding to apply.")
    apply_diff(diff)

    # Preflight checks
    checks_log = run_checks()

    # Commit & push
    commit_msg = f"fix: minimal change for issue #{issue['number']} ({issue['title']})"
    commit_all(commit_msg)

    # Push with token via ephemeral remote
    remote = create_ephemeral_remote(token, owner, repo)
    try:
        push_branch(remote, branch)
    finally:
        delete_ephemeral_remote(remote)

    # Open PR
    pr_title = f"{issue['title']} [agent]"
    pr_body = format_pr_body(issue, llm_out, checks_log, changed_files)
    pr = open_pr(owner, repo, token, branch, pr_title, pr_body)
    log.info("Opened PR #%s %s", pr.get("number"), pr.get("html_url", ""))

def main():
    if not CONFIG_FILE.exists():
        log.error("Missing config: %s", CONFIG_FILE)
        sys.exit(1)

    cfg = load_yaml(CONFIG_FILE)
    token = os.environ.get("AGENT_TOKEN")
    if not token:
        log.error("AGENT_TOKEN not set in environment.")
        sys.exit(2)

    owner, repo = cfg["repo_owner"], cfg["repo_name"]
    poll_seconds = int(cfg.get("poll_seconds", DEFAULT_POLL_SECONDS))

    state = load_state()
    stop = False

    def handle_sigterm(_sig, _frm):
        nonlocal stop
        stop = True

    signal.signal(signal.SIGINT, handle_sigterm)
    signal.signal(signal.SIGTERM, handle_sigterm)

    log.info("Agent started for %s/%s; polling every %ss", owner, repo, poll_seconds)

    while not stop:
        try:
            issues = list_open_agent_issues(owner, repo, token)
            for issue in issues:
                num = str(issue["number"])
                already = state["processed_issues"].get(num)
                if already:
                    continue
                try:
                    process_issue(cfg, issue, token)
                    state["processed_issues"][num] = {"processed_at": datetime.utcnow().isoformat()}
                    save_state(state)
                except Exception as e:
                    log.exception("Failed to process issue #%s: %s", num, e)
                    # leave unprocessed so it can be retried after manual changes
                    time.sleep(5)
        except Exception as e:
            log.warning("Poll error: %s", e)
        save_state(state)
        time.sleep(poll_seconds)

if __name__ == "__main__":
    main()
