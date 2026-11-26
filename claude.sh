#!/usr/bin/env bash
# Claude Code CLI sub-agent ($CLAUDE_MODEL, default sonnet). See run-agent.sh for options.
exec "$(dirname "$0")/run-agent.sh" claude "$@"
