# AI Orchestration — Setup and User Guide

The expensive model **decides**, cheap models **write code**. This document covers the entire system: architecture, OS-neutral installation (Linux, macOS, and **Windows WSL2 + Cursor**), daily usage, outcome dictionary, and troubleshooting. The repository includes all wrapper scripts, rules, and configuration templates.

---

## 1. What does it do?

```
User
   │
   ▼
Orchestrator (expensive model: selected model in Cursor / Claude Code)
   │  plan + task contract (Objective / Scope / Acceptance …)
   ▼
delegate.sh ──► Gemini (agy, subscription quota) ──failure/quota──► Composer (Cursor CLI) ──► ESCALATE (orchestrator takes over)
   │                 │                                                    │
   │                 └──────────── run-agent.sh: snapshot → agent → snapshot → --test → --scope check → summary
   ▼
Summary (≈15 lines): STATUS / OUTCOME / CHANGED / IMAGES / TESTS(+error digest) / SUMMARY / UNRESOLVED
   │
   ▼
Orchestrator review: APPROVED  |  CHANGES REQUIRED → returned via same path with --context "findings"
```

- **The orchestrator model** handles architecture, task definitions, code review, and final decisions; it does not write code directly (except 1–2 line fixes).
- **Gemini** (Antigravity CLI `agy`, your Google account / Gemini subscription quota) is the primary choice at every level: the most cost-effective path via subscription quota. It is also the only sub-agent capable of generating images.
- **Composer** (Cursor CLI `agent`) takes over when Gemini quota is exhausted, on login/CLI failures, or when Gemini fails the task.
- **Wrappers** (bash + python3) run sub-agents headless, track changes, run tests independently, categorize outcomes, and report a concise summary back to the orchestrator model. Raw logs remain on disk and never pollute the expensive orchestrator's context window.

### Why this architecture (design decisions)

| Decision | Rationale |
|---|---|
| Wrapper runs tests, not the agent | An agent might falsely report "tests passed"; the wrapper runs verification independently. Running tests in the orchestrator model would produce the same result but consume expensive context window tokens. |
| Full error lines included on test failure | Both the orchestrator model and the next attempt see the exact root cause; this increases recovery chance on retry and minimizes expensive escalations. Includes the complete log if ≤60 lines, or all error blocks if longer (safety cap: 150 blocks + file-based count). |
| Shadow git | Change tracking does not require a git repository; diff and review work even in non-git directories. |
| `--isolate` worktrees cloned from *current* state | Uncommitted changes, untracked files, and `.env` are copied; `node_modules`/`vendor` are symlinked → the agent sees real code, and tests run cleanly in the worktree. |
| Bash wrapper instead of MCP bridge | MCP does not reduce tokens (tool definitions add overhead to every session) and blocks the orchestrator model during calls; bash allows background execution and simple process debugging. |
| Automatic tiering + escalation | The orchestrator model does not need to choose fallback models; the wrapper automatically transitions based on quota and error conditions. |

---

## 2. File map

| File | Role |
|---|---|
| `delegate.sh` | Routing: tier (`simple`/`normal`/`complex`/`image`) → Gemini → Composer → ESCALATE |
| `run-agent.sh` | Single agent run: injects contract, snapshots state, executes agent, test/scope checks, OUTCOME classification, summary |
| `lib.sh` | Shared functions: sub-agent contract, shadow git, outcome parsing, scope check, quota/auth classification, macOS GNU tool path |
| `testdigest.py` | Test log digest (pass: counts/skips; fail: error lines) |
| `wt.sh` | Isolated git worktrees: ensure / diff / apply / discard / list |
| `watchdog.sh` | Automatic on each run: terminates foreground dev servers, STALL warning |
| `ask.sh` | Read-only codebase query (Gemini → Composer), ≤3000 character response |
| `diff.sh` | Changes from a run (`--stat` or per-file) |
| `doctor.sh` | Environment, auth, and dependency check (`--deps`: local tools only) |
| `config.sh` | Default models |
| `resolve-model.sh` | Resolves latest `composer*` model (cached for 1 day) |
| `cursor.sh`, `gemini.sh` | Single-attempt shortcuts |
| `shadow-exclude` | Patterns ignored in change tracking (`node_modules`, images, `.env`, etc.) |
| `install.sh` | Installation script + writes Cursor/Claude Code rule files |
| `templates/RULES.md` | Orchestrator rules (source for Cursor rule / CLAUDE.md block) |
| `templates/agy-settings.example.json` | Gemini (`agy`) command allow/deny list |
| `templates/env.example` | Template for `~/.config/ai-agents/env` |
| `tests/run.sh`, `tests/stubs/*` | Wrapper test suite (mock agents, offline, ~15s) |

