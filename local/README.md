# Junie Local Model

Installation scripts and update metadata for the Junie local model (on-device inference).

## Current Platform Support

- **macOS** (`install.sh`): Apple M4 or newer, macOS 26+ (MLX backend)
- **Windows** (`install.ps1`): NVIDIA GPU with 24 GB VRAM, driver 581+, Visual
  C++ Redistributable; `windows-amd64` and `windows-aarch64`

Linux is not supported yet: `install.sh` refuses to run there.

## The installer API

`install.sh` (macOS) and `install.ps1` (Windows) are two implementations of the
same installer. They take the same options, perform the same steps and emit the
same JSON events, so a caller only has to pick the script for the platform — not
to special-case the platform afterwards.

### Command line

Both scripts accept the same `--`-style flags. `install.ps1` additionally
accepts the PowerShell spellings (`-Model`, `-CheckOnly`, …) for the same flags.

| Option | Description |
|---|---|
| `--model <id>` | Model to install, as listed by `--models`. Defaults to `Qwen3.6-27B-MLX-4bit` (macOS) / `Qwen3.6-27B-Q4_K_M` (Windows) |
| `--channel <name>` | Update channel: `main` (default) or `eap` |
| `--check-only` | Report system information, then exit without installing |
| `--models` | List the models available for this platform, then exit |
| `--check-engine-update` | Report whether a different inference engine is published for this device, then exit |
| `--update` | Update the engine and re-install every model already installed here |
| `--json` | Emit machine-readable events on stdout; human output goes to stderr |
| `--keep-config` | **Deprecated**, accepted and ignored; it only prints a deprecation warning |
| `--help`, `-h` | Show usage, then exit |

```bash
./install.sh --model Qwen3.6-27B-MLX-4bit --channel eap
./install.sh --check-engine-update --json
./install.sh --update --json
```

```powershell
.\install.ps1 --model Qwen3.6-27B-Q4_K_M --channel eap
.\install.ps1 --check-engine-update --json
.\install.ps1 --update --json
```

`install.sh` can also be piped from a URL: `curl -fsSL https://... | sh`.

The exit code is `0` on success and non-zero when a requirement is not met, a
download or checksum fails, or the arguments are invalid.

Both scripts honour the same environment variables:

| Variable | Effect |
|---|---|
| `JUNIE_HOME` | Junie's config directory, where the model config is written |
| `JUNIE_LOCAL_UPDATE_FILES_BASE_URL` | Where the channel feeds are read from; useful for testing with a `file://` URL |
| `JUNIE_LOCAL_MODEL_TEST_MODE` | When set to `1`, unmet system requirements no longer block the install |

### Test mode

`JUNIE_LOCAL_MODEL_TEST_MODE=1` makes the installer run on a device that is not
supported. The system checks are still performed and reported as usual — the
`check` events keep their real `ok` / `warn` / `fail` status — but a failing
requirement is downgraded to a `warning` event instead of aborting the run, and
`checks_passed` in the `config` event is `true`. `--check-only` exits `0` as
well. The engine and the model are of course not expected to work on such a
device; this is only meant for exercising the installer itself.

```bash
JUNIE_LOCAL_MODEL_TEST_MODE=1 ./install.sh
```

```powershell
$env:JUNIE_LOCAL_MODEL_TEST_MODE='1'; .\install.ps1
```

### `--models`

Lists the models published for this platform in the selected channel and exits.
Human output is one `displayName (id, size)` line per model with its description
underneath; with `--json` a single `models` event carries the same data.

Each model entry has:

| Field | Description |
|---|---|
| `id` | Feed id of the model, the value `--model` takes |
| `displayName` | Human-readable name |
| `description` | One-line description of the model |
| `junieModelId` | The model id Junie itself uses (the `models/<id>.json` profile written to `JUNIE_HOME`), the value shown by `/model` |
| `size` | Total download size in bytes: the sum of the `size` fields of every archive in the model JSON |

`junieModelId` and `size` are resolved from the model JSON
(`models/<id>.json` in the feed); when it cannot be fetched they fall back to
`""` and `0`.

```bash
JUNIE_LOCAL_UPDATE_FILES_BASE_URL="https://raw.githubusercontent.com/jetbrains-junie/junie/main/local" ./install.sh --models --json
```

```json
{"event":"models","platform":"macos-aarch64","channel":"main","models":[{"id":"Qwen3.6-27B-MLX-4bit","displayName":"Qwen 3.6","description":"A 27B vision-language model built for agentic coding, STEM reasoning, and image understanding","junieModelId":"local-qwen3.6-27b-4bit","size":17164458460},{"id":"Qwen3.8-3.6-27B-blend-MLX-4bit","displayName":"Qwen 3.8/3.6 Blend (experimental)","description":"A local AI coding model that completes more coding tasks than Qwen3.6 while using far fewer output tokens than Qwen3.8.","junieModelId":"local-qwen3.8-3.6-27b-blend-4bit","size":17164436304}]}
```

### `--check-engine-update`

