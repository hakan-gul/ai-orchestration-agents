#!/usr/bin/env bash
# Check that sub-agent CLIs are installed and authenticated. Prints one line per check.
source "$(dirname "$0")/lib.sh"
ok=1

# --- local tool dependencies (no network) ---
deps() {
  local bad=0 c
  for c in git python3 rsync flock timeout md5sum pgrep; do
    command -v "$c" >/dev/null || { echo "deps: MISSING $c"; bad=1; }
  done
  stat -c %u / >/dev/null 2>&1 || { echo "deps: stat is not GNU (macOS: brew install coreutils)"; bad=1; }
  date -d @0 +%s >/dev/null 2>&1 || { echo "deps: date is not GNU (macOS: brew install coreutils)"; bad=1; }
  find / -maxdepth 0 -regextype posix-extended >/dev/null 2>&1 || { echo "deps: find is not GNU (macOS: brew install findutils)"; bad=1; }
  sed --version >/dev/null 2>&1 || { echo "deps: sed is not GNU (macOS: brew install gnu-sed)"; bad=1; }
  local bv; bv="$(bash -c 'echo ${BASH_VERSINFO[0]}')"
  [ "$bv" -ge 4 ] || { echo "deps: bash $bv is too old on PATH (macOS: brew install bash)"; bad=1; }
  if [ $bad = 0 ]; then echo "deps: ok (bash $bv, $(git --version | cut -d' ' -f3), $(python3 -V 2>&1))"
  else [ "$(uname -s)" = Darwin ] && echo "deps: macOS one-liner: brew install bash coreutils findutils gnu-sed flock rsync python3"; fi
  return $bad
}
if [ "${1:-}" = --deps ]; then deps; exit $?; fi
deps || ok=0
if command -v agent >/dev/null; then
  echo "cursor: installed $(agent --version 2>/dev/null)"
  if agent status 2>&1 | grep -qi 'not logged in' && [ -z "$CURSOR_API_KEY" ]; then
    echo "cursor: NOT AUTHENTICATED -> run: NO_OPEN_BROWSER=1 agent login   (or put CURSOR_API_KEY in ~/.config/ai-agents/env)"; ok=0
  else
    M="$("$AGENTS_HOME/resolve-model.sh" cursor)" && echo "cursor: auth ok, model=$M" || { echo "cursor: auth ok? but no composer model found"; ok=0; }
  fi
else echo "cursor: MISSING -> curl https://cursor.com/install -fsS | bash"; ok=0; fi

if [ "$GEMINI_CLI" = agy ]; then
  if command -v agy >/dev/null; then
    echo "gemini(agy): installed $(agy --version 2>/dev/null), model=${GEMINI_MODEL:-default}"
    R="$(cd /tmp && timeout 120 agy -p 'Reply with exactly: pong' --output-format json ${GEMINI_MODEL:+--model "$GEMINI_MODEL"} 2>&1)"
    echo "$R" | grep -q pong && echo "gemini(agy): auth ok" || { echo "gemini(agy): call failed -> run 'agy' once interactively to sign in with Google: $(echo "$R" | tail -c 250 | tr '\n' ' ')"; ok=0; }
  else echo "gemini(agy): MISSING -> curl -fsSL https://antigravity.google/cli/install.sh | bash"; ok=0; fi
else
  command -v gemini >/dev/null && echo "gemini(legacy cli): installed" || { echo "gemini: MISSING"; ok=0; }
fi
CDF="$STATE_DIR/gemini-cooldown"
[ -f "$CDF" ] && [ "$(cut -d' ' -f1 "$CDF")" -gt "$(date +%s)" ] && echo "gemini: COOLDOWN until $(date -d @"$(cut -d' ' -f1 "$CDF")" +%H:%M) ($(cut -d' ' -f2- "$CDF")) -> code tasks go to cursor, image tasks escalate"
echo "routing: simple=$GEMINI_MODEL_SIMPLE normal=$GEMINI_MODEL_NORMAL complex=$GEMINI_MODEL_COMPLEX image=$GEMINI_MODEL_IMAGE (gemini first, cursor fallback)"
NWT=$(ls "$STATE_DIR"/worktrees/*.meta 2>/dev/null | wc -l)
[ "$NWT" -gt 0 ] && echo "worktrees: $NWT open (scripts/agents/wt.sh list) — apply or discard finished ones"
[ $ok = 1 ] && echo "doctor: ALL OK" || { echo "doctor: PROBLEMS FOUND"; exit 1; }
