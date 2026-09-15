---
name: junie
description: "Delegate a coding goal to the JetBrains Junie CLI."
version: 1.0.0
author: Alexander Prendota (@AlexanderPrendota) + Hermes Agent
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [Coding-Agent, Junie, JetBrains, Plan-Mode, Code-Review, PTY, Automation]
    related_skills: [claude-code, codex, hermes-agent, opencode]
---

# Junie Skill

Hands a coding *goal* to [JetBrains Junie](https://junie.jetbrains.com/docs/junie-cli.html) — JetBrains' autonomous, LLM-agnostic coding agent CLI — and reads back the result. Junie brings its own harness (plan mode, code review, orchestrated sub-agents), so you describe the outcome, not the steps.

This skill does **not** drive Junie step by step, does not replace `patch` / `terminal` for small edits, and is not the `junie-acp` provider — see `## Pitfalls` for that distinction.

## When to Use

- A self-contained coding task worth delegating whole: a bug fix, a feature, a refactor across several files.
- You want a plan before any edit lands (`--plan`) on a risky or large change.
- You want a second agent to review a diff (`--review`).
- **Not** for one-line edits or for reading code — `patch`, `read_file` and `search_files` are cheaper and immediate.

## Prerequisites

- **Install:** `curl -fsSL https://junie.jetbrains.com/install.sh | bash` (EAP: `install-eap.sh`; PowerShell on Windows). The binary lands at `~/.local/bin/junie`; check with `junie --version`.
- **Auth, pick one:**
  - JetBrains/Junie token: `JUNIE_API_KEY='perm-...'` in the environment (generate at https://junie.jetbrains.com/tokens), or pass `--auth "$JUNIE_API_KEY"`.
  - Interactive login: run `junie` once and sign in on the Account screen.
  - BYOK: `--openai-api-key`, `--anthropic-api-key`, `--google-api-key`, `--grok-api-key`, `--openrouter-api-key`, or a LiteLLM proxy (`--litellm-url` + `--litellm-api-key`).
- **`tmux`** — only for the interactive mode in `## Procedure`.

## How to Run

Headless is the default. Use the `terminal` tool with `workdir` set to the target project:

```
terminal(
  command="junie --skip-update-check --output-format json --json-output-file result.json 'Add error handling to all API calls in src/'",
  workdir="/path/to/project",
  timeout=180,
)
```

Then read the outcome with `read_file` on `result.json` — do not scrape the terminal text.

## Quick Reference

| Flag | Meaning |
|---|---|
| *(positional)* / `--task "..."` | the task itself; there is no print flag |
| `--output-format text\|json\|json-stream` | prefer `json` with `--json-output-file` |
| `-p, --project <dir>` | project dir — `-p` is **project**, not print |
| `--plan` | read-only analysis proposing a plan before edits |
| `--review` | reviews a git diff (needs a git repo) |
| `--goal "..."` | multi-step run across sub-agents; CLI/TUI only |
| `--model <id>`, `--effort low\|medium\|high` | e.g. `claude-opus-4-8`, `gemini-3-flash-preview` |
| `--brave` | execute commands without asking (interactive) |
| `--resume`, `--session-id <id>` | continue the last / a specific session |
| `--skip-update-check` | always set this in automation |

MCP: Junie is an MCP client — servers go in `.junie/mcp/mcp.json` (project) or `~/.junie/mcp/mcp.json` (user), and `/mcp` lists them. Its skills, commands and guidelines are user-authored under `~/.junie/` and `.junie/`; it does not create skills or persist memory across CLI sessions.

## Procedure

1. Confirm the CLI and auth: `junie --version` via `terminal`.
2. For a risky or large change, run with `--plan` first and read the proposed plan.
3. Run the task headless with `--output-format json --json-output-file result.json` and a `timeout` that fits the work (start at 180s).
4. Read `result.json` with `read_file`; on failure the JSON carries the reason.
5. Inspect what actually changed — `search_files`, `read_file`, and `git diff` via `terminal` — before reporting success.
6. Multi-turn work only: drive an interactive session through tmux.

```
terminal(command="tmux new-session -d -s junie-work -x 140 -y 40")
terminal(command="tmux send-keys -t junie-work 'cd /path/to/project && junie' Enter")
terminal(command="sleep 6 && tmux send-keys -t junie-work 'Refactor the auth module to use JWT' Enter")
terminal(command="sleep 15 && tmux capture-pane -t junie-work -p -S -60")
terminal(command="tmux send-keys -t junie-work '/exit' Enter")
```

Interactive mode is what unlocks Junie's slash commands (`/plan`, `/review`, `/usage`).

## Pitfalls

- **This skill vs the `junie-acp` provider.** Here Hermes drives the `junie` CLI as a tool. On the provider, Junie *is* the backend driving Hermes: it does the coding with its own tools while Hermes keeps its agent-level tools (memory, todo, skills) over an ACP text bridge, so the self-improvement loop keeps working. Provider settings live under `junie_acp:` in `config.yaml`, where `forwarded_tools` widens or narrows that set. The background review inherits the provider by default, which spawns an extra Junie session per review — route it elsewhere with `auxiliary.background_review.{provider,model}`.
- **ANSI in text output.** Plain `text` output carries color codes; prefer `json` + `--json-output-file` in automation.
- **Cold start.** The first invocation pays a JVM/agent startup cost of several seconds. An interactive tmux session reuses the process across turns.
- **Auth in automation.** Headless runs never open a browser login — pass `--auth "$JUNIE_API_KEY"` or make sure the variable is in the process environment.
- **`--goal` is CLI/TUI only** and does not behave the same in a headless JSON pipeline; for scripted use prefer a plain task or `--plan`.
- **`-p` is `--project`.** Non-interactive is simply the positional task.

## Verification

- `junie --version` returns a version.
- `result.json` exists and reports success.
- The change is real: `git diff --stat` via `terminal` shows the expected files, and the project's own tests pass.
