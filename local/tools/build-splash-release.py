#!/usr/bin/env python3
"""Stage an installable Splash channel from tested engine and packed model artifacts.

Output is a self-contained directory to upload to a release host. Nothing is
published and no stable metadata is modified. The normal installer consumes it.
"""

import argparse
import hashlib
import json
import shutil
import zipfile
from pathlib import Path

LOCAL = Path(__file__).resolve().parents[1]
MODEL = "Qwen3.8-3.6-27B-blend-Splash-v0.3"


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--engine", type=Path, required=True)
    p.add_argument("--package", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--base-url", required=True)
    p.add_argument(
        "--reuse-model-archive",
        action="store_true",
        help="Reuse an archive already generated in this output directory",
    )
    p.add_argument("--version", default="0.3.2-splash.1")
    a = p.parse_args()
    manifest = json.loads((a.package / "manifest.json").read_text())
    if not isinstance(manifest.get("model"), str):
        p.error("Package manifest must identify the model")
    for name in ("target", "draft", "vision", "tokenizer"):
        if not (a.package / name).is_dir():
            p.error(f"Missing packed model component: {name}")
    a.output.mkdir(parents=True, exist_ok=True)
    (a.output / "models").mkdir(exist_ok=True)
    engine = a.output / a.engine.name
    if engine.resolve() != a.engine.resolve():
        shutil.copy2(a.engine, engine)
    archive = a.output / f"{MODEL}.zip"
    if not (a.reuse_model_archive and archive.is_file()):
        with zipfile.ZipFile(
            archive, "w", compression=zipfile.ZIP_STORED, allowZip64=True
        ) as z:
            for file in sorted(a.package.rglob("*")):
                if file.is_file():
                    z.write(file, Path(MODEL) / file.relative_to(a.package))
    descriptor = json.loads(
        (LOCAL / "models/Qwen3.8-3.6-27B-blend-MLX-4bit.json").read_text()
    )
    descriptor.update(
        id="local-qwen-blend-splash-v03",
        worker_backend="splash",
        splash_package=MODEL,
        draft_model="DFlash2-v0.3",
        draft_kind="dflash",
    )
    descriptor["junieConfig"].update(id=MODEL, displayName="Qwen Blend (Splash)")
    # Junie's legacy XML-command stop marker is incompatible with native tool grammars.
    descriptor["junieConfig"]["extraBody"]["stop"] = []
    base = a.base_url.rstrip("/")
    descriptor["archives"] = [
        dict(
            modelId=MODEL,
            label="Qwen Blend + DFlash2 v0.3 (Splash)",
            name=archive.name,
            downloadUrl=f"{base}/{archive.name}",
            sha256=sha256(archive),
            size=archive.stat().st_size,
        )
    ]
    (a.output / "models" / f"{MODEL}.json").write_text(
        json.dumps(descriptor, indent=2) + "\n"
    )
    engine_info = dict(
        platform="macos-aarch64",
        version=a.version,
        downloadUrl=f"{base}/{engine.name}",
        sha256=sha256(engine),
    )
    model_info = dict(
        platform="macos-aarch64", id=MODEL, displayName="Qwen Blend (Splash)"
    )
    # Both channels intentionally point at Splash in this isolated release tree.
    for channel in ("main", "eap"):
        (a.output / f"update-info-engine-{channel}.jsonl").write_text(
            json.dumps(engine_info, separators=(",", ":")) + "\n"
        )
        (a.output / f"update-info-models-{channel}.jsonl").write_text(
            json.dumps(model_info, separators=(",", ":")) + "\n"
        )
    installer = (LOCAL / "install.sh").read_text()
    installer = installer.replace('MODEL="Qwen3.6-27B-MLX-4bit"', f'MODEL="{MODEL}"')
    installer = installer.replace(
        "https://raw.githubusercontent.com/jetbrains-junie/junie/main/local", base
    )
    installer = installer.replace(
        'elif [ "$OS_VERSION" -lt 26 ]; then',
        'elif [ "$OS_VERSION" -lt 26 ] || { [ "$OS_VERSION" -eq 26 ] && [ "$(echo "$OS_FULL_VERSION" | cut -d . -f 2)" -lt 4 ]; }; then',
    )
    installer = installer.replace("macOS 26 or higher", "macOS 26.4 or higher")
    (a.output / "install.sh").write_text(installer)
    print(a.output)


if __name__ == "__main__":
    main()
