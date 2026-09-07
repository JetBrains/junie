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

- `--model <name>` — Model to install: `qwen3_6` (default) or `qwen3_8`
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

#### Model updates (JSON)

- `update-info-models-main.json`
- `update-info-models-eap.json`

Hierarchical JSON with models grouped by platform.

**Important:** Model keys (the identifiers used with `--model`) must not contain dots (`.`), because `plutil` uses dots as path separators. Use underscores instead (e.g. `qwen3_6` instead of `qwen3.6`).

```json
{
  "models": {
    "qwen3_6": {
      "default": true,
      "displayName": "Qwen 3.6",
      "junieModelId": "local-qwen3.6-27b-4bit",
      "minEngineVersion": "0.2.2",
      "platforms": {
        "macos-aarch64": {
          "hardware": "Apple M5",
          "archives": [
            {
              "name": "Qwen3.6-27B-MLX-4bit.zip",
              "label": "Qwen 3.6 27B 4bit",
              "modelId": "Qwen3.6-27B-MLX-4bit",
              "downloadUrl": "...",
              "sha256": "...",
              "size": 14319324160
            }
          ]
        }
      }
    }
  }
}
```

Fields:

| Field | Description |
|---|---|
| `default` | Whether this model is the default when none is specified |
| `displayName` | Human-readable model name |
| `junieModelId` | Internal Junie model identifier |
| `minEngineVersion` | Minimum engine version required to run this model |
| `platforms` | Map of platform keys to platform-specific data |
| `hardware` | Required hardware for the platform |
| `archives` | Array of archive files for this model on this platform |
| `archives[].name` | Archive filename |
| `archives[].label` | Human-readable label |
| `archives[].modelId` | Model ID the engine serves under |
| `archives[].downloadUrl` | Download URL |
| `archives[].sha256` | SHA-256 checksum |
| `archives[].size` | Size in bytes |

## Adding a New Platform

1. Add a new line to the engine JSONL file for the new platform.
2. Add a new platform key under each model in the models JSON file.
3. Update `install.sh` to support the new platform (OS detection, download URLs, etc.).
