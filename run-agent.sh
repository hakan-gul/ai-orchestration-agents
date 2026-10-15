#!/usr/bin/env bash
# Run one headless sub-agent (cursor | gemini) and print a compact structured summary.
# Full output stays in the run log dir; only the summary reaches the caller.
#
# Usage: run-agent.sh <cursor|gemini>   (gemini = Antigravity CLI "agy" with Google account)
#       run-agent.sh <cursor|gemini> [options] "task"      (task "-" = read stdin)
#   -C DIR          workspace (default: cwd)
#   -m MODEL        override model
#   -t SECONDS      timeout (default 1200; ask mode 600)
#   --test "CMD"    run CMD in workspace after the agent; failure => OUTCOME test_failure, full error digest in summary
#   --scope "LIST"  allowed paths ("src/, tests/*.test.ts, x.php"); anything else changed => OUTCOME scope_violation
#   --isolate NAME  run in git worktree NAME (created from the current tree, reused if it exists); see wt.sh
#   --context TEXT  extra context (e.g. previous attempt's summary / test failure)
#   --ask           read-only question mode: returns a short answer, no edits
#   --shell         gemini only: allow shell tools. Default: accept-edits (file edits only)
#
# OUTCOME (one of): success | partial | agent_failure | test_failure | scope_violation | timeout | quota | auth_failure | cli_failure
#   STATUS is kept for compatibility: success | partial | failed
# Exit: 0 success | 1 any other outcome | 2 usage/auth/infra error (auth_failure, CLI missing, bad options)
source "$(dirname "$0")/lib.sh"

BACKEND="${1:-}"; shift || true
case "$BACKEND" in cursor|gemini) ;; *) die "backend must be cursor|gemini";; esac

WD="$PWD"; MODEL=""; TMO=""; TEST=""; CTX=""; ASK=0; SHELL_OK=0; TASK=""; SCOPE=""; ISO=""
while [ $# -gt 0 ]; do
  case "$1" in
    -C) WD="$2"; shift 2;;
    -m) MODEL="$2"; shift 2;;
    -t) TMO="$2"; shift 2;;
    --test) TEST="$2"; shift 2;;
    --scope) SCOPE="$2"; shift 2;;
    --isolate) ISO="$2"; shift 2;;
    --context) CTX="$2"; shift 2;;
    --ask) ASK=1; shift;;
    --shell) SHELL_OK=1; shift;;
    -) TASK="$(cat)"; shift;;
    -*) die "unknown option $1";;
    *) TASK="$1"; shift;;
  esac
done
[ -n "$TASK" ] || die "no task given"
WD="$(cd "$WD" 2>/dev/null && pwd)" || die "workspace not found"
MAIN_WD="$WD"
if [ -n "$ISO" ]; then
  [ $ASK = 0 ] || die "--isolate cannot be combined with --ask"
  WD="$("$AGENTS_HOME/wt.sh" ensure "$MAIN_WD" "$ISO")" || exit 2
fi

RID="$(new_run_id "$BACKEND")"; RD="$RUNS_DIR/$RID"; mkdir -p "$RD"
PROMPT="$TASK"
[ -n "$CTX" ] && PROMPT="$PROMPT

Context from previous attempt / orchestrator:
$CTX"
if [ $ASK = 1 ]; then
  PROMPT="$PROMPT

Read-only: do NOT modify any files. Answer concisely (max ~20 lines), cite paths as file:line, no long code dumps."
else
  PROMPT="$PROMPT$(contract)"
fi
printf '%s\n' "$PROMPT" > "$RD/prompt.txt"

# ---- build backend command ----
if [ "$BACKEND" = cursor ]; then
  command -v agent >/dev/null || die "cursor 'agent' CLI not installed (run doctor.sh)"
  if [ -z "$MODEL" ]; then MODEL="$("$AGENTS_HOME/resolve-model.sh" cursor)" || die "cursor model resolve failed (logged in?)"; fi
  CMD=(agent -p --output-format json --trust --workspace "$WD" --model "$MODEL")
  if [ $ASK = 1 ]; then CMD+=(--mode ask); else CMD+=(--force); fi