State directory: `~/.local/state/ai-agents/` → `runs/<RUN>/` (prompt, raw output, test.log, summary), `shadow/`, `worktrees/`, `gemini-cooldown`.

---

## 3. Installation

### 3.1 Requirements

The wrappers are written in bash and rely on GNU utilities (`flock`, `rsync`, GNU `find`/`sed`/`stat`, `/proc`).

| OS | Requirements | Notes |
|---|---|---|
| Linux | `bash`, `coreutils`, `findutils`, `git`, `python3`, `rsync`, `util-linux`, `curl`, `unzip` | Native support on Ubuntu/Debian and other distributions. |
| macOS | `brew install bash coreutils findutils gnu-sed flock rsync python3` | `lib.sh` automatically prepends Homebrew GNU tools to PATH. |
| Windows | WSL2 (Ubuntu) required | Native PowerShell and Git Bash are not supported due to missing `flock`, `rsync`, and `/proc`. Everything runs inside WSL2. |

### 3.2 Windows: WSL2 setup

```
Windows
 ├─ Cursor IDE (Windows app)      ──"Connect to WSL"──┐
 └─ WSL2: Ubuntu                                      │
     ├─ ~/code/<projects>        ◄── Cursor opens here┘ (terminal = bash)
     ├─ ~/.ai-agents/            wrappers
     ├─ ~/.local/bin/agy         Gemini (Antigravity CLI)
     └─ ~/.local/bin/agent       Composer (Cursor CLI)
```

Open PowerShell as **Administrator**:
```powershell
wsl --install -d Ubuntu
```

Restart your computer → Open **Ubuntu** from the Start menu → Create your Linux username and password. Then, in the Ubuntu terminal:
```bash
sudo apt update && sudo apt install -y git python3 rsync util-linux coreutils findutils curl unzip wslu
git config --global core.autocrlf input      # prevent Windows CRLF from entering repositories
mkdir -p ~/code
```
`wslu` provides the `wslview` command, which opens the Windows browser from inside WSL (needed for CLI browser logins).

> **Keep projects in the WSL filesystem** (`~/code/...`), NOT under `C:\` (`/mnt/c/...`): accessing files across `/mnt/c` makes git, npm, and agent execution extremely slow, and causes file permission and line ending issues. To migrate an existing project: `git clone <repo> ~/code/project` or `rsync -a /mnt/c/Users/<USER>/projects/project ~/code/`. You can access WSL files from Windows Explorer at `\\wsl$\Ubuntu\home\<user>\code`.

**Connect Cursor to WSL:**
1. In Cursor, press `Ctrl+Shift+P` → **"WSL: Connect to WSL"** (if not installed, install the **WSL** extension by Anysphere from Extensions).
2. The bottom-left corner should display **"WSL: Ubuntu"**. Select **File → Open Folder** → `/home/<user>/code/project`.
   Shortcut: In the Ubuntu terminal, run `cd ~/code/project && cursor .`.
3. Verification: Open a terminal inside Cursor → `uname -a` should output `Linux … microsoft-standard-WSL2`. If PowerShell opens, the project is not in WSL mode and rules will not function.

**CRLF line ending note:**
Perform all setup steps inside the Ubuntu terminal. Files created or edited on Windows may have CRLF line endings that break bash scripts.
If you see `$'\r': command not found`, run:
```bash
sed -i 's/\r$//' ~/ai-agents-src/install.sh
```
Then run `install.sh`; it normalizes remaining files automatically.

### 3.3 Get the files

Perform these steps in your terminal (inside Ubuntu on Windows):

**a) From archive:** If `ai-agents.tar.gz` is in your Downloads folder:
```bash
# Windows / WSL:
mkdir -p ~/ai-agents-src && tar -xzf /mnt/c/Users/<USER>/Downloads/ai-agents.tar.gz -C ~/ai-agents-src

