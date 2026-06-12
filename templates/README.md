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
