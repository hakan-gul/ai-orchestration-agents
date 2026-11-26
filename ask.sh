#!/usr/bin/env bash
# Read-only codebase question to a cheap model; returns a short answer (<=3000 chars).
# Usage: ask.sh [-C DIR] [--cursor|--claude] "question"   default: gemini, falls back to $FALLBACK_BACKEND
D="$(dirname "$0")"
source "$D/lib.sh"
no_nested
B=gemini; ARGS=()
for a in "$@"; do case "$a" in --cursor) B=cursor;; --claude) B=claude;; *) ARGS+=("$a");; esac; done
CDF="$STATE_DIR/gemini-cooldown"
if [ $B = gemini ] && [ -f "$CDF" ] && [ "$(cut -d' ' -f1 "$CDF")" -gt "$(date +%s)" ]; then
  [ "$FB" = none ] && { echo "gemini in cooldown and no fallback backend"; exit 1; }
  B=$FB
fi
"$D/run-agent.sh" $B --ask "${ARGS[@]}" && exit 0
[ $B = gemini ] && [ "$FB" != none ] && { echo "--- gemini failed, retrying with $FB ---"; exec "$D/run-agent.sh" "$FB" --ask "${ARGS[@]}"; }
exit 1