# Linux / macOS:
mkdir -p ~/ai-agents-src && tar -xzf ~/Downloads/ai-agents.tar.gz -C ~/ai-agents-src
```

**b) Extract from single-file AI-ORCHESTRATION.md** (if no archive is available): Save the file as `AI-ORCHESTRATION.md` in Downloads, then run:
```bash
mkdir -p ~/ai-agents-src && python3 - /mnt/c/Users/<USER>/Downloads/AI-ORCHESTRATION.md ~/ai-agents-src <<'EXTRACT'
import os, re, sys
md, out = sys.argv[1], os.path.expanduser(sys.argv[2])
rx = re.compile(r'<!-- file: (\S+) mode: (\d+) -->\n(~{6,})[^\n]*\n(.*?)\n\3\n', re.S)
n = 0
for path, mode, _, body in rx.findall(open(md, encoding='utf-8').read()):   # text mode: CRLF -> LF
    p = os.path.join(out, path); os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, 'w', encoding='utf-8', newline='\n').write(body + '\n'); os.chmod(p, int(mode, 8)); n += 1
print(f'{n} files -> {out}')
EXTRACT
```

**c) From Git:**
```bash
git clone https://github.com/<owner>/ai-orchestration-agents ~/ai-agents-src
```

### 3.4 Install the sub-agent CLIs and log in

```bash
# Gemini — Antigravity CLI, Google account (quota depends on your Google account / Gemini subscription quota)
curl -fsSL https://antigravity.google/cli/install.sh | bash
agy            # open interactively once -> sign in with Google -> exit (Ctrl+C)
agy models     # gemini-3.8-flash-* should be listed

# Composer — Cursor CLI, Cursor account
curl https://cursor.com/install -fsS | bash
NO_OPEN_BROWSER=1 agent login     # open the printed link in your browser (or: wslview <link>)
agent --list-models | grep -i composer
```
Both CLIs are installed into `~/.local/bin`; the wrappers automatically add this directory to PATH. On Windows/WSL, logging into the Cursor desktop application on the Windows side does not authenticate the WSL `agent` CLI; you must log in via the CLI directly.

### 3.5 install.sh

```bash
cd ~/ai-agents-src
./install.sh --dry-run --project ~/code/project --cursor --agy-perms ~/code   # preview actions
./install.sh           --project ~/code/project --cursor --agy-perms ~/code
```

| Option | Description |
|---|---|
| `--prefix DIR` | Where wrappers are installed (default: `~/.ai-agents`) |
| `--project DIR` | Project directory where rules will be written (repeatable; WSL path on Windows) |
| `--cursor` | Writes `DIR/.cursor/rules/ai-orchestration.mdc` (`alwaysApply: true`) |
| `--claude` | Adds or updates the marked block in `DIR/CLAUDE.md` (does not touch external text) |
| `--claude-global` | Writes the same block to `~/.claude/CLAUDE.md` (for global Claude Code use) |
| `--agy-perms DIR` | Writes command allow/deny list to `~/.gemini/antigravity-cli/settings.json`; grants file access to `DIR` and `/tmp` (skipped if `permissions` already exists) |
| `--dry-run` | Shows what would be changed without modifying any files |

Re-running `install.sh` is safe: rule blocks are refreshed, user-authored text is preserved, older manual `.mdc` files are backed up as `.bak`, CRLF line endings are converted to LF, and any existing `~/.config/ai-agents/env` is preserved. When adding new projects later: `~/.ai-agents/install.sh --project ~/code/new-project --cursor`.

### 3.6 Cursor setup

- **Project rules:** Running with `--project <dir> --cursor` writes `.cursor/rules/ai-orchestration.mdc` (`alwaysApply: true`). The Cursor agent loads these instructions automatically in every conversation.
- **Global rules (optional):** In Cursor Settings → Rules → **User Rules**, paste the output of:
  `sed "s#{{AGENTS_HOME}}#$HOME/.ai-agents#g" ~/.ai-agents/templates/RULES.md`
  Note that User Rules also apply to projects opened outside WSL where the bash commands will not run; for this reason, per-project rules are recommended.
- **Orchestrator model:** Select a capable orchestrator model (such as Claude Sonnet or GPT-5 class). Do not select Composer as the orchestrator; Composer is meant to serve as a sub-agent.
- **Long commands:** Delegation tasks may run for 5–20 minutes. If Cursor's terminal tool has a timeout:
  `nohup ~/.ai-agents/delegate.sh normal -C . --test "npm run build" "..." > /tmp/deleg.log 2>&1 &` → when complete, view the summary with `tail -40 /tmp/deleg.log`.
- **Cost awareness:** The orchestrator model in Cursor and the Composer fallback consume your Cursor account quota; Gemini consumes your Google account / Gemini subscription quota. Routing always attempts Gemini first to keep costs down.

### 3.7 Claude Code setup

- Run `./install.sh --claude --project <dir>` to insert or update the rule block inside `<dir>/CLAUDE.md`.
- Use `--claude-global` to write the rules into `~/.claude/CLAUDE.md` for global availability across all projects.
- For long delegations, execute them in the background (`nohup ~/.ai-agents/delegate.sh ... > /tmp/deleg.log 2>&1 &`) and inspect the summary log upon completion.

### 3.8 UI skills and Playwright (optional)

Node.js is required (e.g. `sudo apt install -y nodejs npm` or via nvm). Then install:
```bash
npx skills add -g pbakaus/impeccable
npx skills add -g Leonxlnx/taste-skill
npx skills add -g emilkowalski/skill
npx skills update -g -y                          # update skills
npx playwright install --with-deps chromium      # for 1440px / 390px screenshot checks
```
Skills are installed into `~/.agents/skills` and are accessible to Cursor (in WSL mode), Claude Code, and `agy`. If the `impeccable` detector is present, the sub-agent contract runs it automatically during UI tasks.

### 3.9 Verify

```bash
~/.ai-agents/doctor.sh --deps        # local tools check
~/.ai-agents/doctor.sh               # + checks Cursor and Gemini logins (sends 1 short probe to Gemini)
bash ~/.ai-agents/tests/run.sh       # 11 tests, offline -> "11 passed, 0 failed"
```

First real test run (in a git project, isolated — does not touch your working tree):
```bash
~/.ai-agents/delegate.sh simple -C ~/code/project --isolate first-run --scope "README.md" \
  "Objective: Add a 3-line 'Development' section to the end of README.md (setup + test commands). Non-goals: other files. Done when: section added."
