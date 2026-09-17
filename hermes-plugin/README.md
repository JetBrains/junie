# Junie for Hermes Agent

Run Junie as a model provider inside [Hermes Agent](https://github.com/NousResearch/hermes-agent).

Hermes spawns `junie --acp=true` and talks to it over the [Agent Client Protocol](https://agentclientprotocol.com/), so Junie shows up in `/model` and `--provider` like any other backend — while still running its own tools inside its own session.

This is a Hermes **plugin**, not a fork: installing it changes nothing in Hermes itself.

## Install

You need the Junie CLI first — follow the [quickstart](https://junie.jetbrains.com/docs/junie-cli.html#step-1-install-junie-cli), or the install instructions in this repository's [README](../README.md). Verify with `junie --version`.

Then authenticate — a JetBrains account, a [Junie API key](https://junie.jetbrains.com/cli), or your own model provider (BYOK). See the [authentication docs](https://junie.jetbrains.com/docs/junie-cli.html#step-3-authenticate).

Install the plugin:

```bash
hermes plugins install JetBrains/junie/hermes-plugin
```

Or drop it in by hand: copy this `hermes-plugin/` directory to `~/.hermes/plugins/junie-acp/`.

The installer finishes with *"Plugin installed but not enabled"* — that gate belongs to Hermes' general plugin surface (hooks, tools, the bundled delegation skill). **The provider itself is available immediately**: model-provider discovery is a separate path. Run `hermes plugins enable junie-acp` if you also want the skill.

Requires **Hermes v2026.9.7 or newer** — that release added the provider registration seam this plugin is built on.

Hermes needs its `acp` extra for the protocol SDK — see [Hermes' installation docs](https://hermes-agent.nousresearch.com/docs/getting-started/installation) for how to add an extra to your install.

## Use

```bash
hermes --provider junie-acp chat
hermes -m junie                      # alias
```

`/model` lists the models Junie advertises over the session — the plugin asks the running agent rather than a REST catalog, so you get whatever your account actually has.

## Configuration

Behaviour goes in `config.yaml` under `junie_acp:`. Credentials stay in the environment.

```yaml
junie_acp:
  command: junie                     # path to the CLI
  args: ["--acp=true", "--skip-update-check"]
  permission: deny                   # deny | allow — how to answer Junie's permission prompts
  brave: ""                          # on | off — override Junie's Brave Mode; empty keeps Junie's own setting
  forwarded_tools: []                # all | none | [memory, todo, ...]; empty = the default allowlist
```

| Environment variable | Overrides |
|---|---|
| `JUNIE_API_KEY` | Auth token passed to the CLI as `--auth` (a credential — env only) |
| `HERMES_JUNIE_ACP_COMMAND`, `JUNIE_CLI_PATH` | `command` |
| `HERMES_JUNIE_ACP_ARGS` | `args` |

Env vars win over `config.yaml` — they are the narrower scope, meant for a one-off run.

> `hermes config set junie_acp.<key>` may not recognise the path, because an out-of-tree plugin cannot declare config keys in Hermes' schema. Edit `config.yaml` directly; reading works normally.

### `permission`

Junie asks for consent before acting when its own Brave Mode is off. `deny` (the default) refuses every request, so Junie cannot act without explicit consent. `allow` approves once. This is the seam a future Hermes-approval bridge would replace.

### `forwarded_tools`

Junie is an autonomous agent with its own read/edit/execute tools, so the plugin forwards Hermes' **agent-level** tools only — `memory`, `todo`, the skills toolset and friends. Re-offering the overlapping ones would make Hermes re-run work Junie already finished.

That default set is what keeps Hermes' self-improvement loop alive on this provider: the background-review fork needs those exact tools to write memories and skills. Narrow it and the review can only act on what remains.

## How it works

Junie's own tool calls never come back to Hermes as pending `tool_calls` — Hermes would re-run finished work. Instead the plugin projects them into the transcript as completed `assistant(tool_calls)` + `tool(result)` rows, namespaced `junie_*`, and reports how many tool iterations happened inside the session. That keeps two Hermes subsystems working: the self-improvement loop, which distils memories and skills by replaying the transcript, and the skill-review nudge, whose counter only moves on tool iterations.

Hermes' own tools reach Junie through the ACP text bridge — ACP has no OpenAI `tools` channel, so the schemas travel into the prompt as text and `<tool_call>` blocks are parsed back out.

Everything the plugin uses is public Hermes provider-plugin API; see *External-process (ACP) providers* in the [model provider plugin guide](https://hermes-agent.nousresearch.com/docs/developer-guide/model-provider-plugin).

## Safety

The plugin is the ACP *client*, so file access from Junie goes through it:

- `fs/read_text_file` and `fs/write_text_file` are confined to the working directory
- writes to Hermes-protected files are refused
- reads are redacted for secrets
- the subprocess environment is built with Hermes' `hermes_subprocess_env`, so tier-1 secrets are stripped
- permission requests are denied by default

## Development

With Hermes (including its `acp` extra) available:

```bash
PYTHONPATH=/path/to/hermes-agent python -m pytest hermes-plugin/tests -q
```

The client suite runs end-to-end against a real ACP agent subprocess (`tests/fake_junie_acp_agent.py`) built on the same SDK, so the protocol wiring is under test rather than mocked.

## License

See [LICENSE.md](../LICENSE.md) in the repository root.