Resolves the engine exactly like the install path does — the last matching entry
for this platform in the channel feed — and compares it with the installed
version. Version numbers are not ordered: the feed decides what is current, so
any mismatch is reported as an update. Nothing is downloaded or written.

The installed version comes from `versions/<version>`, recorded by the `current`
symlink on macOS and by the `current` file on Windows; that is the only
implementation difference.

### `--update`

Performs the update that the check reports. It installs the engine the channel
feed points at and then re-runs the model install for every model already
installed on this device (the saved `models/<id>.json` configs are the record of
what is installed), so model updates are picked up too. `--model` is ignored: no
model is added or removed. Weights already on disk are kept as they are; only
archives the model JSON lists but this device does not have yet are downloaded.
The Junie model config is regenerated for each of those models, and the engine
is restarted and warmed up as usual.

### Windows: chaining from the Junie CLI installer

The Junie CLI installer can chain into `install.ps1` right after installing
Junie, the same way `install.sh` does with `--local-model`. Since the documented
Windows install is piped (`irm ... | iex`) and cannot receive arguments, use the
environment variable:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "$env:JUNIE_LOCAL_MODEL='1'; iex (irm 'https://junie.jetbrains.com/install.ps1')"
```

Run as a file, `.\install.ps1 --local-model` on the Junie installer does the
same.

## JSON events (`--json`)

With `--json` both scripts write one compact JSON object per line to **stdout**
and move all human-readable output to **stderr**. A consumer should read stdout
line by line, parse each line as a JSON object, and ignore events and fields it
does not know — new ones may be added within the same protocol version.

The first line is always `hello`, which carries the protocol version (currently
`1`). A run ends with `done` (full install or update), with the single event of
the mode that was requested (`models`, `engine_update`), or with `error`.

| Event | When | Fields |
|---|---|---|
| `hello` | First line of every run | `protocol` (number) |
| `models` | `--models`, then the script exits | `platform`, `channel`, `models`: array of `{id, displayName, description, junieModelId, size}` |
| `engine_update` | `--check-engine-update`, then the script exits | `platform`, `channel`, `installed_version` (empty when none), `latest_version`, `update_available` (bool), `status`: `up_to_date` \| `update_available` \| `not_installed` |
| `check` | Once per system requirement | `name`, `status`: `ok` \| `warn` \| `fail`, `value`, `requirement` |
| `config` | After the checks, before installing | `port`, `ram_gb`, `engine_version`, `model`, `checks_passed` (bool) |
| `update` | `--update` only, after `config` | `installed_engine_version`, `engine_version`, `models`: array of model ids to update |
| `step_start` | Start of an install step | `id`, `title` |
| `step_done` | End of an install step | `id` |
| `progress` | Periodically while downloading or extracting | `action`: `downloading` \| `extracting`, `file`, `bytes`, `total` (`0` when unknown), `label` |
| `activity` | Work without byte progress | `action`: `verifying` \| `extracting`, `file`, `label` |
| `warning` | Recoverable problem; the run continues | `message` |
| `error` | Fatal problem; the run stops | `message` |
| `done` | Successful install or update | `model_id`, `port`, `model_path`, `label` |

`check` names are `os`, `cpu`, `gpu` and `ram` on both platforms; Windows adds
`driver` and `vc_redist`. `step_start` / `step_done` use the ids `engine`,
`models`, `configure` and `start`, in that order.

Example of a full install:

```json
{"event":"hello","protocol":1}
{"event":"check","name":"os","status":"ok","value":"macOS 26.0","requirement":"macOS 26 or newer"}
{"event":"config","port":19239,"ram_gb":24,"engine_version":"0.3.3","model":"Qwen3.6-27B-MLX-4bit","checks_passed":true}
{"event":"step_start","id":"engine","title":"Installing the inference engine"}
{"event":"progress","action":"downloading","file":"junie-local-0.3.3-macos-arm64.tar.gz","bytes":1048576,"total":121590439,"label":"Junie Local 0.3.3"}
{"event":"activity","action":"verifying","file":"junie-local-0.3.3-macos-arm64.tar.gz","label":"Junie Local 0.3.3"}
{"event":"step_done","id":"engine"}
{"event":"done","model_id":"Qwen3.6-27B-MLX-4bit","port":19239,"model_path":"/Users/me/.local/share/junie-local/models/Qwen3.6-27B-MLX-4bit","label":"Qwen 3.6 27B 4bit"}
```

`--models` and `--check-engine-update` are single-event modes:

```json
{"event":"hello","protocol":1}
{"event":"models","platform":"macos-aarch64","channel":"main","models":[{"id":"Qwen3.6-27B-MLX-4bit","displayName":"Qwen 3.6","description":"A 27B vision-language model built for agentic coding, STEM reasoning, and image understanding","junieModelId":"local-qwen3.6-27b-4bit","size":17164458460}]}
```

```json
{"event":"hello","protocol":1}
{"event":"engine_update","platform":"macos-aarch64","channel":"main","installed_version":"0.3.3","latest_version":"0.3.4","update_available":true,"status":"update_available"}
```

`--update` adds its plan right after `config` and then continues with the
regular install events:

```json
{"event":"update","installed_engine_version":"0.3.3","engine_version":"0.3.4","models":["Qwen3.6-27B-MLX-4bit"]}
```

## Update metadata files

Update files describe available engine and model versions per channel. There are two channels:

- **main** — Stable releases
- **eap** — Early access previews

### Engine updates (JSONL)

- `update-info-engine-main.jsonl`
- `update-info-engine-eap.jsonl`

One JSON object per line, one line per platform:

```json
{"version":"0.2.2","platform":"macos-aarch64","hardware":"Apple M4","downloadUrl":"...","sha256":"...","size":52428800}
```

Fields:

| Field | Description |
|---|---|
| `version` | Engine semantic version |
| `platform` | Target platform (e.g. `macos-aarch64`) |
| `hardware` | Required hardware (e.g. `"Apple M4"`) |
| `downloadUrl` | URL to the engine archive |
| `sha256` | SHA-256 checksum of the archive |
| `size` | Archive size in bytes |

### Model index updates (JSONL)

- `update-info-models-main.jsonl`
- `update-info-models-eap.jsonl`

One JSON object per line, listing available models for each platform:

```json
{"platform":"macos-aarch64","id":"Qwen3.6-27B-MLX-4bit","displayName":"Qwen 3.6","description":"A 27B vision-language model built for agentic coding, STEM reasoning, and image understanding"}
```

Fields:

| Field | Description |
|---|---|
| `platform` | Target platform (e.g. `macos-aarch64`) |
| `id` | Model identifier — matches the filename in the `models/` folder (without `.json`) and is used with `--model` |
| `displayName` | Human-readable model name |
| `description` | One-line description shown by `--models` |

### Model detail files (JSON)

Individual JSON files in the `models/` folder provide full configuration and download information for each model:

- `models/Qwen3.6-27B-MLX-4bit.json`
- `models/Qwen3.8-3.6-27B-blend-MLX-4bit.json`

```json
{
  "id": "local-qwen3.6-27b-4bit",
  "junieConfig": {
    "displayName": "Qwen 3.6",
    "providerName": "Local",
    "id": "Qwen3.6-27B-MLX-4bit",
    "baseUrl": "http://localhost:$ENGINE_PORT/v1/chat/completions",
    "apiType": "OpenAICompletion",
    "apiKey": "$AUTH_TOKEN",
    "temperature": 0.6,
    "maxContextLength": 150000,
    "extraBody": {
      "enable_thinking": false
    }
  },
  "archives": [
    {
      "modelId": "Qwen3.6-27B-MLX-4bit",
      "label": "Qwen 3.6 27B 4bit",
      "name": "Qwen3.6-27B-MLX-4bit.zip",
      "downloadUrl": "https://download.jetbrains.com/resources/junie-local/Qwen3.6-27B-MLX-4bit.zip",
      "sha256": "...",
      "size": 16081511240
    }
  ]
}
```

Fields:

| Field | Description |
|---|---|
| `id` | Internal Junie model identifier |
| `junieConfig` | Configuration Junie uses to connect to the local model |
| `junieConfig.displayName` | Human-readable model name |
| `junieConfig.providerName` | Provider name (`Local`) |
| `junieConfig.id` | Model ID as exposed by the engine |
| `junieConfig.baseUrl` | Endpoint URL (uses `$ENGINE_PORT` variable) |
| `junieConfig.apiType` | API type (`OpenAICompletion`) |
| `junieConfig.apiKey` | Auth token (uses `$AUTH_TOKEN` variable) |
| `junieConfig.temperature` | Sampling temperature |
| `junieConfig.maxContextLength` | Maximum context window size |
| `junieConfig.extraBody` | Additional request body fields |
| `archives` | Array of archive files for this model |
| `archives[].modelId` | Model ID the engine serves under |
| `archives[].label` | Human-readable label |
| `archives[].name` | Archive filename |
| `archives[].downloadUrl` | Download URL |
| `archives[].sha256` | SHA-256 checksum |
| `archives[].size` | Size in bytes |

## Adding a New Model

1. Create a new model detail file `models/<ModelId>.json` with `id`, `junieConfig`, and `archives` fields.
2. Add a new line to `update-info-models-main.jsonl` (and/or `update-info-models-eap.jsonl`) for each platform the model supports.
3. If needed, update `install.sh` and `install.ps1` to handle any platform-specific logic for the new model.

## Adding a New Platform

1. Add a new line to `update-info-engine-main.jsonl` (and/or `update-info-engine-eap.jsonl`) for the new platform.
2. Add a new line to `update-info-models-main.jsonl` (and/or `update-info-models-eap.jsonl`) for each model on the new platform.
3. Update the model detail JSON files in `models/` to include archives for the new platform if they differ from the existing ones.
4. Update `install.sh` and `install.ps1` to support the new platform (OS detection, download URLs, etc.), keeping their options and JSON events identical.
