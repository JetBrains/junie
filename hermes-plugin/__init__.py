"""JetBrains Junie as a Hermes model provider, over the Agent Client Protocol.

Hermes spawns ``junie --acp=true`` and talks to it as an ACP *client*, so Junie
appears in ``/model`` and ``--provider`` like any other backend while still
running its own tools inside its own session.

Everything this needs from Hermes is public provider-plugin API — see
"External-process (ACP) providers" in Hermes' model-provider-plugin guide. The
profile declares how to launch the CLI and hands back its own client; Hermes
keys credential resolution, runtime resolution, the model picker and the
auxiliary client on ``auth_type``, not on a provider name. No Hermes edits.
"""

from typing import Any

from providers import register_provider
from providers.base import ProviderProfile


class JunieACPProfile(ProviderProfile):
    """JetBrains Junie ACP — external process, no REST models endpoint."""

    def create_client(self, **client_kwargs: Any) -> Any:
        """Build the ACP stdio shim instead of an HTTP client.

        Imported lazily: the profile is registered at discovery time, long
        before a turn runs, and the client pulls in the ACP SDK.

        Relative, not absolute: Hermes loads a plugin directory via
        ``spec_from_file_location`` with the directory as the package search
        path, so the plugin's own package is reachable as a submodule but is
        never placed on ``sys.path``.
        """
        from .junie_hermes.client import JunieACPClient

        return JunieACPClient(**client_kwargs)

    def fetch_models(
        self,
        *,
        api_key: str | None = None,
        base_url: str | None = None,
        timeout: float = 8.0,
    ) -> list[str] | None:
        """No REST catalog — Junie advertises its models over the ACP session."""
        return None


junie_acp = JunieACPProfile(
    name="junie-acp",
    aliases=("junie", "jetbrains-junie-acp", "junie-acp-agent"),
    display_name="JetBrains Junie (ACP)",
    description="JetBrains Junie coding agent, driven over the Agent Client Protocol",
    signup_url="https://junie.jetbrains.com/cli",
    # ACP subprocess, routed through chat_completions.
    api_mode="chat_completions",
    base_url="acp://junie",
    auth_type="external_process",
    # Credentials live with the subprocess: a JetBrains account login, a
    # JUNIE_API_KEY token, or BYOK. Nothing for Hermes to resolve.
    env_vars=(),
    # How to launch the CLI. Hermes reads these, applies the env overrides and
    # passes the result to create_client as command/args.
    process_command="junie",
    process_args=("--acp=true", "--skip-update-check"),
    process_command_env_vars=("HERMES_JUNIE_ACP_COMMAND", "JUNIE_CLI_PATH"),
    process_args_env_var="HERMES_JUNIE_ACP_ARGS",
)

register_provider(junie_acp)
