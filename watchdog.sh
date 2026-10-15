#!/usr/bin/env bash
# Watchdog for a running sub-agent (started by run-agent.sh).
#
# Usage: watchdog.sh <ROOT_PID> <RUN_DIR> <WORKDIR>
#
# Sub-agents sometimes start a dev/preview server in the FOREGROUND ("npm run preview"), which never exits,
# so the agent blocks silently until the wrapper timeout. Every 30s this:
#   - kills long-lived server/watch processes (>7 min) that are descendants of the agent (the agent's
#     blocked command then returns and the agent continues),
#   - logs a STALL warning when nothing in the workspace changed for 15 min.
# Log: <RUN_DIR>/watchdog.log (one line per event).
ROOT="$1"; RD="$2"; WD="$3"
LOG="$RD/watchdog.log"
MAX_AGE="${WATCHDOG_MAX_AGE:-420}"  # > a normal screenshot test run (which keeps a preview up ~2-3 min)
STALL_MIN="${WATCHDOG_STALL_MIN:-15}"
PATTERN='(^|/| )vite( (preview|dev|serve)( |$)|$)|next (dev|start)|npm (run )?(dev|preview|start|serve)( |$)|artisan serve|webpack(-dev-server| serve)|http-server|python3? -m http\.server|nodemon|--watch( |$)|remotion (studio|preview)'

log() { echo "$(date +%T) $*" >> "$LOG"; }

descendants() {  # all descendant pids of $1
  local c
  for c in $(pgrep -P "$1" 2>/dev/null); do echo "$c"; descendants "$c"; done
}

proc_age() {  # seconds since start; portable ([[dd-]hh:]mm:ss from `ps -o etime`)
  ps -o etime= -p "$1" 2>/dev/null | tr -d ' ' | awk -F'[-:]' '{n=NF; s=$n+60*$(n-1); if(n>=3)s+=3600*$(n-2); if(n>=4)s+=86400*$(n-3); print s}'
}

kill_tree() {
  local p
  for p in $(descendants "$1"); do kill "$p" 2>/dev/null; done
  kill "$1" 2>/dev/null
}

touch "$RD/.watchdog-mark"
LAST_CHANGE=$(date +%s); STALL_WARNED=0
while kill -0 "$ROOT" 2>/dev/null; do
  sleep 30
  for p in $(descendants "$ROOT"); do
    args="$(ps -o args= -p "$p" 2>/dev/null)"; [ -n "$args" ] || continue
    # never kill the agent's own shells (their -c string may mention the server); kill the server process itself
    case "$(basename "$(ps -o comm= -p "$p" 2>/dev/null)")" in bash|sh|dash|zsh|timeout|-bash|-zsh) continue;; esac
    # the agent CLI itself carries the prompt in argv (which may mention "next start" etc.) — never match it
    case "$args" in *cursor-agent/*|*/.local/bin/agent\ *|*antigravity*|agy\ *|*/agy\ *) continue;; esac
    echo "$args" | grep -qE "$PATTERN" || continue
    age=$(proc_age "$p")
    [ -n "$age" ] && [ "$age" -gt "$MAX_AGE" ] || continue
    log "KILLED blocking long-lived process pid=$p age=${age}s: ${args:0:160}"
    kill_tree "$p"
  done
  # stall detection: any workspace file newer than the mark? (ignore heavy dirs)
  if [ -n "$(find "$WD" -path "$WD/node_modules" -prune -o -path "$WD/.git" -prune -o -path "$WD/vendor" -prune \
       -o -type f -newer "$RD/.watchdog-mark" -print -quit 2>/dev/null)" ]; then
    LAST_CHANGE=$(date +%s); STALL_WARNED=0; touch "$RD/.watchdog-mark"
  elif [ $STALL_WARNED = 0 ] && [ $(( $(date +%s) - LAST_CHANGE )) -gt $(( STALL_MIN * 60 )) ]; then
    log "STALL no workspace changes for ${STALL_MIN}min; agent children: $(for c in $(descendants "$ROOT"); do ps -o args= -p "$c" 2>/dev/null | cut -c1-80; printf ' | '; done)"
    STALL_WARNED=1
  fi
done
