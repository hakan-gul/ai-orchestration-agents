#!/usr/bin/env bash
# Show what a sub-agent run changed.  Usage: diff.sh RUN_ID|last [--stat | FILE...]
source "$(dirname "$0")/lib.sh"
R="$1"; shift || true
[ "$R" = last ] || [ -z "$R" ] && R="$(ls -1 "$RUNS_DIR" | while read -r d; do [ -f "$RUNS_DIR/$d/meta" ] && echo "$d"; done | tail -1)"
M="$RUNS_DIR/$R/meta"; [ -f "$M" ] || die "no such run: $R"
. "$M"; SG="$shadow"; WD="$workdir"
if [ "$1" = --stat ]; then shadow_git diff --stat "$before" "$after"
else shadow_git diff -U2 "$before" "$after" -- "$@"; fi
