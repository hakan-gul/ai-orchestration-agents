#!/usr/bin/env bash
# Cursor Agent (Composer) sub-agent. See run-agent.sh for options.
exec "$(dirname "$0")/run-agent.sh" cursor "$@"
