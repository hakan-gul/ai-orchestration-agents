# ai-orchestration-agents

Cost-aware multi-agent coding from the terminal. An expensive **orchestrator** model (the agent in Cursor, Claude Code, …) plans, writes the task contract and reviews. Cheap **sub-agents** do the implementation:

```
orchestrator ──► delegate.sh ──► Gemini (Antigravity CLI `agy`) ──fails / out of quota──► Cursor Composer (`agent` CLI) ──► ESCALATE
                                     │
                                     └─ run-agent.sh: snapshot → agent → snapshot → your test → scope check → ~15-line summary
```

The orchestrator never reads raw agent output. It gets a short summary like this one:

```
RUN: 20261015-114748-gemini-6c0f7c (gemini/gemini-3.8-flash-high, 455s)
STATUS: failed
OUTCOME: test_failure
CHANGED: 2 files, +48/-6
  M	src/cart/store.ts
  A	tests/cart/store.test.ts
TESTS(wrapper): FAIL rc=1 (npx tsc --noEmit && npm test)
  | src/cart/store.ts(42,17): error TS2532: Object is possibly 'undefined'.
SUMMARY: …
UNRESOLVED: none
```

…and the same error digest is passed to the next attempt automatically.

## Features

- **Gemini first, Composer as fallback.** Every level (`simple`, `normal`, `complex`) starts on Gemini. On quota, auth or CLI errors the task moves to Cursor Composer, and a cooldown is recorded so later tasks skip Gemini for a while. A normal failure is retried on Composer together with the full failure report.
- **Image generation.** The `image` level uses Gemini's image tool. It has no Composer fallback, because Composer can't generate images.
- **The wrapper runs your tests, not the agent.** With `--test "<cmd>"`, a failed test sets `OUTCOME: test_failure` and puts every error line in the summary. Logs up to 60 lines are included in full; longer logs are reduced to their error blocks with per-file counts. A passing test shows its counts and flags `NO TESTS RAN`.
- **Outcome taxonomy.** `success`, `partial`, `agent_failure`, `test_failure`, `scope_violation`, `timeout`, `quota`, `auth_failure`, `cli_failure`.
- **Scope guard.** With `--scope "src/cart/, tests/*.ts"`, any change outside those paths is reported as `scope_violation`, and the next attempt reverts it first.
- **Isolated worktrees.** `--isolate NAME` runs the agent in a git worktree built from the current state of your tree: uncommitted changes, untracked files and `.env` are copied, and `node_modules`/`vendor` are symlinked. Review the result, then `wt.sh apply` or `wt.sh discard` it. This also allows parallel tasks in one repo.
- **Works without git.** Changes are tracked in a shadow git repository, so diffs and reviews work in any directory.
- **Watchdog.** It kills dev servers that an agent left running in the foreground and logs a warning when a run stalls.
- **Self-tests.** `tests/run.sh` covers routing, outcomes, scope checks and worktrees using stub agents. It needs no network and takes about 15 s.

## Requirements

- Linux, macOS (with Homebrew GNU tools) or Windows via **WSL2**
- bash ≥ 4, git, python3, rsync, flock
- [Antigravity CLI](https://antigravity.google) (`agy`), logged in with a Google account
- [Cursor CLI](https://cursor.com/cli) (`agent`), logged in with a Cursor account

## Quick start

```bash
git clone https://github.com/hakan-gul/ai-orchestration-agents ~/ai-agents-src
cd ~/ai-agents-src
./install.sh --project ~/code/my-app --cursor --agy-perms ~/code   # installs to ~/.ai-agents
~/.ai-agents/doctor.sh && bash ~/.ai-agents/tests/run.sh
```

`--cursor` writes `.cursor/rules/ai-orchestration.mdc` (always applied) into the project, so the Cursor agent starts orchestrating. Use `--claude` / `--claude-global` for Claude Code instead.

## Usage

```bash
A=~/.ai-agents
$A/delegate.sh normal -C ~/code/my-app --test "npm test" --scope "src/cart/, tests/cart/" "Objective: … Acceptance: …"
$A/delegate.sh image  -C ~/code/site --scope "public/img/" "public/img/hero.webp: 1600x900, warm tones, no text"
$A/ask.sh -C ~/code/my-app "Where is the payment webhook verified? file:line"
$A/diff.sh last --stat
```

Exit codes: `0` success · `3` escalate (the orchestrator takes over) · `2` setup/auth problem (`doctor.sh`).

## Documentation

**[docs/GUIDE.md](docs/GUIDE.md)** is the full guide. It covers architecture and design decisions, installation (Linux, macOS, Windows/WSL2), Cursor and Claude Code setup, the task contract template, the outcome reference, configuration and troubleshooting.

`./pack.sh` builds `dist/AI-ORCHESTRATION.md`: the guide plus the full source of every file in one extractable Markdown file, for setups that can't use git.

## License

[MIT](LICENSE)
