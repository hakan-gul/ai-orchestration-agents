#!/usr/bin/env bash
# Route a coding task to a sub-agent: Gemini (agy) first, Cursor Composer when Gemini is out of quota
# or fails, then ESCALATE to the orchestrator.
#
# Usage: delegate.sh <simple|normal|complex|image> [-C DIR] [--test "CMD"] [--scope "LIST"] [--isolate [NAME]]
#                    [--backend cursor] [--context "review findings"] [other run-agent opts] "task"
#   simple|normal|complex : gemini ($GEMINI_MODEL_<LEVEL>) -> cursor with failure context -> ESCALATE
#                           gemini quota/auth/cooldown    -> cursor -> cursor retry      -> ESCALATE
#   image                 : gemini only (Cursor cannot generate images): gemini -> gemini retry -> ESCALATE
#   complex               : adds a plan-first instruction
#   --backend cursor      : start on Cursor (skip Gemini) for a task you know Gemini handles badly
#   --isolate [NAME]      : run in git worktree NAME (default: generated) — all attempts share it; apply with wt.sh
# Exit: 0 success | 3 escalate to the orchestrator | 2 usage/infra error
D="$(cd "$(dirname "$0")" && pwd)"
source "$D/lib.sh"
LEVEL="${1:-}"; shift || true
case "$LEVEL" in simple|normal|complex|image) ;; *) echo "usage: delegate.sh <simple|normal|complex|image> [opts] task" >&2; exit 2;; esac

ARGS=(); TASK=""; UCTX=""; MODEL=""; START_BACKEND=gemini; ISO=""
while [ $# -gt 0 ]; do
  case "$1" in
    -C|-t|--test|--scope) ARGS+=("$1" "$2"); shift 2;;
    -m) MODEL="$2"; shift 2;;
    --shell) ARGS+=("$1"); shift;;
    --backend) START_BACKEND="$2"; shift 2;;
    --isolate) if [ -n "${2:-}" ] && [[ "$2" != -* ]] && [ $# -gt 2 ]; then ISO="$2"; shift 2
               else ISO="iso-$(date +%m%d-%H%M%S)"; shift; fi;;
    --context) UCTX="$2"; shift 2;;
    -) TASK="$(cat)"; shift;;
    *) TASK="$1"; shift;;
  esac
done
[ -n "$TASK" ] || { echo "no task" >&2; exit 2; }
case "$START_BACKEND" in gemini|cursor) ;; *) echo "--backend must be gemini|cursor" >&2; exit 2;; esac
[ "$LEVEL" = image ] && START_BACKEND=gemini
[ -n "$ISO" ] && ARGS+=(--isolate "$ISO")

# Orchestrator review findings: fold into the task so they survive retries (which pass their own --context)
[ -n "${UCTX:-}" ] && TASK="Context / review findings from the lead developer (address all of them):
$UCTX

Task:
$TASK"
[ "$LEVEL" = complex ] && TASK="$TASK

Approach: first inspect the relevant code and form a short plan, then implement it completely."
[ "$LEVEL" = image ] && TASK="$TASK

This is an image-generation task: use your image generation tool, save every image at the exact path(s) requested
(convert/resize only if asked), and list the saved paths in SUMMARY."

case "$LEVEL" in
  simple) GM="$GEMINI_MODEL_SIMPLE";; normal) GM="$GEMINI_MODEL_NORMAL";;
  complex) GM="$GEMINI_MODEL_COMPLEX";; image) GM="$GEMINI_MODEL_IMAGE";;
esac

gemini_ok() {
  local f="$STATE_DIR/gemini-cooldown"
  ! { [ -f "$f" ] && [ "$(cut -d' ' -f1 "$f")" -gt "$(date +%s)" ]; }
}
cooldown_note() { local f="$STATE_DIR/gemini-cooldown"
  printf '%s until %s' "$(cut -d' ' -f2- "$f" 2>/dev/null)" "$(date -d @"$(cut -d' ' -f1 "$f" 2>/dev/null)" +%H:%M 2>/dev/null)"; }

N=0
attempt() {  # $1=backend $2=label, rest=extra opts ; sets OUT, RC, OC (outcome)
  N=$((N+1))
  local m=()
  if [ $N = 1 ] && [ -n "$MODEL" ]; then m=(-m "$MODEL"); elif [ "$1" = gemini ] && [ -n "$GM" ]; then m=(-m "$GM"); fi
  echo "=== [$N: $2] $1 ==="
  OUT="$("$D/run-agent.sh" "$1" "${ARGS[@]}" "${m[@]}" "${@:3}" "$TASK")"; RC=$?
  echo "$OUT"
  OC="$(echo "$OUT" | grep -m1 '^OUTCOME:' | cut -d' ' -f2)"
  if [ $RC -eq 2 ]; then
    [ "$1" = gemini ] && { OC="${OC:-cli_failure}"; return 1; }   # gemini setup problem: fall back to cursor
    echo "=== INFRA ERROR (cursor unusable; fix setup: scripts/agents/doctor.sh) ==="; exit 2
  fi
  return $RC
}
# Previous attempt's report (incl. the full test-error digest) for the next attempt
ctx() { printf 'A previous sub-agent attempt did not finish the task (outcome: %s). Its report — files it changed are still in place, build on or fix them:\n%s\n' \
  "$OC" "$(echo "$OUT" | grep -vE '^(RUN|DIFF|=== )')"
  [ "$OC" = scope_violation ] && echo "First revert/delete every file listed under OUT-OF-SCOPE (restore its previous content), then finish the task inside the allowed scope."
  [ "$OC" = test_failure ] && echo "Fix the root cause of every error listed under TESTS(wrapper); do not weaken or delete the verification."
  return 0; }
gemini_down() { case "$OC" in quota|auth_failure|cli_failure) return 0;; esac; return 1; }
escalate() {
  echo "=== ESCALATE ($1): sub-agents failed; the orchestrator should take over. ==="
  [ -n "$ISO" ] && echo "WORKTREE: $ISO — inspect: scripts/agents/wt.sh diff $ISO --stat | discard: wt.sh discard $ISO" \
    || echo "Inspect with: scripts/agents/diff.sh last"
  exit 3
}
done_ok() { [ -n "$ISO" ] && echo "=== NEXT: review wt.sh diff $ISO --stat, then wt.sh apply $ISO && wt.sh discard $ISO ==="; exit 0; }

# ---- image: gemini only ----
if [ "$LEVEL" = image ]; then
  gemini_ok || escalate "image needs gemini, which is in cooldown: $(cooldown_note)"
  attempt gemini "image" && done_ok
  gemini_down && escalate "gemini unavailable ($OC); cursor cannot generate images"
  attempt gemini "image retry" --context "$(ctx)" && done_ok
  escalate "image generation failed twice"
fi

# ---- code: gemini first, cursor fallback ----
if [ "$START_BACKEND" = gemini ] && gemini_ok; then
  attempt gemini "$LEVEL" && done_ok
  if gemini_down; then
    echo "=== gemini unavailable ($OC) -> cursor ==="
    attempt cursor "$LEVEL via cursor" --context "$(ctx)" && done_ok
    attempt cursor "cursor retry" --context "$(ctx)" && done_ok
  else
    attempt cursor "escalated to cursor" --context "$(ctx)" && done_ok
  fi
else
  [ "$START_BACKEND" = gemini ] && echo "=== gemini in cooldown ($(cooldown_note)) -> cursor ==="
  attempt cursor "$LEVEL via cursor" && done_ok
  attempt cursor "cursor retry" --context "$(ctx)" && done_ok
fi
escalate "last outcome: $OC"
