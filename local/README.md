# Junie Local Model

Installation scripts and update metadata for the Junie local model (on-device inference).

## Current Platform Support

macOS only (Apple M5 or newer, macOS 26+).

## Files

### `install.sh`

Shell script that downloads and installs the inference engine and model weights. Run it directly or pipe it from a URL:

```bash
curl -fsSL https://... | sh
```

Supported options:

- `--model <name>` — Model to install: `Qwen3.6-27B-MLX-4bit` (default) or `Qwen3.8-27B-MLX-4bit`
- `--channel <name>` — Update channel: `main` (default) or `eap`
- `--check-only` — Report system information and exit without installing
- `--json` — Emit machine-readable events on stdout
- `--keep-config` — Preserve an existing `server-config.json`

### Update Channel Files

Update files describe available engine and model versions per channel. There are two channels:

- **main** — Stable releases
- **eap** — Early access previews

#### Engine updates (JSONL)

- `update-info-engine-main.jsonl`
- `update-info-engine-eap.jsonl`

One JSON object per line, one line per platform:

```json
{"version":"0.2.2","platform":"macos-aarch64","hardware":"Apple M5","downloadUrl":"...","sha256":"...","size":52428800}
```

Fields:

| Field | Description |
|---|---|
| `version` | Engine semantic version |
| `platform` | Target platform (e.g. `macos-aarch64`) |
| `hardware` | Required hardware (e.g. `"Apple M5"`) |
| `downloadUrl` | URL to the engine archive |
| `sha256` | SHA-256 checksum of the archive |
| `size` | Archive size in bytes |

#### Model index updates (JSONL)

- `update-info-models-main.jsonl`
- `update-info-models-eap.jsonl`

One JSON object per line, listing available models for each platform:

```json
{"platform":"macos-aarch64","id":"Qwen3.6-27B-MLX-4bit","displayName":"Qwen 3.6"}
```

Fields:

| Field | Description |
|---|---|
| `platform` | Target platform (e.g. `macos-aarch64`) |
| `id` | Model identifier — matches the filename in the `models/` folder (without `.json`) and is used with `--model` |
| `displayName` | Human-readable model name |

#### Model detail files (JSON)

Individual JSON files in the `models/` folder provide full configuration and download information for each model:

- `models/Qwen3.6-27B-MLX-4bit.json`
- `models/Qwen3.8-27B-MLX-4bit.json`

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
3. If needed, update `install.sh` to handle any platform-specific logic for the new model.

## Adding a New Platform

1. Add a new line to `update-info-engine-main.jsonl` (and/or `update-info-engine-eap.jsonl`) for the new platform.
2. Add a new line to `update-info-models-main.jsonl` (and/or `update-info-models-eap.jsonl`) for each model on the new platform.
3. Update the model detail JSON files in `models/` to include archives for the new platform if they differ from the existing ones.
4. Update `install.sh` to support the new platform (OS detection, download URLs, etc.).
