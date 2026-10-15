# Shared helpers for agent wrappers. Sourced, not executed.
set -o pipefail

AGENTS_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${AI_AGENTS_STATE:-$HOME/.local/state/ai-agents}"
RUNS_DIR="$STATE_DIR/runs"
SHADOW_DIR="$STATE_DIR/shadow"
export PATH="$HOME/.local/bin:$PATH"
# macOS: use GNU coreutils/findutils/sed + flock from Homebrew (brew install coreutils findutils gnu-sed flock rsync)
if [ "$(uname -s)" = Darwin ]; then
  for _p in /opt/homebrew /usr/local; do
    for _t in coreutils findutils gnu-sed; do [ -d "$_p/opt/$_t/libexec/gnubin" ] && PATH="$_p/opt/$_t/libexec/gnubin:$PATH"; done
    [ -d "$_p/bin" ] && PATH="$PATH:$_p/bin"
  done; export PATH
fi
# self-tests put stub `agent` / `agy` binaries first (tests/run.sh)
[ -n "${AI_AGENTS_STUB_BIN:-}" ] && export PATH="$AI_AGENTS_STUB_BIN:$PATH"

# Secrets / overrides (GEMINI_API_KEY, CURSOR_API_KEY, CURSOR_MODEL, GEMINI_MODEL)
[ -f "$HOME/.config/ai-agents/env" ] && set -a && . "$HOME/.config/ai-agents/env" && set +a
[ -f "$AGENTS_HOME/config.sh" ] && . "$AGENTS_HOME/config.sh"

die() { echo "ERROR: $*" >&2; exit 2; }

