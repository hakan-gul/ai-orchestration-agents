#!/usr/bin/env bash
# Print the Cursor model to use: $CURSOR_MODEL, else newest composer model (cached 1 day).
source "$(dirname "$0")/lib.sh"
[ "$1" = cursor ] || exit 1
[ -n "$CURSOR_MODEL" ] && { echo "$CURSOR_MODEL"; exit 0; }
C="$STATE_DIR/cursor-model"
if [ -s "$C" ] && [ -z "$(find "$C" -mmin +1440)" ]; then cat "$C"; exit 0; fi
M="$(timeout 60 agent --list-models 2>/dev/null | grep -oiE '\bcomposer[-a-z0-9.]*' | tr 'A-Z' 'a-z' | grep -v -- '-fast$' | sort -uV | tail -1)"
[ -z "$M" ] && M="$(timeout 60 agent --list-models 2>/dev/null | grep -oiE '\bcomposer[-a-z0-9.]*' | sort -uV | tail -1)"
[ -n "$M" ] || exit 1
mkdir -p "$STATE_DIR"; echo "$M" > "$C"; echo "$M"