~/.ai-agents/wt.sh diff first-run --stat && ~/.ai-agents/wt.sh discard first-run
```
Then in Cursor (with the project opened in WSL mode), give the agent a regular task; it should invoke `delegate.sh` automatically.

---

## 4. Usage

### 4.1 Tiers

| Tier | First attempt | Fallback | Intended for |
|---|---|---|---|
| `simple` | Gemini flash-medium | Composer | boilerplate, writing tests, CSS, small fixes, text/translations |
| `normal` | Gemini flash-high | Composer | standard development, refactoring, multi-file changes |
| `complex` | Gemini flash-high + "plan first" | Composer | large implementations after the plan is solidified |
| `image` | Gemini (image tool) | **none** (Gemini retry) | icons, illustrations, hero/OG images |

Execution flow details:
- Gemini succeeds → finished.
- Gemini returns `quota` / `auth_failure` / `cli_failure` → falls back to Composer, followed by a Composer retry (both receiving the prior report).
- Gemini standard failure (`test_failure`, `agent_failure`, `scope_violation`, etc.) → falls back to Composer, passing the previous report and **full error digest**.
- If Gemini is in cooldown (written when quota is exhausted: 6 hours for daily quota, 10 minutes for 429 rate limit, 15 minutes for 503 service unavailable), execution bypasses Gemini and goes directly to Composer.
- `image`: on cooldown or when Gemini is unreachable, immediately triggers ESCALATE (Composer cannot generate images).
- `--backend cursor`: bypasses Gemini and invokes Composer directly.

### 4.2 Commands

```bash
A=~/.ai-agents
# Code task
$A/delegate.sh normal -C ~/code/app --test "npx tsc --noEmit && npm test" --scope "src/cart/, tests/cart/" - <<'EOF'
Objective: When the same product is added to the cart twice, increment quantity instead of adding a new row.
Current behavior: src/cart/store.ts addItem adds a new row on every call.
Expected behavior: same productId+variant → quantity += n; different variant → new row.
Non-goals: cart UI, price calculations.
File scope: src/cart/, tests/cart/
Acceptance: Two tests added to tests/cart/store.test.ts and passing; existing tests pass.
Done when: SUMMARY lists changed files.
EOF

# Image generation
$A/delegate.sh image -C ~/code/site --scope "public/img/" "public/img/hero.webp: 1600x900, warm tones, modern clean desk setup, clean background, no text."

# Question (read-only)
$A/ask.sh -C ~/code/app "Where is the payment webhook verified? file:line"

# Review
$A/diff.sh last --stat
$A/diff.sh last src/cart/store.ts