new_run_id() { echo "$(date +%Y%m%d-%H%M%S)-$1-$(head -c3 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }

# impeccable design detector (optional): first one found, or $IMPECCABLE_BIN
if [ -z "${IMPECCABLE_BIN:-}" ]; then
  for _c in "$HOME/.agents/skills/impeccable/scripts/impeccable" "$HOME/.claude/skills/impeccable/scripts/impeccable"; do
    [ -x "$_c" ] && { IMPECCABLE_BIN="$_c"; break; }; done
fi

# --- shadow git: tracks changes in any dir (git repo or not) without touching it ---
shadow_git() { git -c user.name=agents -c user.email=agents@local -c core.quotepath=off \
  --git-dir="$SG" --work-tree="$WD" "$@"; }

shadow_init() {  # sets SG for $WD
  SG="$SHADOW_DIR/$(printf %s "$WD" | md5sum | cut -c1-12).git"
  if [ ! -d "$SG" ]; then
    mkdir -p "$SHADOW_DIR"; git init -q --bare "$SG"
    echo "$WD" > "$SG/workdir"
  fi
  cp "$AGENTS_HOME/shadow-exclude" "$SG/info/exclude"
}

snapshot() {  # $1=message ; prints commit sha
  shadow_git add -A . >/dev/null 2>&1
  shadow_git commit -q --allow-empty --no-verify -m "$1" >/dev/null 2>&1
  shadow_git rev-parse HEAD
}

# --- the contract every sub-agent must follow ---
# uses: WD, BACKEND, SHELL_OK, SCOPE, TEST
contract() {
cat <<EOF

---
Working rules (sub-agent):
- Workspace: $WD. Only modify files inside it. Keep changes minimal and focused; follow the existing code style.
EOF
[ -n "$SCOPE" ] && cat <<EOF
- FILE SCOPE (hard limit): only create/modify paths matching: $SCOPE
  Any change outside it is detected automatically and fails the run. If the task truly needs another file, do not edit it — say so under UNRESOLVED.
EOF
if [ "$BACKEND" = gemini ] && [ "$SHELL_OK" = 0 ]; then cat <<EOF
- Shell commands are blocked in this mode: do NOT run builds, tests, installs or other shell commands (a blocked command ends your session with nothing done). Read and edit files only.
EOF
fi
[ -n "$TEST" ] && cat <<EOF
- After you finish, the wrapper itself runs this verification in the workspace: $TEST
  If it fails, the full error output is sent back for a retry — make the code pass it.
EOF
cat <<EOF
- NEVER: deploy, rsync, restart/reload services (nginx, php-fpm, pm2, systemd), git commit/push, edit /etc, install global packages, drop/migrate production databases, delete user data.
- NEVER run long-lived processes in the foreground (dev/preview servers, watch modes, npm run dev/preview/start): they never exit and block you forever. Start them in the background: 'cmd >/tmp/x.log 2>&1 & PID=\$!' and 'kill \$PID' when done (never pkill -f).
- UI/frontend work (layout, CSS, components, animation, landing pages): first read the relevant design skills in ~/.agents/skills/ (impeccable, design-taste-frontend, high-end-visual-design, emil-design-eng; animation: animate / review-animations; mobile: mobile-native) if present, and follow them. If Playwright/Chromium is available, screenshot desktop (1440) + mobile (390) of changed pages and fix visual issues before finishing.${IMPECCABLE_BIN:+ Also run '$IMPECCABLE_BIN detect <changed files or src dir>' and fix real findings.}
- Do not paste file contents or long logs into your final answer.
- Your FINAL message must be ONLY this block, nothing else:
STATUS: success | partial | failed
SUMMARY: <max 3 short sentences: what you changed and why>
TESTS: <commands you ran and result, or "not run">
UNRESOLVED: <open issues / assumptions, or "none">
EOF
}

# Extract final text from backend JSON output -> stdout
extract_result() {  # $1=backend $2=json file
  python3 - "$1" "$2" <<'PY'
import json, sys
backend, path = sys.argv[1], sys.argv[2]
raw = open(path, errors="replace").read().strip()
data = None
for cand in (raw, raw[raw.find("{"):] if "{" in raw else ""):
    try: data = json.loads(cand); break
    except Exception: pass
if data is None:
    # stream / noisy output: take last JSON line that parses
    for line in reversed(raw.splitlines()):
        try: data = json.loads(line); break
        except Exception: continue
if not isinstance(data, dict):
    print(raw[-1500:]); sys.exit(0)
if backend == "cursor":
    txt = data.get("result") or ""
    if data.get("is_error"): txt = "STATUS: failed\nSUMMARY: agent error: " + str(txt)[:500]
else:
    txt = data.get("response") or ""
    err = data.get("error")
    if err and not txt: txt = "STATUS: failed\nSUMMARY: agent error: " + json.dumps(err)[:500]
    denied = data.get("denied_actions") or []  # agy: tools blocked by permissions
    if denied:
        d = ", ".join(sorted({str(x.get("display_name") or x.get("action")) for x in denied}))
        txt = txt or "STATUS: failed\nSUMMARY: agent stopped with no output"
        txt += "\nUNRESOLVED: permission-denied tools: " + d + " (see ~/.gemini/antigravity-cli/settings.json; or retry with --shell)"
print(txt)
PY
}

# Pull a single "KEY: value" field (value may continue on following lines until next key)
field() {  # $1=KEY $2=file $3=maxchars
  python3 - "$1" "$2" "${3:-600}" <<'PY'
import re, sys
key, path, mx = sys.argv[1], sys.argv[2], int(sys.argv[3])
txt = open(path, errors="replace").read()
m = re.search(r'(?im)^\**\s*' + key + r'\s*\**\s*:\s*(.*?)(?=^\**\s*(STATUS|SUMMARY|TESTS|UNRESOLVED)\s*\**\s*:|\Z)', txt, re.S | re.M)
v = " ".join(m.group(1).split()) if m else ""
print(v[:mx] + ("…" if len(v) > mx else ""))
PY
}

# Files outside the declared scope.  $1=scope ("a/b/, src/*.ts, x.php" — comma/space separated;
# trailing / or plain dir = prefix, globs via fnmatch)  stdin: changed paths (one per line)  -> stdout: violators
scope_violations() {
  python3 -c '
import sys, fnmatch, re
pats = [p.strip().lstrip("./") for p in re.split(r"[,\s]+", sys.argv[1]) if p.strip()]
def ok(f):
    for p in pats:
        if any(c in p for c in "*?["):
            if fnmatch.fnmatch(f, p) or fnmatch.fnmatch(f, p.rstrip("/") + "/*"): return True
        elif f == p.rstrip("/") or f.startswith(p.rstrip("/") + "/"): return True
    return False
for f in sys.stdin.read().splitlines():
    f = f.strip()
    if f and not ok(f): print(f)
' "$1"
}

# Classify a non-zero agent exit from its logs: quota | auth | "" (unknown)   $1=backend $2=stderr $3=raw
infra_reason() {
  local t; t="$(cat "$2" "$3" 2>/dev/null | tail -c 20000)"
  if echo "$t" | grep -qiE 'exhausted your daily quota|exceeded your current quota|RESOURCE_EXHAUSTED|status: 429|rate.?limit|usage limit|out of (credits|requests)|quota (exceeded|reached)|hit your (usage|limit)|status: 503|high demand'; then echo quota
  elif echo "$t" | grep -qiE 'not logged in|log ?in required|please (log|sign) ?in|unauthenticated|authentication (failed|required)|invalid (api key|credentials)|status: 401|IneligibleTier'; then echo auth
  fi
}
