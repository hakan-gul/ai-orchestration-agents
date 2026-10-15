#!/usr/bin/env bash
# Gemini Flash sub-agent. See run-agent.sh for options.
exec "$(dirname "$0")/run-agent.sh" gemini "$@"