# Revision round (CHANGES REQUIRED)
$A/delegate.sh normal -C ~/code/app --test "npm test" --context "src/cart/store.ts:42 crashes when variant is null; null must be treated as default variant" "Fix the reported issue."

# Two parallel tasks in the same project
$A/delegate.sh simple -C ~/code/app --isolate i18n --scope "locales/" "..." &
$A/delegate.sh simple -C ~/code/app --isolate docs --scope "docs/" "..." &
wait
$A/wt.sh diff i18n --stat; $A/wt.sh apply i18n; (cd ~/code/app && npm test); $A/wt.sh discard i18n
$A/wt.sh diff docs --stat; $A/wt.sh apply docs; $A/wt.sh discard docs
```

Task text can also be passed via stdin using `-` (recommended for multi-line contracts).

### 4.3 Summary format

```
=== [1: normal] gemini ===
RUN: 20261015-114748-gemini-6c0f7c (gemini/gemini-3.8-flash-high, 455s)
STATUS: failed
OUTCOME: test_failure
CHANGED: 2 files, +48/-6
  M	src/cart/store.ts
  A	tests/cart/store.test.ts
TESTS(wrapper): FAIL rc=1 (npx tsc --noEmit && npm test)
  full log (9 lines, noise frames dropped):
  | src/cart/store.ts(42,17): error TS2532: Object is possibly 'undefined'.
  | ...
  (full log: ~/.local/state/ai-agents/runs/…/test.log)
