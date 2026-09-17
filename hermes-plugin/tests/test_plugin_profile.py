"""The plugin must load the way Hermes actually loads it.

Hermes imports a provider plugin directory with
``importlib.util.spec_from_file_location(..., submodule_search_locations=[dir])``
— the directory becomes a package, but it is never placed on ``sys.path``. That
distinction is invisible until runtime: an absolute ``import junie_hermes...``
imports fine from a checkout and raises ``ModuleNotFoundError`` once installed
under ``~/.hermes/plugins/``. These tests load the plugin through the same
mechanism so that failure mode cannot come back.

The rest pins the launch metadata the provider seam reads off the profile —
`process_command`, `process_args`, the env overrides — since a typo there is
also only visible when a real subprocess fails to start.
"""

from __future__ import annotations

import importlib
import importlib.util
import sys
import uuid
from pathlib import Path

import pytest

PLUGIN_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = PLUGIN_DIR.parent

pytest.importorskip("providers", reason="requires a hermes-agent checkout on sys.path")


def _load_plugin_as_hermes_does():
    """Import the plugin directory exactly the way providers/__init__.py does."""
    module_name = f"_hermes_user_provider_junie_acp_{uuid.uuid4().hex[:8]}"
    spec = importlib.util.spec_from_file_location(
        module_name,
        PLUGIN_DIR / "__init__.py",
        submodule_search_locations=[str(PLUGIN_DIR)],
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    try:
        spec.loader.exec_module(module)
    except Exception:
        sys.modules.pop(module_name, None)
        raise
    return module


@pytest.fixture
def plugin():
    import providers as _providers

    snapshot = (
        dict(_providers._REGISTRY),
        dict(_providers._ALIASES),
        _providers._PROVIDER_LIST_CACHE,
    )
    try:
        yield _load_plugin_as_hermes_does()
    finally:
        _providers._REGISTRY.clear()
        _providers._REGISTRY.update(snapshot[0])
        _providers._ALIASES.clear()
        _providers._ALIASES.update(snapshot[1])
        _providers._PROVIDER_LIST_CACHE = snapshot[2]


def test_the_plugin_registers_itself_on_import(plugin):
    from providers import get_provider_profile

    profile = get_provider_profile("junie-acp")
    assert profile is not None
    assert profile is plugin.junie_acp


@pytest.mark.parametrize("alias", ["junie", "jetbrains-junie-acp", "junie-acp-agent"])
def test_aliases_resolve(plugin, alias):
    from providers import get_provider_profile

    assert get_provider_profile(alias) is plugin.junie_acp


@pytest.fixture
def plugin_dir_off_sys_path():
    """Reproduce the installed environment: the plugin directory is NOT importable.

    Hermes never puts it on ``sys.path``. A test run does — pytest inserts the
    rootdir, and the client suite inserts the plugin root explicitly — which is
    exactly what would hide an absolute-import bug. Strip both, and evict any
    cached copy of the plugin's package so the import is really re-resolved.
    """
    saved_path = list(sys.path)
    saved_modules = {k: v for k, v in sys.modules.items() if k.split(".")[0] == "junie_hermes"}
    plugin_dir = str(PLUGIN_DIR)
    sys.path[:] = [p for p in sys.path if Path(p or ".").resolve() != PLUGIN_DIR]
    for name in list(saved_modules):
        del sys.modules[name]
    try:
        # Precondition: the bug this guards against is now actually reachable.
        with pytest.raises(ModuleNotFoundError):
            importlib.import_module("junie_hermes.client")
        for name in [n for n in sys.modules if n.split(".")[0] == "junie_hermes"]:
            del sys.modules[name]
        yield plugin_dir
    finally:
        sys.path[:] = saved_path
        for name in [n for n in sys.modules if n.split(".")[0] == "junie_hermes"]:
            del sys.modules[name]
        sys.modules.update(saved_modules)


def test_create_client_works_when_loaded_as_a_plugin(plugin, plugin_dir_off_sys_path):
    """The regression that matters: with the plugin directory off ``sys.path``
    — as it is once installed — an absolute import of the plugin's own package
    raises ModuleNotFoundError. Only a relative import survives."""
    pytest.importorskip("acp")
    client = plugin.junie_acp.create_client(
        api_key="junie-acp",
        base_url="acp://junie",
        command="junie",
        args=["--acp=true"],
    )
    assert type(client).__name__ == "JunieACPClient"


def test_the_client_declares_the_acp_capability_flags(plugin):
    """Without these the auxiliary client re-dispatches an ACP shim through an
    HTTP wire adapter."""
    pytest.importorskip("acp")
    client = plugin.junie_acp.create_client(base_url="acp://junie", args=["--acp=true"])
    assert client.HERMES_SKIP_TRANSPORT_WRAP is True
    assert client.HERMES_SKIP_ASYNC_WRAP is True
    assert client.SUPPORTS_HERMES_TOOL_CALLS is True


# ── what the provider seam reads off the profile ─────────────────────────────


def test_it_is_an_external_process_provider(plugin):
    """Hermes keys credential and runtime resolution on this, not on the name."""
    assert plugin.junie_acp.auth_type == "external_process"
    assert plugin.junie_acp.base_url == "acp://junie"
    assert plugin.junie_acp.api_mode == "chat_completions"


def test_launch_metadata(plugin):
    profile = plugin.junie_acp
    assert profile.process_command == "junie"
    assert "--acp=true" in profile.process_args
    assert profile.process_command_env_vars == (
        "HERMES_JUNIE_ACP_COMMAND",
        "JUNIE_CLI_PATH",
    )
    assert profile.process_args_env_var == "HERMES_JUNIE_ACP_ARGS"


def test_the_profile_and_the_client_agree_on_the_default_args(plugin):
    """Two sources of truth for argv — the profile (used when Hermes launches)
    and the client fallback (used on direct construction). They must match, or
    the CLI starts differently depending on the entry point."""
    pytest.importorskip("acp")
    from junie_hermes.client import DEFAULT_ACP_ARGS

    assert tuple(plugin.junie_acp.process_args) == tuple(DEFAULT_ACP_ARGS)


def test_no_credential_env_vars_are_declared(plugin):
    """Auth belongs to the subprocess (JetBrains account, JUNIE_API_KEY, BYOK).
    Declaring env_vars here would make Hermes prompt for a key it never uses."""
    assert plugin.junie_acp.env_vars == ()


def test_there_is_no_rest_catalog(plugin):
    assert plugin.junie_acp.fetch_models() is None


def test_the_manifest_declares_the_provider_kind():
    """`hermes plugins install` only routes `kind: model-provider` to provider
    discovery; any other value and the plugin installs but never registers."""
    manifest = (PLUGIN_DIR / "plugin.yaml").read_text(encoding="utf-8")
    assert "kind: model-provider" in manifest
    assert "name: junie-acp" in manifest


def test_the_manifest_declares_the_hermes_floor():
    """The seam this plugin needs landed in Hermes 0.21.1 (v2026.9.7); an older
    Hermes cannot build a client from the profile."""
    manifest = (PLUGIN_DIR / "plugin.yaml").read_text(encoding="utf-8")
    assert 'requires_hermes: ">=0.21.1"' in manifest
