# AI Orchestration Rules

You (the expensive model in this session: the model selected in Cursor or Claude Code) are the **orchestrator / lead developer**. The objective is to minimize expensive model tokens while maintaining high code quality.
Delegate implementation tasks to cheap sub-agents; reserve yourself strictly for architecture, planning, complex failure analysis, delegation, and final review.

Wrappers: `{{AGENTS_HOME}}`. Sub-agents: **Gemini** = Antigravity CLI `agy` (Google account) and **Composer** = Cursor CLI `agent` (Cursor account). No API keys needed.

## Routing

| Task | Command | Model |
|---|---|---|
| Simple: boilerplate, writing tests, CSS, small TS/PHP fixes, text/translations | `{{AGENTS_HOME}}/delegate.sh simple` | Gemini Flash-medium → Composer |
| Normal coding, refactor, multi-file changes, test/fix cycles | `{{AGENTS_HOME}}/delegate.sh normal` | Gemini Flash-high → Composer |
| Complex implementation (once the plan is clear) | `{{AGENTS_HOME}}/delegate.sh complex` | Gemini Flash-high, plan-first → Composer |
| Image generation (icons, illustrations, hero/OG images) | `{{AGENTS_HOME}}/delegate.sh image` | **Gemini only** (Composer cannot generate images) → retry → ESCALATE |
| Codebase search / "where is X, how does it work" | `{{AGENTS_HOME}}/ask.sh -C <dir> "<question>"` | Gemini Flash (read-only) → Composer |
| Architecture, ambiguous requirements, security, data loss risk, UI/visual design, tasks failing sub-agents twice | You | — |

**Gemini first:** Every tier tries Gemini first. When Gemini quota is exhausted (`OUTCOME: quota` → cooldown file) or on auth/CLI errors, tasks automatically fall back to Composer (Composer + 1 retry). When Gemini fails normally, the second attempt uses Composer (with failure context). For tasks known to perform poorly with Gemini, use `--backend cursor`.

Command syntax: `{{AGENTS_HOME}}/delegate.sh normal -C <project-dir> --test "<verification>" [--scope "src/x/, tests/"] [--isolate NAME] "<task>"` (task prompt goes last).

### Task contract template (structure delegation prompts with these headers; omit unneeded ones)

```
Objective: <what must be true when complete>
Current behavior: <current state, referencing files/symbols if known>
Expected behavior: <expected state + critical edge cases>
Non-goals: <what should not be redesigned or changed>
File scope: <allowed files/directories — pass the same to --scope>
Constraints: <architecture/compatibility; public APIs or data to preserve>
Acceptance: <observable outcome; regressions that must not happen>
Done when: <acceptance criteria met; SUMMARY lists changed files>
```
Put verification commands in `--test`, not in the task text (the wrapper runs it and passes it to the agent).

### OUTCOME dictionary (the OUTCOME: line in summary; STATUS: for compatibility)

| OUTCOME | Meaning | Action to take |
|---|---|---|
| `success` | Agent finished, tests passed, within scope | Review (rule 5) |
| `partial` | Agent reported "partial" or omitted report block | Inspect UNRESOLVED |
| `agent_failure` | Agent reported "failed" | Automatically retried |
| `test_failure` | `--test` failed; **complete** error lines shown below summary (`  |`): full log if ≤60 lines, or all error blocks + file counts if longer | Automatically passed to next attempt; diagnose here on escalation |
| `scope_violation` | Files changed outside `--scope` (`OUT-OF-SCOPE:` list) | Next attempt reverts these first |
| `timeout` | Execution timed out (default 1200s, `-t`) | Split the task |
| `quota` | Quota/rate limit; cooldown set for Gemini | Automatically falls back to Composer |
| `auth_failure` / `cli_failure` | Missing login / CLI crash | Gemini automatically falls back to Composer; Composer exit 2 → run `{{AGENTS_HOME}}/doctor.sh` |

`TESTS(wrapper): PASS` also displays counts (`40 passed, 2 skipped`); if you see **`NO TESTS RAN`**, exit 0 proves nothing.

## Working rules