TESTS(agent): not run
SUMMARY: ...
UNRESOLVED: none
DIFF: ~/.ai-agents/diff.sh 20261015-114748-gemini-6c0f7c [--stat|FILE]
=== [2: escalated to cursor] cursor ===
...
```

Additional lines: `IMAGES:` (new or modified images), `OUT-OF-SCOPE:` (files modified outside scope), `WATCHDOG:` (terminated processes / STALL warnings), `WORKTREE:` (isolated execution).

### 4.4 OUTCOME dictionary

| OUTCOME | Meaning | What delegate.sh does | What you do |
|---|---|---|---|
| `success` | Agent finished, tests passed, within scope | Stops, exit 0 | Review |
| `partial` | Agent reported "partial" or omitted report block | Proceeds to next attempt | Inspect UNRESOLVED |
| `agent_failure` | Agent reported "failed" | Proceeds to next attempt | — |
| `test_failure` | `--test` command failed | Retries with error digest | Diagnose on escalation |
| `scope_violation` | Files modified outside `--scope` | Next attempt reverts changes first | — |
| `timeout` | Execution timed out (default 1200s, `-t`) | Proceeds to next attempt | Split the task |
| `quota` | Quota exhausted / rate limit / 503 | Sets Gemini cooldown + tries Composer | — |
| `auth_failure` | Not logged in | Gemini→Composer; on Composer exit 2 | Run `doctor.sh`, log in |
| `cli_failure` | CLI crashed or produced no output | Gemini→Composer | Check `runs/<RUN>/stderr.log` |

`wt.sh apply` results: `applied` / `no_changes` / `apply_conflict` (main working tree modified or patch already applied) / `apply_error`.

Exit codes: `0` success · `3` ESCALATE · `2` infrastructure error.

### 4.5 Sub-agent contract (injected automatically into every task)

- Make changes strictly inside the working directory, keeping modifications minimal and adhering to existing style.
- **NEVER:** deploy, rsync, restart services, git commit/push, edit `/etc`, install global packages, run prod DB migrations/drops, or delete user data.
- Never run dev/preview servers in the foreground (start in the background, terminate via PID when finished; never `pkill -f`).
- If `--scope` is specified: modify only matching paths; list any other required changes under UNRESOLVED.
- Gemini (`accept-edits` mode): do not run shell commands — a rejected command aborts the session; verification is handled by the wrapper.
- If `--test` is specified, the command is communicated to the sub-agent.
- For UI tasks: consult installed design skills, capture Playwright 1440px and 390px screenshots, and run `impeccable detect` (if available).
- Final response must consist ONLY of the `STATUS / SUMMARY / TESTS / UNRESOLVED` block.

---

## 5. Configuration

Configured via `~/.config/ai-agents/env` (generated from template during installation) or `config.sh`:

| Variable | Default | Notes |
|---|---|---|
| `GEMINI_MODEL_SIMPLE` | `gemini-3.8-flash-medium` | Available models via `agy models` |
| `GEMINI_MODEL_NORMAL` / `_COMPLEX` | `gemini-3.8-flash-high` | |
| `GEMINI_MODEL_IMAGE` | `gemini-3.8-flash-medium` | Chat model orchestrating the image generation tool |
| `GEMINI_MODEL` | `gemini-3.8-flash-medium` | Used by `ask.sh` / `gemini.sh` |
| `CURSOR_MODEL` | empty = latest `composer*` | |
| `GEMINI_CLI` | `agy` | `gemini` = legacy Gemini CLI + API key |
| `IMPECCABLE_BIN` | auto | |
| `AI_AGENTS_STATE` | `~/.local/state/ai-agents` | |
| `TEST_DIGEST_MAX` | 150 | Max error lines shown from long logs |
| `WATCHDOG_MAX_AGE` / `WATCHDOG_STALL_MIN` | 420s / 15m | |

Timeouts: agent 1200s (`-t`), `--test` 900s, ask 600s.

**agy permissions** (`~/.gemini/antigravity-cli/settings.json`): In headless mode, commands not present on the allowlist are rejected. By default, Gemini operates in `accept-edits` (file editing only) mode; for rare tasks that require shell access, pass `--shell` (enables full shell permissions — use caution). The denylist blocks `sudo`, `rsync`, `ssh`, `git push/commit`, `curl`, editing `.env`, etc.

---

## 6. Troubleshooting

| Symptom | Cause / Solution |
|---|---|
| Gemini "agent stopped with no output" / `UNRESOLVED: permission-denied tools` | A shell command was rejected (e.g. prefix commands like `cd ... &&`, `PATH=... npx` do not match the allowlist). Do not include commands in task instructions; specify verification via `--test`. If shell execution is strictly required, use `--shell`. |
| Always routing to Composer | Check `doctor.sh` → `gemini: COOLDOWN until ...` or auth error. To clear cooldown early: `rm ~/.local/state/ai-agents/gemini-cooldown`. |
| Delegation silent for 15+ minutes | Check `runs/<RUN>/watchdog.log` (STALL/KILLED). Find recently modified files: `find <project> -newer ~/.local/state/ai-agents/runs/<RUN>/prompt.txt -type f \| head`. Check agent child processes: `pgrep -P <pid>`. |
| `workspace busy` | Another run holds the lock on the same directory. Wait for it to finish or run with `--isolate`. |
| `apply_conflict` | The main repository branch changed on the same lines after the worktree was created. Discard with `wt.sh discard NAME` and re-delegate against current code, or resolve the patch manually (`~/.local/state/ai-agents/worktrees/NAME.patch`). |
| `--isolate needs a git repository` / `use the repo root` | Isolation only works within git repositories and `-C` must point to the repository root. |
| `NO TESTS RAN` | Test command exited with code 0 without executing any tests; verify your test command. |
| `$'\r': command not found`, `/usr/bin/env: 'bash\r'` | CRLF line endings (files were created or cloned on the Windows side). Run `sed -i 's/\r$//' ~/ai-agents-src/install.sh`, then re-run `install.sh`. |
| Cursor agent runs commands in PowerShell / `delegate.sh` not found | Project is not opened in WSL mode. Press `Ctrl+Shift+P` → "WSL: Connect to WSL" → open the folder via `/home/...`. |
| Everything is slow, `git status` takes seconds | Project is located under `/mnt/c/...`. Move it to the native WSL filesystem (`~/code`). |
| `agy` / `agent login` does not open browser | Install `wslu` (`sudo apt install wslu`) → open link with `wslview <link>` or paste it into your browser manually. |
| WSL clock drifted → strange cooldown times, TLS errors | Run `sudo hwclock -s`, or in PowerShell run `wsl --shutdown` and restart Ubuntu. |
| WSL consumes excessive RAM / OOM | Create `C:\Users\<USER>\.wslconfig` with `[wsl2]` `memory=8GB` (adjust for your system); run `wsl --shutdown`. Avoid running multiple heavy tasks concurrently (build + agent + browser). |
| Playwright Chromium fails to launch | Run `npx playwright install --with-deps chromium` inside WSL or your system. |
| macOS: `stat: illegal option -c`, `flock: command not found` | Run `brew install bash coreutils findutils gnu-sed flock rsync`; verify with `doctor.sh --deps`. |
| Modified a wrapper script | Run `bash ~/.ai-agents/tests/run.sh` — 11/11 tests must pass. |
