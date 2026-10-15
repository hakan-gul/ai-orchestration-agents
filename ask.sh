#!/usr/bin/env bash
# Read-only codebase question to a cheap model; returns a short answer (<=3000 chars).
# Usage: ask.sh [-C DIR] [--cursor] "question"      default backend: gemini, falls back to cursor
B=gemini; ARGS=()
for a in "$@"; do [ "$a" = --cursor ] && B=cursor || ARGS+=("$a"); done
D="$(dirname "$0")"
CDF="${AI_AGENTS_STATE:-$HOME/.local/state/ai-agents}/gemini-cooldown"
[ $B = gemini ] && [ -f "$CDF" ] && [ "$(cut -d' ' -f1 "$CDF")" -gt "$(date +%s)" ] && B=cursor
"$D/run-agent.sh" $B --ask "${ARGS[@]}" && exit 0
[ $B = gemini ] && { echo "--- gemini failed, retrying with cursor ---"; exec "$D/run-agent.sh" cursor --ask "${ARGS[@]}"; }
exit 1
