# Splash release staging

The `feat/splash-local-engine` branch is coordinated with:

- JetBrains/mlx-vlm: `feat/junie-splash-worker`
- Junie application: `feat/splash-local-engine`

Build the engine using `packaging/build_splash.py` in the engine repository.
Stage a channel using this repository:

```sh
python3 local/tools/build-splash-release.py \
  --engine /path/to/junie-splash-macos-arm64.tar.gz \
  --package /path/to/packed-blend-v03 \
  --output /path/to/release-directory \
  --base-url https://your-release-host.example/junie-splash
```

The package must contain `manifest.json`, `target/`, `draft/`, `vision/` and
`tokenizer/`, produced and validated by the model conversion pipeline. The
stager creates a ZIP rooted at its managed model ID, calculates SHA256 hashes,
and emits the installer, engine/model indexes, and model descriptor. All
artifacts must be served at the exact base URL supplied. Nothing is uploaded by
this command, and stable channel metadata remains untouched.

For a local release test, serve the output with `python3 -m http.server` bound
to loopback and use that URL as `--base-url`. Do not upload an installer built
with a loopback URL. `--reuse-model-archive` is only for iterating metadata with
an unchanged package; otherwise regenerate the archive.

The application can embed this URL at build time with
`-PlocalInstallerUrl=<base-url>/install.sh`; preview users need no environment
overrides. The application branch also accepts `JUNIE_LOCAL_INSTALL_SCRIPT_URL` pointing to
`<base-url>/install.sh`. Start that Junie build, open `/local`, and select
Qwen Blend (Splash). The normal installer downloads the engine and weights,
sets the default model, and uses the existing Junie lifecycle. No model server,
Python environment or Splash checkout needs to be started by the user.

Splash 1.0.2 requires macOS 26.4+. The staged installer enforces this. The
profile retains reasoning with low effort, temperature 1, top-p 0.95 and top-k
20. It overrides the legacy XML-command stop marker with an empty stop list:
Splash uses native tool grammar and rejects nonempty stop sequences with tools.
The target is the packed Q4 Blend and the draft is DFlash2 v0.3.

## Release boundary

This is a separate release channel, not a modification to the public main/EAP
indexes. Before promotion, publish the staged artifacts to the maintained
release host and test download on a clean Mac. Existing release signing and
notarization requirements still apply. The local archive test is not a
Gatekeeper/download-quarantine test. Preserve the previous engine version,
model descriptor, server configuration and Junie profile for rollback when
moving an existing installation between MLX and Splash.
