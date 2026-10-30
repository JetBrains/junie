"""Portable installer checks using Git Bash or a POSIX shell; no GPU or downloads.

Run: python tests/local_linux_installer.py
On Windows, set BASH to the path of Git's bash.exe if it is not on PATH.
"""

import hashlib
import json
import os
import shutil
import subprocess
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "local/install.sh"
BASH = os.environ.get("BASH") or shutil.which("bash")
if os.name == "nt" and not os.environ.get("BASH"):
    BASH = str(Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Git/bin/bash.exe")


class LinuxInstallerTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="junie installer ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.home = self.root / "home"
        self.home.mkdir()
        self.environment = {
            **os.environ, "HOME": self.home.as_posix(), "JUNIE_HOME": "",
            "JUNIE_NO_ANIM": "1", "JUNIE_LOCAL_MODEL_TEST_MODE": "",
            "FIXTURE_ARCH": "x86_64", "FIXTURE_OS": "Linux", "FIXTURE_CUDA": "12.8",
            "FIXTURE_GPU": "GPU-test, Test NVIDIA, 24576, 570.0", "HF_TOKEN": "",
        }
        self.stub("uname", '''case "$1" in
  -s) echo "$FIXTURE_OS" ;; -m) echo "$FIXTURE_ARCH" ;; -r) echo 6.8.0 ;;
esac''')
        self.stub("nvidia-smi", '''if [ -n "$1" ]; then
  printf '%s\\n' "$FIXTURE_GPU"
else
  printf '| NVIDIA-SMI 570 | Driver Version: 570 | CUDA Version: %s |\\n' "$FIXTURE_CUDA"
fi''')
        # /proc/meminfo and macOS tools are unavailable on Windows.
        self.stub("awk", '''case "$*" in
  */proc/meminfo*) echo 68719476736 ;; *) exec /usr/bin/awk "$@" ;;
esac''')
        self.stub("lscpu", "echo 'Model name: Test CPU'")
        self.stub("sysctl", '''case "$2" in
  hw.memsize) echo 68719476736 ;; *) echo 'Apple M5' ;;
esac''')
        self.stub("sw_vers", "echo 26.0")
        self.stub("pgrep", "exit 1")
        self.stub("xxd", "exit 0")
        self.stub("shasum", '''shift 2; exec sha256sum "$@"''')
        source = INSTALLER.read_text(encoding="utf-8")
        self.functions = self.root / "functions.sh"
        self.functions.write_text(source.split('\nif [ "$LIST_MODELS" = true ]; then\n')[0],
                                  encoding="utf-8", newline="\n")

    def stub(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\n" + body + "\n", encoding="utf-8", newline="\n")
        path.chmod(0o755)

    def run_shell(self, script, *, success=True, **environment):
        # Set PATH inside Bash to avoid Windows PATH separator conversion.
        path = self.bin.as_posix().replace("'", "'\\''")
        command = f"export PATH=\"$(cd '{path}' && pwd)\":$PATH\n" + script
        result = subprocess.run([BASH, "-c", command], cwd=self.root,
                                env={**self.environment, **environment},
                                capture_output=True, text=True, encoding="utf-8", timeout=30)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def check(self, *, success=True, **environment):
        result = self.run_shell(f'sh "{INSTALLER.as_posix()}" --check-only --json',
                                success=success, **environment)
        events = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(events[0]["event"], "hello")
        self.assertFalse((self.home / ".local/share/junie-local").exists())
        return {event["name"]: event for event in events if event["event"] == "check"}

    def test_hardware_and_cuda_checks(self):
        for arch, cuda in [("x86_64", "12.8"), ("aarch64", "13.4"), ("aarch64", "14.0")]:
            with self.subTest(arch=arch, cuda=cuda):
                checks = self.check(FIXTURE_ARCH=arch, FIXTURE_CUDA=cuda)
                self.assertEqual(checks["gpu"]["status"], "ok")
                self.assertEqual(checks["cuda"]["status"], "ok")
                self.assertNotIn("ram", checks)
        for arch, cuda in [("x86_64", "12.7"), ("aarch64", "13.3"), ("aarch64", "N/A")]:
            with self.subTest(arch=arch, cuda=cuda):
                checks = self.check(success=False, FIXTURE_ARCH=arch, FIXTURE_CUDA=cuda)
                self.assertEqual(checks["cuda"]["status"], "fail")

    def test_gpu_validation_and_npu_filter(self):
        for gpu in ["", "GPU-test, Test NVIDIA, N/A, 570", "GPU-test, Test, 16384, 570",
                    "GPU-test, Test, 24319, 570",
                    "GPU-1, Test, 16384, 570\nGPU-2, Test, 24576, 570"]:
            with self.subTest(gpu=gpu):
                checks = self.check(success=False, FIXTURE_GPU=gpu)
                self.assertEqual(checks["gpu"]["status"], "fail")
        checks = self.check(FIXTURE_GPU="DLA-test, NPU, N/A, 570\nGPU-test, Test, 24320, 570")
        self.assertEqual(checks["gpu"]["status"], "ok")
        self.stub("nvidia-smi", "exit 1")
        checks = self.check(success=False)
        self.assertEqual(checks["gpu"]["status"], "fail")

    def test_multiple_gpus_check_only_the_first_gpu(self):
        checks = self.check(FIXTURE_GPU="GPU-1, First GPU, 24576, 570\nGPU-2, Second GPU, 16384, 570")
        self.assertEqual(checks["gpu"]["status"], "ok")
        self.assertIn("First GPU", checks["gpu"]["value"])
        self.assertNotIn("Second GPU", checks["gpu"]["value"])

    def test_failed_hardware_does_not_fetch_or_save_metadata(self):
        self.stub("curl", '''echo requested >> "$HOME/requests"; exit 98''')
        for option in ("", "--update"):
            with self.subTest(option=option):
                result = self.run_shell(f'sh "{INSTALLER.as_posix()}" --json {option}',
                                        success=False, FIXTURE_GPU="")
                events = list(map(json.loads, result.stdout.splitlines()))
                config = next(e for e in events if e["event"] == "config")
                self.assertFalse(config["checks_passed"])
                self.assertEqual(config["engine_version"], "")
                self.assertEqual(events[-1]["event"], "error")
                self.assertIn("system requirements", events[-1]["message"])
                self.assertFalse((self.home / "requests").exists())
                self.assertFalse((self.home / ".local/share/junie-local").exists())

    def test_reported_ram_matches_windows_without_changing_macos(self):
        for system, expected in (("Linux", 24), ("Darwin", 35)):
            with self.subTest(system=system):
                result = self.run_shell(f'sh "{INSTALLER.as_posix()}" --check-only --json',
                                        FIXTURE_OS=system)
                config = next(e for e in map(json.loads, result.stdout.splitlines())
                              if e["event"] == "config")
                self.assertEqual(config["ram_gb"], expected)

    def test_linux_driver_check_uses_cuda_support_instead_of_windows_version(self):
        # Linux 570-series drivers passed native x64 inference tests.
        for driver in ("570.207", "570.211.01", "580.178.04", "595.91.07"):
            with self.subTest(driver=driver):
                checks = self.check(FIXTURE_GPU=f"GPU-test, Test NVIDIA, 24576, {driver}")
                self.assertEqual(checks["gpu"]["status"], "ok")
                self.assertEqual(checks["cuda"]["status"], "ok")

    def test_platform_defaults_and_model_feeds(self):
        for arch in ("x86_64", "aarch64"):
            result = self.run_shell(f'sh "{INSTALLER.as_posix()}" --help', success=False, FIXTURE_ARCH=arch)
            self.assertIn("default: Qwen3.6-27B-Q4_K_M", result.stdout)
            for channel in ("main", "eap"):
                result = self.run_shell(
                    f'sh "{INSTALLER.as_posix()}" --models --json --channel {channel}',
                    FIXTURE_ARCH=arch,
                    JUNIE_LOCAL_UPDATE_FILES_BASE_URL=(ROOT / "local").as_uri(),
                )
                event = next(e for e in map(json.loads, result.stdout.splitlines())
                             if e["event"] == "models")
                self.assertEqual(len(event["models"]), 2)
                for model in event["models"]:
                    path = ROOT / "local/models" / f"{model['id']}.json"
                    manifest = json.loads(path.read_text())
                    self.assertEqual(model["size"], sum(a["size"] for a in manifest["archives"]))
        result = self.run_shell(f'sh "{INSTALLER.as_posix()}" --help', FIXTURE_OS="Darwin")
        self.assertIn("default: Qwen3.6-27B-MLX-4bit", result.stdout)
        self.check(FIXTURE_OS="Darwin")
        self.run_shell(f'sh "{INSTALLER.as_posix()}" --check-only',
                       success=False, FIXTURE_ARCH="riscv64")

    def test_linux_cli_rejects_invalid_channel_and_deprecated_flag_like_windows(self):
        self.stub("curl", "echo 'Unexpected network access' >&2; exit 98")
        for arguments in ("--channel imaginary --check-only --json", "--keep-config --check-only", "--help"):
            with self.subTest(arguments=arguments):
                result = self.run_shell(f'sh "{INSTALLER.as_posix()}" {arguments}', success=False)
                self.assertEqual(result.returncode, 1)
                self.assertNotIn('"event":"hello"', result.stdout)
        self.run_shell(f'sh "{INSTALLER.as_posix()}" --keep-config --check-only', FIXTURE_OS="Darwin")

    def test_linux_does_not_require_system_ram_but_macos_still_does(self):
        self.stub("sysctl", '''case "$2" in
  hw.memsize) echo 17179869184 ;; *) echo 'Apple M5' ;;
esac''')
        self.assertNotIn("ram", self.check())
        checks = self.check(success=False, FIXTURE_OS="Darwin")
        self.assertEqual(checks["ram"]["status"], "fail")

    def model_fixture(self, *, zipped=False, corrupt_hash=False):
        name = "fixture.zip" if zipped else "fixture.gguf"
        weights = self.root / name
        if zipped:
            with zipfile.ZipFile(weights, "w") as archive:
                archive.writestr("fixture/config.json", "{}")
        else:
            weights.write_bytes(b"GGUF fixture weights")
        digest = "0" * 64 if corrupt_hash else hashlib.sha256(weights.read_bytes()).hexdigest()
        manifest = self.root / "model.json"
        manifest.write_text(json.dumps({"archives": [{
            "name": name, "modelId": "fixture", "label": "Fixture",
            "downloadUrl": weights.as_uri(), "sha256": digest,
        }]}), encoding="utf-8")
        return f'''. "{self.functions.as_posix()}"
mkdir -p "$MODELS_DIR" "$DOWNLOAD_DIR"
models_json=$(cat "{manifest.as_posix()}")
install_model_if_needed 0
'''

    def test_gguf_install_uses_windows_completion_marker_semantics(self):
        script = self.model_fixture()
        self.run_shell(script)
        installed = self.home / ".local/share/junie-local/models/fixture.gguf"
        self.assertEqual(installed.read_bytes(), b"GGUF fixture weights")
        timestamp = installed.stat().st_mtime_ns
        self.assertIn("already installed", self.run_shell(script).stdout)
        self.assertEqual(installed.stat().st_mtime_ns, timestamp)
        self.assertTrue((self.home / ".local/share/junie-local/incomplete_downloads/fixture.gguf").is_file())
        installed.unlink()
        self.assertIn("already installed", self.run_shell(script).stdout)
        self.assertFalse(installed.exists())
        installed.with_name(".fixture.installed").unlink()
        installed.write_bytes(b"interrupted output")
        self.run_shell(script)
        self.assertEqual(installed.read_bytes(), b"GGUF fixture weights")

    def test_checksum_failure_never_installs_weights(self):
        self.run_shell(self.model_fixture(corrupt_hash=True), success=False)
        models = self.home / ".local/share/junie-local/models"
        self.assertFalse((models / "fixture.gguf").exists())
        self.assertFalse((models / ".fixture.installed").exists())

    def test_macos_zip_install_is_preserved(self):
        self.run_shell(self.model_fixture(zipped=True), FIXTURE_OS="Darwin")
        installed = self.home / ".local/share/junie-local/models/fixture/config.json"
        self.assertTrue(installed.is_file())

    def test_linux_restart_uses_authenticated_health_and_controller(self):
        self.stub("curl", '''printf '%s\\n' "$*" >> "$HOME/requests"
case "$*" in
  */health*) [ -f "$HOME/running" ] ;;
  */status*) echo '{"phase":"ready"}' ;;
  *) exit 1 ;;
esac''')
        self.stub("pgrep", "echo 'Process-name lookup must not run on Linux' >&2; exit 99")
        controller = self.root / "serverctl.sh"
        controller.write_text('''#!/bin/sh
echo "$1" >> "$HOME/controls"
case "$1" in stop) rm -f "$HOME/running" ;; start) touch "$HOME/running" ;; esac
''', encoding="utf-8", newline="\n")
        controller.chmod(0o755)
        (self.home / "running").touch()
        self.run_shell(f'''. "{self.functions.as_posix()}"
mkdir -p "$BASE_DIR"
echo '{{"api_key":"fixture-token"}}' > "$BASE_DIR/server-config.json"
ENGINE_CTL="{controller.as_posix()}"
start_engine
''')
        self.assertEqual((self.home / "controls").read_text().splitlines(), ["stop", "start"])
        self.assertIn("Authorization: Bearer fixture-token", (self.home / "requests").read_text())

if __name__ == "__main__":
    unittest.main()
