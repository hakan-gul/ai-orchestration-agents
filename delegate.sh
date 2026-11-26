#!/usr/bin/env bash
# Route a coding task to a sub-agent: Gemini (agy) first, then the fallback backend (FALLBACK_BACKEND:
# cursor = Cursor Composer | claude = Claude Code CLI, $CLAUDE_MODEL | none) when Gemini is out of quota
# or fails, then ESCALATE to the orchestrator.
#
# Usage: delegate.sh <simple|normal|complex|image> [-C DIR] [--test "CMD"] [--scope "LIST"] [--isolate [NAME]]
#                    [--backend gemini|cursor|claude] [--context "review findings"] [other run-agent opts] "task"
#   simple|normal|complex : gemini ($GEMINI_MODEL_<LEVEL>) -> fallback with failure context -> ESCALATE
#                           gemini quota/auth/cooldown    -> fallback -> fallback retry    -> ESCALATE
#                           fallback none                 -> gemini -> gemini retry        -> ESCALATE
#   image                 : gemini only (no image tool elsewhere): gemini -> gemini retry -> ESCALATE
#   complex               : adds a plan-first instruction
#   --backend B           : start on B (skip Gemini) for a task you know Gemini handles badly
#   FALLBACK_BACKEND      : cursor (default) | claude | none   (~/.config/ai-agents/env; DISABLE_CURSOR=1 = no cursor)
#   --isolate [NAME]      : run in git worktree NAME (default: generated) — all attempts share it; apply with wt.sh
# Exit: 0 success | 3 escalate to the orchestrator | 2 usage/infra error
D="$(cd "$(dirname "$0")" && pwd)"
source "$D/lib.sh"
no_nested
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
case "$START_BACKEND" in gemini|cursor|claude) ;; *) echo "--backend must be gemini|cursor|claude" >&2; exit 2;; esac
if [ "$START_BACKEND" = cursor ] && [ "${DISABLE_CURSOR:-0}" = 1 ]; then
  echo "=== Cursor is disabled (DISABLE_CURSOR=1) -> using ${FB/none/gemini} ==="; START_BACKEND="${FB/none/gemini}"; fi
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

backend_ok() {  # $1=backend: not in a quota cooldown
  local f="$STATE_DIR/$1-cooldown"
  ! { [ -f "$f" ] && [ "$(cut -d' ' -f1 "$f")" -gt "$(date +%s)" ]; }
}
gemini_ok() { backend_ok gemini; }
cooldown_note() { local f="$STATE_DIR/${1:-gemini}-cooldown"
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
    [ "$1" = gemini ] && { OC="${OC:-cli_failure}"; return 1; }   # gemini setup problem: use the fallback
    echo "=== INFRA ERROR ($1 unusable; fix setup: scripts/agents/doctor.sh) ==="; exit 2
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

# ---- code: gemini only (no fallback backend) ----
if [ "$FB" = none ] && [ "$START_BACKEND" = gemini ]; then
  gemini_ok || escalate "gemini in cooldown ($(cooldown_note)) and no fallback backend"
  attempt gemini "$LEVEL" && done_ok
  gemini_down && escalate "gemini unavailable ($OC) and no fallback backend (FALLBACK_BACKEND=${FALLBACK_BACKEND:-cursor}${DISABLE_CURSOR:+, DISABLE_CURSOR=$DISABLE_CURSOR})"
  attempt gemini "$LEVEL retry" --context "$(ctx)" && done_ok
  escalate "gemini failed twice (no fallback backend); last outcome: $OC"
fi

# ---- code: gemini first, fallback backend second ----
fallback() {  # $1=backend $2=label, rest=opts ; escalate at once when the fallback is out of quota
  backend_ok "$1" || escalate "$1 in cooldown ($(cooldown_note "$1"))"
  attempt "$@" && done_ok
  [ "$OC" = quota ] && escalate "$1 out of quota"
  return 0
}
if [ "$START_BACKEND" = gemini ] && gemini_ok; then
  attempt gemini "$LEVEL" && done_ok
  if gemini_down; then
    echo "=== gemini unavailable ($OC) -> $FB ==="
    fallback "$FB" "$LEVEL via $FB" --context "$(ctx)"
    fallback "$FB" "$FB retry" --context "$(ctx)"
  else
    fallback "$FB" "escalated to $FB" --context "$(ctx)"
  fi
else
  B="$START_BACKEND"; [ "$B" = gemini ] && { B="$FB"; echo "=== gemini in cooldown ($(cooldown_note)) -> $B ==="; }
  fallback "$B" "$LEVEL via $B"
  fallback "$B" "$B retry" --context "$(ctx)"
fi
escalate "last outcome: $OC"
