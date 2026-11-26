# SETUP — instructions for an AI agent

You are an AI coding agent (Claude Code, Cursor, …) and the user asked you to set up this orchestration
on the current machine ("look at this repo and set it up"). Follow these steps in order. Run every command
yourself; only the logins in step 3 need the user. Report each step as done / blocked (with the reason).

**Standard profile** (use it unless the user says otherwise):

```
orchestrator (you) ──► Gemini (agy) ──out of quota / fails──► Sonnet (Claude Code CLI) ──► ESCALATE back to you
image tasks: Gemini only        Cursor: not used (DISABLE_CURSOR=1)
```

## 1. Platform and dependencies

- Linux or WSL2: fine. macOS: `brew install bash coreutils findutils gnu-sed flock rsync python3`.
  Native Windows (PowerShell): stop and tell the user to use WSL2 (see docs/GUIDE.md §3).
- Check: `bash --version` (≥ 4), `git`, `python3`, `rsync`, `flock`. Install what is missing with the
  system package manager (ask the user before using sudo).

## 2. Get the code and install the CLIs

```bash
git clone https://github.com/hakan-gul/ai-orchestration-agents ~/ai-agents-src   # or: cd ~/ai-agents-src && git pull
command -v agy    || curl -fsSL https://antigravity.google/cli/install.sh | bash     # Gemini (Google account)
command -v claude || curl -fsSL https://claude.ai/install.sh | bash                 # fallback: Sonnet (Claude account)
```

Both land in `~/.local/bin` (the wrappers add it to PATH themselves).

## 3. Logins (the user does these once, interactively)

Check first, so you only ask for what is missing:

```bash
cd /tmp && agy -p 'Reply with exactly: pong' --output-format json | grep -q pong && echo "agy ok"
echo 'Reply with exactly: pong' | claude -p --output-format json | grep -q pong && echo "claude ok"
```

If one fails, ask the user to run it in a terminal and sign in, then come back:
- `agy` → sign in with Google → Ctrl+C
- `claude` → `/login` → exit

If you are running inside Claude Code yourself, `claude` is usually already logged in.

## 4. Install the wrappers and the rules

```bash
cd ~/ai-agents-src
./install.sh --fallback claude --claude-global --agy-perms ~/code     # ~/code = the user's projects folder
grep -q '^DISABLE_CURSOR=' ~/.config/ai-agents/env || echo 'DISABLE_CURSOR=1' >> ~/.config/ai-agents/env
```

- Wrappers go to `~/.ai-agents`; settings live in `~/.config/ai-agents/env` (kept on re-install; `--fallback`
  only rewrites the `FALLBACK_BACKEND` line).
- `--claude-global` puts the orchestrator rules into `~/.claude/CLAUDE.md` (a marked block; the user's own
  text is untouched). Ask which projects folder to use for `--agy-perms` if `~/code` does not exist.
- Cursor as the orchestrator: add `--project <dir> --cursor` per project (writes `.cursor/rules/…mdc`), or
  paste `sed "s#{{AGENTS_HOME}}#$HOME/.ai-agents#g" ~/.ai-agents/templates/RULES.md` into Cursor → Settings
  → Rules → User Rules.

## 5. Verify

```bash
bash ~/.ai-agents/tests/run.sh      # self-test, no network, ~20 s: all must pass
~/.ai-agents/doctor.sh              # logins + routing; expect "fallback: claude" and "doctor: ALL OK"
```

Optional smoke test with real agents in a scratch dir:

```bash
mkdir -p /tmp/ai-smoke && cd /tmp/ai-smoke && printf 'module.exports=(a,b)=>a-b\n' > add.js
~/.ai-agents/delegate.sh simple -C /tmp/ai-smoke --scope add.js \
  --test "node -e 'process.exit(require(\"./add.js\")(2,3)===5?0:1)'" "Objective: add.js must return a+b."
```

Expect `OUTCOME: success`. To test the Sonnet path directly: `~/.ai-agents/claude.sh -C /tmp/ai-smoke "…"`.

## 6. Tell the user

One short report: which steps passed, what is blocked (missing login, missing sudo, …), and where the
settings are (`~/.config/ai-agents/env`: `FALLBACK_BACKEND`, `CLAUDE_MODEL`, `DISABLE_CURSOR`,
`GEMINI_MODEL_*`). Updating later is the same as installing: `cd ~/ai-agents-src && git pull && ./install.sh
--fallback claude --claude-global`.

## Notes

- Ephemeral cloud sandboxes (e.g. Claude Code on the web) lose logins when the container is recycled;
  there `agy` usually cannot sign in. Use `FALLBACK_BACKEND=claude` and accept that tasks start on Sonnet
  (`delegate.sh … --backend claude`), or skip the setup.
- Sub-agents never deploy, push or restart services; that stays with the orchestrator and the user.
- Full reference: [docs/GUIDE.md](docs/GUIDE.md).
