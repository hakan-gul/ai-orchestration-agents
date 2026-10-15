# Defaults (override in ~/.config/ai-agents/env or per call with -m)
: "${GEMINI_CLI:=agy}"     # agy = Antigravity CLI (Google account). "gemini" = legacy Gemini CLI + API key
: "${GEMINI_MODEL:=gemini-3.8-flash-medium}"          # default (ask.sh, direct gemini.sh calls)
# delegate.sh levels — Gemini is the first choice for every level (list: agy models)
: "${GEMINI_MODEL_SIMPLE:=gemini-3.8-flash-medium}"
: "${GEMINI_MODEL_NORMAL:=gemini-3.8-flash-high}"
: "${GEMINI_MODEL_COMPLEX:=gemini-3.8-flash-high}"
: "${GEMINI_MODEL_IMAGE:=gemini-3.8-flash-medium}"    # image tool is the same; the chat model only drives it
: "${CURSOR_MODEL:=}"      # empty = auto-detect newest "composer*" model