else
  # Gemini via Antigravity CLI (Google account). Legacy gemini CLI only if GEMINI_CLI=gemini.
  MODEL="${MODEL:-$GEMINI_MODEL}"
  if [ "${GEMINI_CLI:-agy}" = agy ]; then
    command -v agy >/dev/null || die "antigravity 'agy' CLI not installed (run doctor.sh)"
    CMD=(agy --output-format json)
    if [ $ASK = 1 ]; then CMD+=(--mode plan); elif [ $SHELL_OK = 1 ]; then CMD+=(--dangerously-skip-permissions); else CMD+=(--mode accept-edits); fi
  else
    command -v gemini >/dev/null || die "gemini CLI not installed (run doctor.sh)"
    if [ $ASK = 1 ]; then AM=plan; elif [ $SHELL_OK = 1 ]; then AM=yolo; else AM=auto_edit; fi
    CMD=(gemini -o json --skip-trust --approval-mode "$AM")
  fi
  [ -n "$MODEL" ] && CMD+=(--model "$MODEL") || MODEL=default
fi
if [ $ASK = 1 ]; then TMO="${TMO:-600}"; else TMO="${TMO:-1200}"; fi
[ "$BACKEND" = gemini ] && [ "${GEMINI_CLI:-agy}" = agy ] && CMD+=(--print-timeout "$((TMO-30))s")

# ---- snapshot, run, snapshot ----
if [ $ASK = 0 ]; then
  shadow_init
  exec 9>"$SG.lock"; flock -w 1800 9 || die "workspace busy (another agent run holds the lock; use --isolate for parallel work)"
  BEFORE="$(snapshot "before $RID")"
fi

touch "$RD/.start"; START=$(date +%s)
# Run in the background so watchdog.sh can kill servers the agent started in the foreground (they block it forever).
if [ "$BACKEND" = cursor ]; then
  (cd "$WD" && exec timeout "$TMO" "${CMD[@]}" "$PROMPT") >"$RD/raw.json" 2>"$RD/stderr.log" </dev/null &
else
  (cd "$WD" && exec timeout "$TMO" "${CMD[@]}" -p "$PROMPT") >"$RD/raw.json" 2>"$RD/stderr.log" </dev/null &
