# Junie installer templates

This directory is the single source of truth for the `install.sh` / `install.ps1`
scripts that live in the repository root. The root scripts are **generated** —
do not edit them directly.

## Workflow

1. Edit a template or a shim:
   - `install.sh.template` — Bash installer
   - `install.ps1.template` — PowerShell installer
   - `junie.shim.sh` — Bash shim inlined into every `install*.sh`
   - `junie.shim.bat` — Windows `.bat` shim inlined into every `install*.ps1`
2. Edit `channels.tsv` if you need to add/remove a channel.
3. Regenerate the root scripts:
   ```sh
   ./templates/generate.sh
   ```
4. Verify the result is clean and idempotent:
   ```sh
   ./templates/generate.sh --check
   ```
5. Commit the templates and the regenerated root scripts together.

## Files

| File                    | Purpose                                                    |
|-------------------------|------------------------------------------------------------|
| `channels.tsv`          | `name<TAB>update_info_url` rows (one per channel)          |
| `install.sh.template`   | Bash installer template with `{{CHANNEL}}`, `{{UPDATE_INFO_URL}}`, `{{SHIM}}` placeholders |
| `install.ps1.template`  | PowerShell installer template with the same placeholders   |
| `junie.shim.sh`         | Bash shim body (verbatim, no escaping)                     |
| `junie.shim.bat`        | Windows `.bat` shim body (verbatim, no escaping)           |
| `generate.sh`           | Regenerates `install*.sh` and `install*.ps1` in the repo root |

## Output layout

For each row in `channels.tsv`:

- `release`      → `install.sh`, `install.ps1`
- `<name>` else → `install-<name>.sh`, `install-<name>.ps1`

## Local model setup

Every `install*.sh` accepts `--local-model`. With it, once Junie is installed the
installer fetches and runs `local/install.sh` from this repository, which
downloads the inference engine and model weights, writes the Junie model config,
and starts the engine:

```sh
curl -fsSL https://junie.jetbrains.com/install.sh | bash -s -- --local-model
```

`LOCAL_MODEL_URL` in `install.sh.template` points at
`raw.githubusercontent.com/jetbrains-junie/junie/main/local/install.sh` — the
same host, repo, and branch as the `channels.tsv` update-info URLs. Note that
`junie.jetbrains.com` cannot be used here: it ignores the path and redirects
every request to the Junie installer itself.

The local model requires macOS 26+ on an Apple M5 or newer with at least 40 GB of
RAM; `local/install.sh` runs its own preflight checks and reports what is missing.
If it fails, the installer says that Junie itself is installed and ready to run,
prints the command to retry the local model on its own, and exits non-zero.

`local/install.sh` reports itself two ways from one code path. Standalone it
draws the Junie logo, section headings and a progress bar that fits the terminal;
with `--json` it draws nothing, keeps its human stream free of escape sequences,
and reports through the protocol events instead. The drawing is confined to the
`# --- junie-ui:begin/end ---` block and steps down to plain lines whenever
stdout is not a terminal, `CI=true`, or `JUNIE_NO_ANIM=1`.

### Windows

Every `install*.ps1` offers the same opt-in, wired to `local/install.ps1`
(`$LOCAL_MODEL_URL` in `install.ps1.template`). Because the documented Windows
install is piped — `irm ... | iex` — and a piped script body cannot receive
arguments, the switch is primarily an environment variable:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "$env:JUNIE_LOCAL_MODEL='1'; iex (irm 'https://junie.jetbrains.com/install.ps1')"
```

When the installer is run as a file (or as a script block), `--local-model`
works too and is equivalent:

```powershell
.\install.ps1 --local-model
```

`Install-LocalModel` downloads `local/install.ps1` to a temp file and runs it as
a child process, so that script's own argument parsing and exit code behave
exactly as for a direct invocation; the temp file is always removed. Failures
are reported like on Unix: Junie itself is installed, with a retry hint, exit 1.

The Windows local model is NVIDIA-only — `local/install.ps1` requires a GPU with
~24 GB of VRAM and runs its own preflight checks.

One-shot installs (`JUNIE_ONESHOT=1`, set by the shim) pass no arguments, so the
local model step never runs on that path.

## One-shot channel switching

The shim supports `junie --<channel>` (`--eap`, `--nightly`, `--release`,
`--experimental`, or `--channel=<name>`) to run another channel's latest build
for a single launch without changing the installed default.

A specific build can be pinned with `--use-version=<build>` (e.g.
`junie --eap --use-version=122.1`); the shim forwards it to the installer as
`JUNIE_VERSION`. Without it, the channel's latest build is used.

It works by shelling out to that channel's published installer in **one-shot
mode**: the shim runs `install-<channel>.sh` with `JUNIE_ONESHOT=1`,
`JUNIE_ONESHOT_VERSION_FILE=<tmp>`, and (when pinned) `JUNIE_VERSION=<build>`.
In one-shot mode the installer:

- still resolves + downloads + installs the channel's latest build into
  `versions/<ver>` (skipping the download if that exact version is already
  present), but
- does **not** rewrite the shim, flip the `current` pointer, or modify `PATH`, and
- writes the installed version to `JUNIE_ONESHOT_VERSION_FILE`.

The shim then launches that version directly. The default channel (the `current`
pointer) is left untouched, so a plain `junie` still runs/updates the default.

The base URL for fetching installers is `https://junie.jetbrains.com` and can be
overridden for testing via `JUNIE_INSTALL_BASE_URL`. The set of valid channel
names is injected into both shims as `{{CHANNELS}}` from `channels.tsv` by
`generate.sh` (the single source of truth); the shims derive both flag matching
and validation from that one list, so adding a channel to `channels.tsv` and
regenerating is all that's required.

On Windows the bareword forms (`junie --eap`, `--nightly`, …) are the most
robust: `cmd.exe` tokenizes on `=`, so the explicit `junie --channel=<name>`
form is parsed out of the raw argument string (`%*`) rather than the `FOR`
loop. Prefer barewords there.