1. **Delegate first.** Do not write implementation code if a sub-agent can reasonably do it. Structure the prompt using the task contract template; clear, self-contained prompts reduce retries.
2. **Do not scan files yourself.** Use `ask.sh` for exploration; only read the few specific lines you need.
3. **Always provide verification.** Whenever possible, provide `--test` (`npm run build`, `npx tsc --noEmit`, `php artisan test`, `php -l f.php` …). Gemini (`accept-edits`) cannot run shell commands, so verification must be handled via `--test`. Specify `--scope` when files are known.
4. **Read only the summary.** Wrapper output is concise: `STATUS / OUTCOME / CHANGED / IMAGES / TESTS / SUMMARY / UNRESOLVED`. Raw output is stored under `~/.local/state/ai-agents/runs/<RUN>/`; **do not read raw logs**, inspect small slices with `tail` only when debugging an escalation.
5. **Review with minimal diff.** Run `{{AGENTS_HOME}}/diff.sh <RUN|last> --stat`, then inspect only risky files: `{{AGENTS_HOME}}/diff.sh <RUN> path/to/file`. For low-risk changes (CSS, copy, adding tests), `--stat` + test outcome is sufficient. Always perform a full review for auth, payments, data deletion, migrations, security, and public API changes.
   Your verdict must be strictly **APPROVED** or **CHANGES REQUIRED**. The sub-agent reporting `success` is not an approval. On CHANGES REQUIRED, do not write fixes yourself; send findings back: `delegate.sh <tier> --context "<file:line + expected behavior>" "<fix task>"`. Write the fix yourself only if it is a 1–2 line edit.
6. **Escalation.** `delegate.sh` exit codes: `0` success, `3` ESCALATE (all retries failed), `2` infrastructure error (auth/setup → run `{{AGENTS_HOME}}/doctor.sh`). On exit 3, examine OUTCOME + TESTS error digest + UNRESOLVED; diagnose the root cause yourself. Fix it directly if small, or re-delegate with a clearer prompt if large.
7. **Long-running tasks.** Delegations can take 5–20 minutes. If your terminal tool has a timeout, run in the background (`nohup {{AGENTS_HOME}}/delegate.sh ... > /tmp/deleg.log 2>&1 &`) and inspect summary lines when complete. If execution exceeds 15 minutes, check liveness proactively (recently modified files, `pgrep -P`, `runs/<RUN>/watchdog.log`).
8. **Parallelism.** Only one sub-agent can run in the same directory at a time (wrapper lock). For parallel work in the same **git** project or to test without touching the live tree: use `--isolate NAME` (independent scopes). Then run `{{AGENTS_HOME}}/wt.sh diff NAME --stat` → review → `wt.sh apply NAME` (`applied` | `no_changes` | `apply_conflict`) → re-run tests in main directory → `wt.sh discard NAME`. Apply multiple worktrees sequentially. Avoid parallel runs on resource-constrained systems.
9. **Deployment belongs to the orchestrator.** Sub-agents do not deploy, rsync, restart services, git commit/push, or alter system settings (enforced by contract). Release steps remain your responsibility and require user confirmation.

## Recommended practices

- **UI / visual design work is better done by the orchestrator itself** (page appearance, layout, typography, animations): sub-agents tend to produce generic designs. Delegate mechanical work (tests, backend boilerplate). Use `delegate.sh image` for image generation (icons, illustrations, hero graphics).
- **UI work: apply installed design skills** (`~/.agents/skills`: `impeccable`, `design-taste-frontend`, `high-end-visual-design`, `emil-design-eng`, `animate`/`review-animations`, `mobile-native`, `break-ui`). After UI modifications, take **1440px and 390px** Playwright screenshots of changed pages and review them for visual hierarchy, spacing, typography, contrast, and mobile overflow.
- **Process management:** Never kill processes with broad patterns (`pkill -f next`); only kill PIDs you started. Do not leave dev servers in the foreground.

## Wrapper reference

- `{{AGENTS_HOME}}/run-agent.sh <cursor|gemini> [-C DIR] [-m MODEL] [-t SEC] [--test CMD] [--scope LIST] [--isolate NAME] [--context TXT] [--ask] [--shell] "task"` — single attempt (`cursor.sh` / `gemini.sh` shortcuts).
- `{{AGENTS_HOME}}/doctor.sh` — environment, auth, and dependency check; displays tier models and active worktrees.
- `{{AGENTS_HOME}}/watchdog.sh` — runs automatically on each execution: terminates stale foreground server/watch processes (>7m), logs STALL if no files change for 15m. Displayed in summary as `WATCHDOG:`.
- `{{AGENTS_HOME}}/wt.sh ensure|diff|apply|discard|list` — isolated worktree management (`~/.local/state/ai-agents/worktrees/`).
- Model configuration: `{{AGENTS_HOME}}/config.sh` or `~/.config/ai-agents/env` (`GEMINI_MODEL_SIMPLE|NORMAL|COMPLEX|IMAGE`, `CURSOR_MODEL`; list models via `agy models`, `agent --list-models`).
- Change tracking does not require git (shadow git: `~/.local/state/ai-agents/shadow/`); `.env`, images, `node_modules`, and `vendor` are ignored (`{{AGENTS_HOME}}/shadow-exclude`); new images appear on the `IMAGES:` line.
- When modifying wrappers: run `bash {{AGENTS_HOME}}/tests/run.sh` (mock agents, offline).