fi
APID=$!
"$(dirname "$0")/watchdog.sh" "$APID" "$RD" "$WD" </dev/null >/dev/null 2>&1 &
WDPID=$!
wait "$APID"; RC=$?
kill "$WDPID" 2>/dev/null
# Orphaned servers the agent backgrounded and forgot (reparented, cwd inside the workspace, started during this run)
[ -d /proc/self ] && for p in $(pgrep -f 'vite|next (dev|start)|npm (run )?(dev|preview|start)|artisan serve|http-server|http\.server|nodemon'); do
  case "$(readlink "/proc/$p/cwd" 2>/dev/null)" in "$WD"|"$WD"/*) ;; *) continue;; esac
  [ "$(ps -o etimes= -p "$p" | tr -d ' ')" -le $(( $(date +%s) - START )) ] || continue
  [ "$(ps -o ppid= -p "$p" | tr -d ' ')" = 1 ] || continue
  echo "$(date +%T) CLEANUP orphan pid=$p: $(tr '\0' ' ' < /proc/$p/cmdline | cut -c1-120)" >> "$RD/watchdog.log"
  pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null
done
[ -s "$RD/watchdog.log" ] && WATCHDOG_NOTE="$(tail -3 "$RD/watchdog.log" | cut -c1-200 | tr '\n' ';')"
DUR=$(( $(date +%s) - START ))
extract_result "$BACKEND" "$RD/raw.json" > "$RD/result.txt"

# ---- infra classification (quota / auth) ----
INFRA=""
if [ $RC -ne 0 ] && [ $RC -ne 124 ]; then INFRA="$(infra_reason "$BACKEND" "$RD/stderr.log" "$RD/raw.json")"
elif [ $RC -eq 0 ] && grep -q 'STATUS: failed' "$RD/result.txt"; then
  # some CLIs exit 0 but report a quota/auth error in the JSON
  INFRA="$(infra_reason "$BACKEND" /dev/null "$RD/result.txt")"
fi
QUOTA=""
if [ "$INFRA" = quota ]; then
  T="$(cat "$RD/stderr.log" "$RD/raw.json" 2>/dev/null | tail -c 20000)"
  if echo "$T" | grep -q 'exhausted your daily quota'; then QUOTA="daily quota exhausted"; CD=360
  elif echo "$T" | grep -qE 'status: 503|high demand'; then QUOTA="model overloaded (503)"; CD=15
  else QUOTA="rate/usage limit"; CD=10; fi
  # gemini cooldown so delegate.sh / ask.sh skip gemini for a while
  [ "$BACKEND" = gemini ] && echo "$(( $(date +%s) + CD*60 )) $QUOTA" > "$STATE_DIR/gemini-cooldown"
fi

# ---- ask mode: just return a capped answer ----
if [ $ASK = 1 ]; then
  echo "RUN: $RID ($BACKEND/$MODEL, ${DUR}s, rc=$RC)"
  if [ $RC -ne 0 ]; then
    echo "STATUS: failed"; echo "OUTCOME: ${INFRA:-cli_failure}"
    echo "ERROR: ${QUOTA:-$(grep -vE '^\s+at ' "$RD/stderr.log" | tail -c 400 | tr '\n' ' ')}"; exit 1
  fi
  head -c 3000 "$RD/result.txt"; [ "$(wc -c < "$RD/result.txt")" -gt 3000 ] && echo "… (truncated, full: $RD/result.txt)"
  exit 0
fi

AFTER="$(snapshot "after $RID")"
printf 'workdir=%q\nbefore=%q\nafter=%q\nbackend=%q\nmodel=%q\nshadow=%q\nisolate=%q\nmain=%q\n' \
  "$WD" "$BEFORE" "$AFTER" "$BACKEND" "$MODEL" "$SG" "$ISO" "$MAIN_WD" > "$RD/meta"
shadow_git diff --name-status "$BEFORE" "$AFTER" > "$RD/changed.txt"
shadow_git diff --numstat "$BEFORE" "$AFTER" > "$RD/numstat.txt"
flock -u 9

# images are not tracked by the shadow repo: list new/modified ones separately
find "$WD" \( -name node_modules -o -name .git -o -name vendor -o -name .next -o -name .cache \) -prune -o \
  -type f -newer "$RD/.start" -regextype posix-extended -iregex '.*\.(png|jpe?g|webp|gif|avif|ico)$' -print 2>/dev/null \
  | sed "s#^$WD/##" | head -40 > "$RD/images.txt"

# keep web files owned like the workspace (agents run as root); isolated runs are chowned by wt.sh apply
OWNER="$(stat -c %u:%g "$WD")"
if [ -z "$ISO" ] && [ "$OWNER" != "0:0" ]; then
  { awk -F'\t' '$1!="D"{print $NF}' "$RD/changed.txt"; cat "$RD/images.txt"; } | while IFS= read -r f; do
    [ -e "$WD/$f" ] && chown "$OWNER" "$WD/$f"; done
fi

# ---- scope check ----
SCOPE_BAD=""
if [ -n "$SCOPE" ]; then
  SCOPE_BAD="$({ awk -F'\t' '{print $NF}' "$RD/changed.txt"; cat "$RD/images.txt"; } | scope_violations "$SCOPE")"
fi

# ---- optional verification ----
TEST_LINE="not run by wrapper"; TEST_OK=1; TEST_DIGEST=""
if [ -n "$TEST" ]; then
  (cd "$WD" && timeout 900 bash -c "$TEST") > "$RD/test.log" 2>&1; TRC=$?
  if [ $TRC -eq 0 ]; then
    TEST_LINE="PASS ($TEST) — $(python3 "$AGENTS_HOME/testdigest.py" pass "$RD/test.log" | head -1)"
    TEST_DIGEST="$(python3 "$AGENTS_HOME/testdigest.py" pass "$RD/test.log" | tail -n +2)"
  else
    TEST_OK=0
    [ $TRC -eq 124 ] && TEST_LINE="FAIL — TIMED OUT after 900s ($TEST)" || TEST_LINE="FAIL rc=$TRC ($TEST)"
    TEST_DIGEST="$(python3 "$AGENTS_HOME/testdigest.py" fail "$RD/test.log" "${TEST_DIGEST_MAX:-150}")"
    TEST_DIGEST="$TEST_DIGEST
  (full log: $RD/test.log)"
  fi
fi

# ---- outcome ----
AGENT_STATUS="$(field STATUS "$RD/result.txt" 40 | tr 'A-Z' 'a-z' | grep -oE 'success|partial|failed' | head -1)"
if [ $RC -eq 124 ] || [ $RC -eq 137 ]; then OUTCOME=timeout; echo "timeout after ${TMO}s" >> "$RD/result.txt"
elif [ "$INFRA" = quota ]; then OUTCOME=quota
elif [ "$INFRA" = auth ]; then OUTCOME=auth_failure
elif [ $RC -ne 0 ] && [ -z "$AGENT_STATUS" ]; then OUTCOME=cli_failure
elif [ -n "$SCOPE_BAD" ]; then OUTCOME=scope_violation
elif [ $TEST_OK = 0 ]; then OUTCOME=test_failure
elif [ "$AGENT_STATUS" = failed ] || [ $RC -ne 0 ]; then OUTCOME=agent_failure
elif [ "$AGENT_STATUS" = success ]; then OUTCOME=success
else OUTCOME=partial; fi   # partial, or agent ignored the contract
case "$OUTCOME" in success) STATUS=success;; partial) STATUS=partial;; *) STATUS=failed;; esac

NFILES=$(grep -c . "$RD/changed.txt")
ADDS=$(awk '{a+=$1} END{print a+0}' "$RD/numstat.txt"); DELS=$(awk '{d+=$2} END{print d+0}' "$RD/numstat.txt")

{
echo "RUN: $RID ($BACKEND/$MODEL, ${DUR}s)"
echo "STATUS: $STATUS"
echo "OUTCOME: $OUTCOME"
echo "CHANGED: $NFILES files, +$ADDS/-$DELS"
head -25 "$RD/changed.txt" | sed 's/^/  /'
[ "$NFILES" -gt 25 ] && echo "  … (+$((NFILES-25)) more)"
[ -s "$RD/images.txt" ] && { echo "IMAGES: $(wc -l < "$RD/images.txt") new/modified"; sed 's/^/  /' "$RD/images.txt"; }
[ -n "$SCOPE_BAD" ] && { echo "OUT-OF-SCOPE (allowed: $SCOPE):"; echo "$SCOPE_BAD" | head -20 | sed 's/^/  /'; }
echo "TESTS(wrapper): $TEST_LINE"
[ -n "$TEST_DIGEST" ] && echo "$TEST_DIGEST"
echo "TESTS(agent): $(field TESTS "$RD/result.txt" 300)"
S="$(field SUMMARY "$RD/result.txt" 600)"
[ -z "$S" ] && S="(no summary) $(tail -c 300 "$RD/result.txt" | tr '\n' ' ')"
if [ $RC -ne 0 ] && [ $RC -ne 124 ]; then
  if [ -n "$QUOTA" ]; then S="$S [$BACKEND unavailable: $QUOTA${CD:+; cooldown ${CD}m}]"
  else S="$S [rc=$RC: $(grep -vE '^\s+at ' "$RD/stderr.log" | tail -c 300 | tr '\n' ' ')]"; fi
fi
echo "SUMMARY: $S"
echo "UNRESOLVED: $(field UNRESOLVED "$RD/result.txt" 400)"
[ -n "$WATCHDOG_NOTE" ] && echo "WATCHDOG: $WATCHDOG_NOTE"
if [ -n "$ISO" ]; then
  echo "WORKTREE: $ISO ($WD)"
  echo "DIFF: $AGENTS_HOME/wt.sh diff $ISO [--stat|FILE]   APPLY: wt.sh apply $ISO   DISCARD: wt.sh discard $ISO"
else
  echo "DIFF: $AGENTS_HOME/diff.sh $RID [--stat|FILE]"
fi
} | tee "$RD/summary.txt"

[ "$OUTCOME" = auth_failure ] && exit 2
[ "$OUTCOME" = success ] && exit 0 || exit 1
