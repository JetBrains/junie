"""Tests for the JetBrains Junie ACP client shim.

The client drives a Junie agent subprocess over the Agent Client Protocol
Python SDK. The behaviour-critical paths (persistent-process reuse, model/brave
forwarding, no-replay-after-dispatch, fs/permission safety, tool activity) are
exercised end-to-end against ``fake_junie_acp_agent.py`` — a real subprocess
speaking ACP via the same SDK — rather than mocked, so the SDK wiring is under
test too. Pure helpers and the OpenAI-shape conversion are unit-tested directly.
"""
from __future__ import annotations

import asyncio
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

# The plugin ships its client as ``junie_hermes.client``; add the plugin root to
# sys.path so the suite runs standalone (`pytest hermes-plugin/tests`) as well as
# from a Hermes checkout that has the plugin installed.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import junie_hermes.client as junie_mod  # noqa: E402
from junie_hermes.client import (  # noqa: E402
    _DEFAULT_FORWARDED_TOOLS,
    JunieACPClient,
    _HermesClient,
    _build_subprocess_env,
    _choose_permission_option,
    _extract_model_ids,
    _format_messages_as_prompt,
    _format_tool_results_as_prompt,
    _merge_tool_update,
    _project_tool_events,
    _render_tool_activity,
    _resolve_args,
    _resolve_brave_override,
    _resolve_command,
    _resolve_forwarded_tools,
    _resolve_permission_policy,
    _with_auth,
    _trailing_tool_results,
    fetch_junie_models,
)

_FAKE_AGENT = str(Path(__file__).with_name("fake_junie_acp_agent.py"))


def _read_log(path: str) -> list[dict]:
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as fh:
        return [json.loads(line) for line in fh if line.strip()]


def _make_client(cwd: str, **kwargs) -> JunieACPClient:
    """A JunieACPClient wired to the in-repo fake agent, settling fast."""
    client = JunieACPClient(
        acp_cwd=cwd,
        command=sys.executable,
        args=[_FAKE_AGENT],
        **kwargs,
    )
    client._settle_quiet_gap = 0.05
    client._settle_max = 2.0
    return client


# --------------------------------------------------------------------------- #
# Pure launch / resolution helpers                                            #
# --------------------------------------------------------------------------- #
class JunieLaunchResolutionTests(unittest.TestCase):
    def test_default_command_and_args(self) -> None:
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(_resolve_command(), "junie")
            self.assertEqual(_resolve_args(), ["--acp=true", "--skip-update-check"])

    def test_command_override(self) -> None:
        with patch.dict(os.environ, {"HERMES_JUNIE_ACP_COMMAND": "/opt/junie"}, clear=True):
            self.assertEqual(_resolve_command(), "/opt/junie")
        with patch.dict(os.environ, {"JUNIE_CLI_PATH": "/usr/bin/junie"}, clear=True):
            self.assertEqual(_resolve_command(), "/usr/bin/junie")

    def test_auth_injected_from_env(self) -> None:
        with patch.dict(os.environ, {"JUNIE_API_KEY": "perm-token"}, clear=True):
            args = _with_auth(_resolve_args())
        self.assertIn("--auth", args)
        self.assertEqual(args[args.index("--auth") + 1], "perm-token")

    def test_auth_injected_whatever_the_args_came_from(self) -> None:
        """The provider profile supplies argv now, so injection cannot live in
        ``_resolve_args`` — args arriving from Hermes must still get the token."""
        with patch.dict(os.environ, {"JUNIE_API_KEY": "perm-token"}, clear=True):
            client = JunieACPClient(args=["--acp=true"])
        self.assertEqual(client._acp_args, ["--acp=true", "--auth", "perm-token"])

    def test_no_auth_arg_without_a_token(self) -> None:
        with patch.dict(os.environ, {}, clear=True):
            self.assertNotIn("--auth", _with_auth(["--acp=true"]))

    def test_explicit_auth_arg_not_double_injected(self) -> None:
        with patch.dict(
            os.environ,
            {"HERMES_JUNIE_ACP_ARGS": "--acp=true --auth explicit", "JUNIE_API_KEY": "perm-token"},
            clear=True,
        ):
            args = _with_auth(_resolve_args())
        self.assertEqual(args.count("--auth"), 1)
        self.assertIn("explicit", args)
        self.assertNotIn("perm-token", args)

    def test_explicit_auth_equals_form_not_double_injected(self) -> None:
        with patch.dict(os.environ, {"JUNIE_API_KEY": "perm-token"}, clear=True):
            args = _with_auth(["--acp=true", "--auth=explicit"])
        self.assertNotIn("perm-token", args)
        self.assertEqual(args.count("--auth=explicit"), 1)

    def test_default_policy_is_deny(self) -> None:
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(_resolve_permission_policy(), "deny")

    def test_permission_policy_env(self) -> None:
        with patch.dict(os.environ, {"HERMES_JUNIE_ACP_PERMISSION": "allow"}, clear=True):
            self.assertEqual(_resolve_permission_policy(), "allow")
        with patch.dict(os.environ, {"HERMES_JUNIE_ACP_PERMISSION": "deny"}, clear=True):
            self.assertEqual(_resolve_permission_policy(), "deny")

    def test_brave_override_env_parsing(self) -> None:
        for on in ("on", "1", "true", "yes"):
            with patch.dict(os.environ, {"HERMES_JUNIE_ACP_BRAVE": on}, clear=True):
                self.assertIs(_resolve_brave_override(), True)
        for off in ("off", "0", "false", "no"):
            with patch.dict(os.environ, {"HERMES_JUNIE_ACP_BRAVE": off}, clear=True):
                self.assertIs(_resolve_brave_override(), False)
        with patch.dict(os.environ, {}, clear=True):
            self.assertIsNone(_resolve_brave_override())

    def test_constructor_override_beats_env(self) -> None:
        with patch.dict(os.environ, {"HERMES_JUNIE_ACP_BRAVE": "off"}, clear=True):
            client = JunieACPClient(acp_cwd="/tmp", brave_mode=True)
        self.assertIs(client._brave_override, True)

    def test_brave_default_is_no_override(self) -> None:
        with patch.dict(os.environ, {}, clear=True):
            client = JunieACPClient(acp_cwd="/tmp")
        self.assertIsNone(client._brave_override)


# --------------------------------------------------------------------------- #
# Subprocess environment: Tier-1 secrets must never reach the agent           #
# --------------------------------------------------------------------------- #
class SubprocessEnvTests(unittest.TestCase):
    """Junie is a third-party model-driving subprocess.

    It legitimately needs LLM provider credentials (BYOK keys), so Tier-2 is
    inherited — but Tier-1 secrets (gateway bot tokens, GitHub auth, infra) have
    no business in it. A raw ``os.environ.copy()`` would hand over all of them,
    which is why this routes through ``hermes_subprocess_env`` like the sibling
    ACP client does.
    """

    _TIER1 = {
        "GITHUB_TOKEN": "ghp_should_not_leak",
        "GH_TOKEN": "gho_should_not_leak",
        "TELEGRAM_BOT_TOKEN": "123:should_not_leak",
        "SLACK_BOT_TOKEN": "xoxb-should-not-leak",
        "DISCORD_BOT_TOKEN": "discord_should_not_leak",
    }

    def test_tier1_secrets_are_stripped(self) -> None:
        with patch.dict(os.environ, self._TIER1, clear=False):
            env = _build_subprocess_env()
        leaked = sorted(k for k in self._TIER1 if k in env)
        self.assertEqual(leaked, [], f"Tier-1 secrets leaked to Junie: {leaked}")
        leaked_values = sorted(
            k for k, v in env.items() if isinstance(v, str) and "should_not_leak" in v
        )
        self.assertEqual(leaked_values, [], f"secret values leaked under: {leaked_values}")

    def test_provider_credentials_still_reach_junie(self) -> None:
        # Junie drives models itself: BYOK keys and its own token must survive,
        # otherwise the provider cannot authenticate at all.
        creds = {
            "JUNIE_API_KEY": "perm-junie-token",
            "ANTHROPIC_API_KEY": "sk-ant-byok",
            "OPENAI_API_KEY": "sk-openai-byok",
        }
        with patch.dict(os.environ, creds, clear=False):
            env = _build_subprocess_env()
        for key, value in creds.items():
            self.assertEqual(env.get(key), value, f"{key} did not reach Junie")

    def test_home_is_always_set(self) -> None:
        with patch.dict(os.environ, {}, clear=False):
            env = _build_subprocess_env()
        self.assertTrue(env.get("HOME"), "child process needs a writable HOME")


# --------------------------------------------------------------------------- #
# Permission-option selection (pure)                                          #
# --------------------------------------------------------------------------- #
class ChoosePermissionOptionTests(unittest.TestCase):
    _ALLOW_ONCE = [{"optionId": "yes", "name": "Allow", "kind": "allow_once"}]

    def test_deny_policy_never_selects(self) -> None:
        self.assertIsNone(_choose_permission_option(self._ALLOW_ONCE, "deny"))

    def test_allow_selects_allow_once(self) -> None:
        self.assertEqual(_choose_permission_option(self._ALLOW_ONCE, "allow"), "yes")

    def test_allow_without_allow_option_returns_none(self) -> None:
        opts = [{"optionId": "no", "name": "Deny", "kind": "reject_once"}]
        self.assertIsNone(_choose_permission_option(opts, "allow"))

    def test_allow_prefers_allow_once_over_allow_always(self) -> None:
        opts = [
            {"optionId": "always", "kind": "allow_always"},  # listed first
            {"optionId": "once", "kind": "allow_once"},
        ]
        self.assertEqual(_choose_permission_option(opts, "allow"), "once")


# --------------------------------------------------------------------------- #
# Client-side ACP callbacks (fs + permission bridge), tested directly         #
# --------------------------------------------------------------------------- #
class HermesClientHandlerTests(unittest.TestCase):
    def _handler(self, cwd: str, policy: str = "deny") -> _HermesClient:
        return _HermesClient(cwd=cwd, permission_policy=policy)

    def test_request_permission_denies_by_default(self) -> None:
        from acp.schema import PermissionOption, ToolCallUpdate

        h = self._handler("/tmp", policy="deny")
        resp = asyncio.run(h.request_permission(
            options=[PermissionOption(kind="allow_once", name="Allow", option_id="yes")],
            session_id="s",
            tool_call=ToolCallUpdate(tool_call_id="t", title="x"),
        ))
        self.assertEqual(resp.outcome.model_dump(by_alias=True)["outcome"], "cancelled")

    def test_request_permission_allow_selects_option(self) -> None:
        from acp.schema import PermissionOption, ToolCallUpdate

        h = self._handler("/tmp", policy="allow")
        resp = asyncio.run(h.request_permission(
            options=[PermissionOption(kind="allow_once", name="Allow", option_id="yes")],
            session_id="s",
            tool_call=ToolCallUpdate(tool_call_id="t", title="x"),
        ))
        dumped = resp.outcome.model_dump(by_alias=True)
        self.assertEqual(dumped["outcome"], "selected")
        self.assertEqual(dumped["optionId"], "yes")

    def test_read_text_file_redacts_sensitive_content(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            secret = root / "config.env"
            secret.write_text("OPENAI_API_KEY=sk-proj-abc123def456ghi789jkl012")
            h = self._handler(str(root))
            with patch("agent.redact._REDACT_ENABLED", True):
                resp = asyncio.run(h.read_text_file(path=str(secret), session_id="s"))
        self.assertNotIn("abc123def456", resp.content)
        self.assertIn("OPENAI_API_KEY=", resp.content)

    def test_read_text_file_honors_limit_at_top(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            f = root / "big.txt"
            f.write_text("".join(f"line{i}\n" for i in range(100)))
            h = self._handler(str(root))
            with patch("agent.redact._REDACT_ENABLED", False):
                resp = asyncio.run(h.read_text_file(path=str(f), session_id="s", line=1, limit=3))
        self.assertEqual(resp.content, "line0\nline1\nline2\n")

    def test_read_outside_cwd_is_rejected(self) -> None:
        from acp.exceptions import RequestError

        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir) / "workspace"
            root.mkdir()
            outside = Path(tmpdir) / "secret.txt"
            outside.write_text("nope")
            h = self._handler(str(root))
            with self.assertRaises(RequestError):
                asyncio.run(h.read_text_file(path=str(outside), session_id="s"))

    def test_write_text_file_respects_safe_root(self) -> None:
        from acp.exceptions import RequestError

        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            safe_root = root / "workspace"
            safe_root.mkdir()
            outside = root / "outside.txt"
            h = self._handler(str(root))
            with patch.dict(os.environ, {"HERMES_WRITE_SAFE_ROOT": str(safe_root)}, clear=False):
                with self.assertRaises(RequestError):
                    asyncio.run(h.write_text_file(content="should-not-write", path=str(outside), session_id="s"))
            self.assertFalse(outside.exists())


# --------------------------------------------------------------------------- #
# OpenAI-shape conversion (patch the ACP turn, assert the response mapping)   #
# --------------------------------------------------------------------------- #
class OpenAIShapeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.client = JunieACPClient(acp_cwd="/tmp")

    def test_completion_never_fabricates_openai_tool_calls(self) -> None:
        events: dict = {}
        _merge_tool_update(events, {
            "sessionUpdate": "tool_call", "toolCallId": "t1", "title": 'Found "*"',
            "kind": "other", "status": "pending",
        })
        _merge_tool_update(events, {
            "sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "completed",
            "content": [{"type": "content", "content": {"type": "text", "text": "gamma.log\n"}}],
        })
        with patch.object(self.client, "_run_prompt", return_value=("Here are the files.", "", events, None)):
            resp = self.client._create_chat_completion(model="junie-acp", messages=[])
        choice = resp.choices[0]
        self.assertEqual(choice.finish_reason, "stop")
        self.assertEqual(choice.message.tool_calls, [])
        self.assertEqual(choice.message.content, "Here are the files.")
        self.assertIn("Junie tool activity", choice.message.reasoning)
        self.assertIn("gamma.log", choice.message.reasoning)

    def test_usage_prefers_reported_counts(self) -> None:
        from types import SimpleNamespace
        reported = SimpleNamespace(input_tokens=123, output_tokens=45, thought_tokens=5, cached_read_tokens=10)
        with patch.object(self.client, "_run_prompt", return_value=("resp", "", {}, reported)):
            resp = self.client._create_chat_completion(model="junie-acp", messages=[{"role": "user", "content": "q"}])
        u = resp.usage
        self.assertEqual(u.prompt_tokens, 123)
        self.assertEqual(u.completion_tokens, 50)  # output + thought
        self.assertEqual(u.total_tokens, 173)
        self.assertEqual(u.prompt_tokens_details.cached_tokens, 10)

    def test_usage_falls_back_to_estimate(self) -> None:
        with patch.object(self.client, "_run_prompt", return_value=("some response text here", "", {}, None)):
            resp = self.client._create_chat_completion(
                model="junie-acp",
                messages=[{"role": "user", "content": "a fairly long user question to size the prompt"}],
            )
        u = resp.usage
        self.assertGreater(u.prompt_tokens, 0)
        self.assertGreater(u.completion_tokens, 0)
        self.assertEqual(u.total_tokens, u.prompt_tokens + u.completion_tokens)

    def test_hermes_tool_call_blocks_are_parsed_from_response(self) -> None:
        """Junie delegating a HERMES tool must reach Hermes' dispatcher.

        This is the other half of the invariant above: Junie's own (already
        executed) activity is never a pending tool_call, but a <tool_call> block
        Junie emits IS a delegation — without it, memory/todo/skill_manage are
        unreachable for the whole session.
        """
        text = (
            'Saving that.\n<tool_call>{"id":"c1","type":"function","function":'
            '{"name":"memory","arguments":"{\\"action\\":\\"add\\"}"}}</tool_call>'
        )
        with patch.object(self.client, "_run_prompt", return_value=(text, "", {}, None)):
            resp = self.client._create_chat_completion(model="junie-acp", messages=[])
        choice = resp.choices[0]
        self.assertEqual(choice.finish_reason, "tool_calls")
        self.assertEqual(len(choice.message.tool_calls), 1)
        call = choice.message.tool_calls[0]
        self.assertEqual(call.function.name, "memory")
        self.assertEqual(call.function.arguments, '{"action":"add"}')
        # The raw block is stripped from the user-visible content.
        self.assertNotIn("<tool_call>", choice.message.content)
        self.assertIn("Saving that.", choice.message.content)


    def test_native_activity_is_projected_into_the_transcript(self) -> None:
        """The review fork learns from `messages`, not from `reasoning`.

        Junie's real work must land as completed assistant(tool_call)+tool(result)
        rows so the self-improvement loop replays substance instead of a one-line
        activity feed.
        """
        events: dict = {}
        _merge_tool_update(events, {
            "sessionUpdate": "tool_call", "toolCallId": "t1", "title": "Edit main.py",
            "kind": "edit", "status": "pending",
            "rawInput": {"path": "main.py", "patch": "-a\n+b"},
        })
        _merge_tool_update(events, {
            "sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "completed",
            "content": [{"type": "content", "content": {"type": "text", "text": "1 file changed"}}],
        })
        with patch.object(self.client, "_run_prompt", return_value=("Done.", "", events, None)):
            resp = self.client._create_chat_completion(model="junie-acp", messages=[])

        projected = resp.hermes_projected_messages
        self.assertEqual(len(projected), 2)
        assistant, tool = projected
        self.assertEqual(assistant["role"], "assistant")
        self.assertIsNone(assistant["content"])
        call = assistant["tool_calls"][0]
        self.assertEqual(call["function"]["name"], "junie_edit")
        args = json.loads(call["function"]["arguments"])
        self.assertEqual(args["path"], "main.py")
        self.assertEqual(args["title"], "Edit main.py")
        self.assertIn("+b", args["patch"])
        self.assertEqual(tool["role"], "tool")
        self.assertEqual(tool["tool_call_id"], call["id"])
        self.assertIn("1 file changed", tool["content"])
        # Junie's toolCallId is only unique inside its session, and Hermes opens
        # one session per user turn — the projected id must be namespaced so the
        # transcript can't end up with duplicate tool_call ids.
        self.assertTrue(call["id"].startswith("junie_"), call["id"])
        self.assertNotEqual(call["id"], "t1")
        # Still not a pending tool call, and it ticks the skill-review counter.
        self.assertEqual(resp.choices[0].message.tool_calls, [])
        self.assertEqual(resp.hermes_provider_tool_iterations, 1)

    def test_failed_activity_keeps_its_status_in_the_projection(self) -> None:
        events: dict = {}
        _merge_tool_update(events, {
            "sessionUpdate": "tool_call", "toolCallId": "t9", "title": "Run tests",
            "kind": "execute", "status": "failed",
            "rawOutput": {"exitCode": 1, "stderr": "2 failed"},
        })
        with patch.object(self.client, "_run_prompt", return_value=("Failed.", "", events, None)):
            resp = self.client._create_chat_completion(model="junie-acp", messages=[])
        tool = resp.hermes_projected_messages[1]
        self.assertIn("[status failed]", tool["content"])
        self.assertIn("2 failed", tool["content"])

    def test_stream_true_returns_chunks_that_still_carry_the_projection(self) -> None:
        """``stream=True`` (MoA / auxiliary paths) must not drop the extras.

        An ACP turn is one-shot, so streaming is a re-shape — but a plain list of
        chunks would silently lose ``hermes_projected_messages``, i.e. exactly the
        transcript substance the self-improvement loop needs.
        """
        events: dict = {}
        _merge_tool_update(events, {
            "sessionUpdate": "tool_call", "toolCallId": "t1", "title": "Run tests",
            "kind": "execute", "status": "completed",
            "content": [{"type": "content", "content": {"type": "text", "text": "3 passed"}}],
        })
        text = (
            'Ran them.\n<tool_call>{"id":"c1","type":"function","function":'
            '{"name":"todo","arguments":"{}"}}</tool_call>'
        )
        with patch.object(self.client, "_run_prompt", return_value=(text, "", events, None)):
            chunks = self.client._create_chat_completion(
                model="junie-acp", messages=[], stream=True
            )
        self.assertEqual(len(list(chunks)), 2)  # data chunk + usage chunk
        delta = chunks[0].choices[0].delta
        self.assertEqual(chunks[0].choices[0].finish_reason, "tool_calls")
        self.assertEqual(delta.tool_calls[0].function.name, "todo")
        self.assertIn("Ran them.", delta.content)
        self.assertIsNotNone(chunks[1].usage)
        # The extras survive the re-shape.
        self.assertEqual(len(chunks.hermes_projected_messages), 2)
        self.assertEqual(chunks.hermes_provider_tool_iterations, 1)

    def test_no_activity_means_no_projection_and_no_counter_tick(self) -> None:
        with patch.object(self.client, "_run_prompt", return_value=("hi", "", {}, None)):
            resp = self.client._create_chat_completion(model="junie-acp", messages=[])
        self.assertEqual(resp.hermes_projected_messages, [])
        self.assertEqual(resp.hermes_provider_tool_iterations, 0)


# --------------------------------------------------------------------------- #
# Hermes tool bridge: forwarded-tool allowlist + continuation prompts         #
# --------------------------------------------------------------------------- #
class ToolBridgeTests(unittest.TestCase):
    _TOOLS = [
        {"type": "function", "function": {"name": "memory", "description": "remember", "parameters": {}}},
        {"type": "function", "function": {"name": "skill_manage", "description": "skills", "parameters": {}}},
        {"type": "function", "function": {"name": "todo", "description": "todos", "parameters": {}}},
        {"type": "function", "function": {"name": "execute_command", "description": "shell", "parameters": {}}},
    ]

    def test_default_allowlist_is_agent_level_only(self) -> None:
        with patch.dict(os.environ, {}, clear=True):
            forwarded = _resolve_forwarded_tools()
        # Hermes' agent-level surface: the memory/skill self-improvement loop
        # (writes AND the reads a review needs to update the right skill) plus
        # todo. Junie's own read/edit/execute capabilities are NOT re-offered.
        self.assertEqual(
            forwarded,
            frozenset({"memory", "todo", "skill_manage", "skill_view", "skills_list"}),
        )

    def test_allowlist_env_overrides(self) -> None:
        with patch.dict(os.environ, {"HERMES_JUNIE_ACP_FORWARD_TOOLS": "all"}, clear=True):
            self.assertIsNone(_resolve_forwarded_tools())
        with patch.dict(os.environ, {"HERMES_JUNIE_ACP_FORWARD_TOOLS": "none"}, clear=True):
            self.assertEqual(_resolve_forwarded_tools(), frozenset())
        with patch.dict(os.environ, {"HERMES_JUNIE_ACP_FORWARD_TOOLS": "memory, todo"}, clear=True):
            self.assertEqual(_resolve_forwarded_tools(), frozenset({"memory", "todo"}))

    def test_settings_come_from_config_yaml(self) -> None:
        """Behavioral settings are config.yaml-backed; .env is for secrets only."""
        cfg = {
            "junie_acp": {
                "permission": "allow",
                "brave_mode": False,
                "forwarded_tools": ["memory", "todo"],
                "command": "/opt/junie/bin/junie",
                "args": ["--acp=true", "--quiet"],
            }
        }
        with patch.dict(os.environ, {}, clear=True), patch(
            "hermes_cli.config.load_config_readonly", return_value=cfg
        ):
            self.assertEqual(_resolve_permission_policy(), "allow")
            self.assertIs(_resolve_brave_override(), False)
            self.assertEqual(_resolve_forwarded_tools(), frozenset({"memory", "todo"}))
            self.assertEqual(_resolve_command(), "/opt/junie/bin/junie")
            self.assertEqual(_resolve_args(), ["--acp=true", "--quiet"])

    def test_registered_defaults_do_not_disable_the_bridge(self) -> None:
        """Empty config values must not change behavior.

        A ``junie_acp:`` block written out with blank placeholders — by a
        template, a `hermes config` round-trip, or a user commenting values out
        — must read as "unset". Taken literally, ``forwarded_tools: []`` would
        disable the tool bridge (the exact defect this provider was reviewed
        for) and ``args: []`` would launch Junie without ``--acp=true``.
        """
        blank = {
            "command": "",
            "args": [],
            "permission": "",
            "brave": "",
            "forwarded_tools": [],
        }
        with patch.dict(os.environ, {}, clear=True), patch(
            "hermes_cli.config.load_config_readonly",
            return_value={"junie_acp": blank},
        ):
            self.assertEqual(
                _resolve_forwarded_tools(), frozenset(_DEFAULT_FORWARDED_TOOLS)
            )
            self.assertEqual(_resolve_args()[:2], ["--acp=true", "--skip-update-check"])
            self.assertEqual(_resolve_command(), "junie")
            self.assertEqual(_resolve_permission_policy(), "deny")
            self.assertIsNone(_resolve_brave_override())

    def test_env_bridge_wins_over_config(self) -> None:
        # The env names stay as an internal bridge for a one-off run: narrower
        # scope wins, but config.yaml is the documented surface.
        cfg = {"junie_acp": {"permission": "deny", "forwarded_tools": "none"}}
        with patch.dict(
            os.environ,
            {"HERMES_JUNIE_ACP_PERMISSION": "allow",
             "HERMES_JUNIE_ACP_FORWARD_TOOLS": "memory"},
            clear=True,
        ), patch("hermes_cli.config.load_config_readonly", return_value=cfg):
            self.assertEqual(_resolve_permission_policy(), "allow")
            self.assertEqual(_resolve_forwarded_tools(), frozenset({"memory"}))

    def test_config_all_and_none_keywords(self) -> None:
        for value, expected in (("all", None), ("none", frozenset())):
            with patch.dict(os.environ, {}, clear=True), patch(
                "hermes_cli.config.load_config_readonly",
                return_value={"junie_acp": {"forwarded_tools": value}},
            ):
                self.assertEqual(_resolve_forwarded_tools(), expected)

    def test_prompt_forwards_agent_level_tools_but_not_junies_own_work(self) -> None:
        prompt = _format_messages_as_prompt(
            [{"role": "user", "content": "hi"}],
            model="junie-acp",
            tools=self._TOOLS,
            forwarded_tools=frozenset({"memory", "todo", "skill_manage"}),
        )
        self.assertIn("<tool_call>", prompt)
        self.assertIn('"name": "memory"', prompt)
        self.assertIn('"name": "skill_manage"', prompt)
        # Re-offering Junie's own capabilities would make Hermes re-run finished work.
        self.assertNotIn("execute_command", prompt)

    def test_prompt_omits_the_bridge_when_nothing_is_forwarded(self) -> None:
        prompt = _format_messages_as_prompt(
            [{"role": "user", "content": "hi"}],
            tools=self._TOOLS,
            forwarded_tools=frozenset(),
        )
        self.assertNotIn("<tool_call>", prompt)
        self.assertNotIn("memory", prompt)

    def test_trailing_tool_results_detects_a_mid_turn_continuation(self) -> None:
        self.assertEqual(_trailing_tool_results([{"role": "user", "content": "q"}]), [])
        msgs = [
            {"role": "user", "content": "q"},
            {"role": "assistant", "content": None, "tool_calls": [{"id": "c1"}]},
            {"role": "tool", "tool_call_id": "c1", "content": "saved"},
            {"role": "tool", "tool_call_id": "c2", "content": "also saved"},
        ]
        trailing = _trailing_tool_results(msgs)
        self.assertEqual([m["tool_call_id"] for m in trailing], ["c1", "c2"])

    def test_projected_rows_do_not_look_like_a_continuation(self) -> None:
        # Junie's own projected activity ends in a tool row too, but Junie is not
        # waiting on it — treating it as a continuation would tell Junie "here
        # are your results" about work it already did itself. Recognised by the
        # namespaced tool name, so nothing non-standard travels on the wire.
        msgs = [
            {"role": "user", "content": "q"},
            {"role": "assistant", "content": None,
             "tool_calls": [{"id": "j1", "type": "function",
                             "function": {"name": "junie_edit", "arguments": "{}"}}]},
            {"role": "tool", "tool_call_id": "j1", "name": "junie_edit", "content": "1 file changed"},
        ]
        self.assertEqual(_trailing_tool_results(msgs), [])

    def test_reloaded_session_keeps_the_projection_marker(self) -> None:
        # A session restored from the DB carries the tool name under
        # ``tool_name`` rather than ``name`` (hermes_state), so the filter must
        # recognise both spellings.
        msgs = [
            {"role": "user", "content": "q"},
            {"role": "tool", "tool_call_id": "j1", "tool_name": "junie_execute",
             "content": "tests passed"},
        ]
        self.assertEqual(_trailing_tool_results(msgs), [])

    def test_continuation_prompt_carries_results_not_the_transcript(self) -> None:
        prompt = _format_tool_results_as_prompt(
            [{"role": "tool", "tool_call_id": "c1", "name": "memory", "content": "saved"}]
        )
        self.assertIn("saved", prompt)
        self.assertIn("memory", prompt)
        self.assertIn("Do NOT redo any work", prompt)


# --------------------------------------------------------------------------- #
# Native tool-activity helpers                                                #
# --------------------------------------------------------------------------- #
class ToolActivityHelperTests(unittest.TestCase):
    def test_tool_call_then_update_merge_by_id(self) -> None:
        events: dict = {}
        _merge_tool_update(events, {
            "sessionUpdate": "tool_call", "toolCallId": "id1", "title": 'Found "*"',
            "kind": "other", "status": "pending",
        })
        _merge_tool_update(events, {
            "sessionUpdate": "tool_call_update", "toolCallId": "id1", "status": "completed",
            "content": [{"type": "content", "content": {"type": "text", "text": "alpha\ngamma.log\n"}}],
        })
        self.assertEqual(len(events), 1)
        ev = events["id1"]
        self.assertEqual(ev["status"], "completed")
        self.assertEqual(ev["kind"], "other")
        self.assertEqual(ev["title"], 'Found "*"')
        self.assertIn("gamma.log", ev["result"])

    def test_render_tool_activity_is_readable(self) -> None:
        events: dict = {}
        _merge_tool_update(events, {"sessionUpdate": "tool_call", "toolCallId": "id1",
                                    "title": "list", "kind": "other", "status": "completed",
                                    "content": [{"type": "content", "content": {"type": "text", "text": "gamma.log"}}]})
        rendered = _render_tool_activity(events)
        self.assertIn("[other]", rendered)
        self.assertIn("completed", rendered)
        self.assertIn("gamma.log", rendered)


# --------------------------------------------------------------------------- #
# End-to-end against the fake ACP agent subprocess                            #
# --------------------------------------------------------------------------- #
class JunieEndToEndTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.cwd = self._tmp.name
        self.log = os.path.join(self.cwd, "calls.log")

    def _client(self, **kwargs) -> JunieACPClient:
        client = _make_client(self.cwd, **kwargs)
        self.addCleanup(client.close)
        return client

    def _ask(self, client: JunieACPClient, text: str, model: str = "junie-acp"):
        return client.chat.completions.create(
            model=model, messages=[{"role": "user", "content": text}], timeout=30
        )

    def test_process_reused_across_two_calls(self) -> None:
        with patch.dict(os.environ, {"FAKE_JUNIE_LOG": self.log}, clear=False):
            client = self._client()
            r1 = self._ask(client, "hi 1")
            r2 = self._ask(client, "hi 2")
        self.assertEqual(r1.choices[0].message.content, "ANSWER1")
        self.assertEqual(r2.choices[0].message.content, "ANSWER2")
        self.assertEqual(r1.choices[0].finish_reason, "stop")
        log = _read_log(self.log)
        self.assertEqual(sum(1 for e in log if e["method"] == "initialize"), 1)
        self.assertEqual(sum(1 for e in log if e["method"] == "session/new"), 2)
        self.assertEqual(sum(1 for e in log if e["method"] == "session/prompt"), 2)

    def test_dead_process_is_respawned(self) -> None:
        with patch.dict(os.environ, {"FAKE_JUNIE_LOG": self.log, "FAKE_JUNIE_EXIT_AFTER_PROMPT": "1"}, clear=False):
            client = self._client()
            r1 = self._ask(client, "x")
            self.assertEqual(r1.choices[0].message.content, "ANSWER1")
            r2 = self._ask(client, "y")
        # Fresh process → its own counter restarts at 1.
        self.assertEqual(r2.choices[0].message.content, "ANSWER1")
        log = _read_log(self.log)
        self.assertEqual(sum(1 for e in log if e["method"] == "initialize"), 2)

    def test_real_model_is_forwarded_via_set_config_option(self) -> None:
        with patch.dict(os.environ, {"FAKE_JUNIE_LOG": self.log}, clear=False):
            client = self._client()
            self._ask(client, "x", model="claude-opus-4-8")
        sets = [(e.get("configId"), e.get("value")) for e in _read_log(self.log)
                if e["method"] == "session/set_config_option"]
        self.assertIn(("model", "claude-opus-4-8"), sets)

    def test_provider_sentinel_model_is_not_forwarded(self) -> None:
        for sentinel in ("junie-acp", "junie", "jetbrains-junie-acp", "junie-acp-agent", ""):
            log = os.path.join(self.cwd, f"calls_{sentinel or 'empty'}.log")
            with patch.dict(os.environ, {"FAKE_JUNIE_LOG": log}, clear=False):
                client = self._client()
                self._ask(client, "x", model=sentinel)
                client.close()
            model_sets = [e for e in _read_log(log)
                          if e["method"] == "session/set_config_option" and e.get("configId") == "model"]
            self.assertFalse(model_sets, f"sentinel {sentinel!r} should not set a model")

    def test_model_set_failure_does_not_abort_turn(self) -> None:
        with patch.dict(os.environ, {"FAKE_JUNIE_LOG": self.log, "FAKE_JUNIE_FAIL_MODEL": "1"}, clear=False):
            client = self._client()
            resp = self._ask(client, "x", model="no-such-model")
        self.assertEqual(resp.choices[0].message.content, "ANSWER1")
        self.assertEqual(resp.choices[0].finish_reason, "stop")

    def test_brave_override_sends_set_config_option(self) -> None:
        with patch.dict(os.environ, {"FAKE_JUNIE_LOG": self.log}, clear=False):
            client = self._client(brave_mode=False)
            self._ask(client, "x")
        sets = [(e.get("configId"), e.get("value")) for e in _read_log(self.log)
                if e["method"] == "session/set_config_option"]
        self.assertIn(("brave_mode", False), sets)

    def test_no_replay_after_prompt_dispatch(self) -> None:
        with patch.dict(os.environ, {"FAKE_JUNIE_LOG": self.log, "FAKE_JUNIE_FAIL_PROMPT": "1"}, clear=False):
            client = self._client()
            with self.assertRaises(RuntimeError):
                self._ask(client, "x")
        log = _read_log(self.log)
        self.assertEqual(sum(1 for e in log if e["method"] == "session/prompt"), 1)   # dispatched once
        self.assertEqual(sum(1 for e in log if e["method"] == "initialize"), 1)        # no respawn

    def test_retry_before_prompt_respawns(self) -> None:
        sentinel = os.path.join(self.cwd, "session_new.sentinel")
        with patch.dict(os.environ, {
            "FAKE_JUNIE_LOG": self.log,
            "FAKE_JUNIE_FAIL_SESSION_NEW_ONCE": "1",
            "FAKE_JUNIE_SESSION_SENTINEL": sentinel,
        }, clear=False):
            client = self._client()
            resp = self._ask(client, "x")
        self.assertEqual(resp.choices[0].message.content, "ANSWER1")
        log = _read_log(self.log)
        self.assertEqual(sum(1 for e in log if e["method"] == "initialize"), 2)  # respawned
        self.assertEqual(sum(1 for e in log if e["method"] == "session/prompt"), 1)

    def test_tool_activity_surfaced_as_reasoning_not_tool_calls(self) -> None:
        with patch.dict(os.environ, {"FAKE_JUNIE_LOG": self.log, "FAKE_JUNIE_EMIT_TOOLCALL": "1"}, clear=False):
            client = self._client()
            resp = self._ask(client, "list files")
        choice = resp.choices[0]
        self.assertEqual(choice.message.tool_calls, [])
        self.assertIn("Junie tool activity", choice.message.reasoning or "")
        self.assertIn("gamma.log", choice.message.reasoning or "")

    def test_hermes_tool_call_then_continuation_reuses_the_session(self) -> None:
        """A tool-bridge turn must not restart Junie's task.

        Hermes runs the delegated tool and calls back with the result. Opening a
        fresh session and replaying the transcript would make Junie redo the
        coding work it already finished, so the continuation reuses the live
        session and carries only the results.
        """
        with patch.dict(os.environ, {
            "FAKE_JUNIE_LOG": self.log,
            "FAKE_JUNIE_EMIT_HERMES_TOOL_CALL": "1",
        }, clear=False):
            client = self._client()
            first = client.chat.completions.create(
                model="junie-acp",
                messages=[{"role": "user", "content": "remember this"}],
                tools=[{"type": "function", "function": {
                    "name": "memory", "description": "remember", "parameters": {}}}],
                timeout=30,
            )
            self.assertEqual(first.choices[0].finish_reason, "tool_calls")
            call = first.choices[0].message.tool_calls[0]
            self.assertEqual(call.function.name, "memory")

            second = client.chat.completions.create(
                model="junie-acp",
                messages=[
                    {"role": "user", "content": "remember this"},
                    {"role": "assistant", "content": "", "tool_calls": [{"id": call.id}]},
                    {"role": "tool", "tool_call_id": call.id, "name": "memory",
                     "content": "memory saved"},
                ],
                timeout=30,
            )

        self.assertEqual(second.choices[0].finish_reason, "stop")
        log = _read_log(self.log)
        prompts = [e for e in log if e["method"] == "session/prompt"]
        self.assertEqual(len(prompts), 2)
        # One session for both prompts — the continuation reused it.
        self.assertEqual(sum(1 for e in log if e["method"] == "session/new"), 1)
        self.assertEqual(prompts[0]["session"], prompts[1]["session"])
        # And it carried the result instead of replaying the conversation.
        self.assertIn("memory saved", prompts[1]["text"])
        self.assertNotIn("Conversation transcript", prompts[1]["text"])

    def test_rejected_reused_session_falls_back_instead_of_failing_the_turn(self) -> None:
        """Session reuse must not make a turn fail harder than before.

        Junie may have reaped the session between prompts. The rejection arrives
        before Junie does anything — no update, no permission prompt, no fs call —
        so the client retries with the full transcript in a fresh session rather
        than surfacing an error. (A failure AFTER Junie acted is still never
        replayed; see test_no_replay_after_prompt_dispatch.)
        """
        with patch.dict(os.environ, {
            "FAKE_JUNIE_LOG": self.log,
            "FAKE_JUNIE_EMIT_HERMES_TOOL_CALL": "1",
            "FAKE_JUNIE_REJECT_REUSED_SESSION": "1",
        }, clear=False):
            client = self._client()
            first = client.chat.completions.create(
                model="junie-acp",
                messages=[{"role": "user", "content": "remember this"}],
                tools=[{"type": "function", "function": {
                    "name": "memory", "description": "remember", "parameters": {}}}],
                timeout=30,
            )
            call = first.choices[0].message.tool_calls[0]
            second = client.chat.completions.create(
                model="junie-acp",
                messages=[
                    {"role": "user", "content": "remember this"},
                    {"role": "assistant", "content": "", "tool_calls": [{"id": call.id}]},
                    {"role": "tool", "tool_call_id": call.id, "name": "memory", "content": "saved"},
                ],
                timeout=30,
            )
        # The turn recovered rather than raising.
        self.assertIsNotNone(second.choices[0].message)
        log = _read_log(self.log)
        rejected = [e for e in log if e.get("result") == "unknown-session"]
        self.assertTrue(rejected, "the reused session should have been rejected once")
        # …by respawning and replaying the transcript into a brand-new session.
        self.assertEqual(sum(1 for e in log if e["method"] == "initialize"), 2)
        accepted = [e for e in log if e["method"] == "session/prompt" and "text" in e]
        self.assertIn("Conversation transcript", accepted[-1]["text"])

    def test_unrelated_trailing_tool_row_does_not_reuse_the_session(self) -> None:
        """Only results Junie actually asked for may re-enter its session.

        A history that merely ENDS with a tool row (session resume, host-fed
        transcript) must not be delivered to a live session as "here are your
        results" for work Junie never requested.
        """
        with patch.dict(os.environ, {
            "FAKE_JUNIE_LOG": self.log,
            "FAKE_JUNIE_EMIT_HERMES_TOOL_CALL": "1",
        }, clear=False):
            client = self._client()
            first = client.chat.completions.create(
                model="junie-acp",
                messages=[{"role": "user", "content": "remember this"}],
                tools=[{"type": "function", "function": {
                    "name": "memory", "description": "remember", "parameters": {}}}],
                timeout=30,
            )
            self.assertTrue(first.choices[0].message.tool_calls)
            # A tool row whose id Junie never requested.
            client.chat.completions.create(
                model="junie-acp",
                messages=[
                    {"role": "user", "content": "unrelated older turn"},
                    {"role": "tool", "tool_call_id": "someone-elses-call", "content": "stale"},
                ],
                timeout=30,
            )
        log = _read_log(self.log)
        self.assertEqual(sum(1 for e in log if e["method"] == "session/new"), 2)
        prompts = [e for e in log if e["method"] == "session/prompt"]
        self.assertNotEqual(prompts[0]["session"], prompts[1]["session"])
        self.assertIn("Conversation transcript", prompts[1]["text"])

    def test_continuation_falls_back_to_full_prompt_without_a_live_session(self) -> None:
        # No prior turn on this client → nothing to reuse. The tool results must
        # not be sent bare into a session that has no idea what they belong to.
        with patch.dict(os.environ, {"FAKE_JUNIE_LOG": self.log}, clear=False):
            client = self._client()
            client.chat.completions.create(
                model="junie-acp",
                messages=[
                    {"role": "user", "content": "do the thing"},
                    {"role": "tool", "tool_call_id": "c1", "content": "result"},
                ],
                timeout=30,
            )
        prompts = [e for e in _read_log(self.log) if e["method"] == "session/prompt"]
        self.assertEqual(len(prompts), 1)
        self.assertIn("Conversation transcript", prompts[0]["text"])
        self.assertIn("do the thing", prompts[0]["text"])

    def test_thought_chunk_surfaced_as_reasoning(self) -> None:
        with patch.dict(os.environ, {"FAKE_JUNIE_LOG": self.log, "FAKE_JUNIE_EMIT_THOUGHT": "1"}, clear=False):
            client = self._client()
            resp = self._ask(client, "think")
        self.assertIn("thinking...", resp.choices[0].message.reasoning or "")

    def test_usage_from_prompt_response(self) -> None:
        with patch.dict(os.environ, {"FAKE_JUNIE_LOG": self.log, "FAKE_JUNIE_USAGE": "1"}, clear=False):
            client = self._client()
            resp = self._ask(client, "x")
        self.assertEqual(resp.usage.prompt_tokens, 123)
        self.assertEqual(resp.usage.completion_tokens, 45)

    def test_permission_bridge_denies_by_default(self) -> None:
        with patch.dict(os.environ, {"FAKE_JUNIE_LOG": self.log, "FAKE_JUNIE_ASK_PERMISSION": "1"}, clear=False):
            client = self._client()  # default policy: deny
            self._ask(client, "x")
        outcomes = [e["outcome"] for e in _read_log(self.log) if e["method"] == "permission_outcome"]
        self.assertTrue(outcomes)
        self.assertEqual(outcomes[0]["outcome"], "cancelled")

    def test_permission_bridge_allows_when_policy_allow(self) -> None:
        with patch.dict(os.environ, {"FAKE_JUNIE_LOG": self.log, "FAKE_JUNIE_ASK_PERMISSION": "1"}, clear=False):
            client = self._client(permission_policy="allow")
            self._ask(client, "x")
        outcomes = [e["outcome"] for e in _read_log(self.log) if e["method"] == "permission_outcome"]
        self.assertTrue(outcomes)
        self.assertEqual(outcomes[0]["outcome"], "selected")
        self.assertEqual(outcomes[0]["optionId"], "yes")

    def test_fs_read_bridge_redacts_and_sandboxes(self) -> None:
        secret = os.path.join(self.cwd, "config.env")
        Path(secret).write_text("OPENAI_API_KEY=sk-proj-abc123def456ghi789jkl012")
        with patch.dict(os.environ, {"FAKE_JUNIE_LOG": self.log, "FAKE_JUNIE_READ_PATH": secret}, clear=False):
            with patch("agent.redact._REDACT_ENABLED", True):
                client = self._client()
                self._ask(client, "read it")
        reads = [e["content"] for e in _read_log(self.log) if e["method"] == "fs_read_result"]
        self.assertTrue(reads)
        self.assertIn("OPENAI_API_KEY=", reads[0])
        self.assertNotIn("abc123def456", reads[0])


# --------------------------------------------------------------------------- #
# session_update routing + cross-session filtering (handler, direct)          #
# --------------------------------------------------------------------------- #
class SessionUpdateRoutingTests(unittest.TestCase):
    def _turn(self):
        h = _HermesClient(cwd="/tmp", permission_policy="deny")
        text, reasoning, tools = [], [], {}
        h.begin_turn("current", text, reasoning, tools)
        return h, text, reasoning, tools

    @staticmethod
    def _msg(kind, content):
        return {"sessionUpdate": kind, "content": content}

    def test_stale_session_update_is_dropped(self):
        # A straggler chunk tagged with a different session must not leak in.
        h, text, _r, _t = self._turn()
        asyncio.run(h.session_update(
            session_id="OTHER", update=self._msg("agent_message_chunk", {"type": "text", "text": "leak"})))
        self.assertEqual(text, [])

    def test_matching_session_update_is_kept(self):
        h, text, _r, _t = self._turn()
        asyncio.run(h.session_update(
            session_id="current", update=self._msg("agent_message_chunk", {"type": "text", "text": "ok"})))
        self.assertEqual(text, ["ok"])

    def test_list_form_chunk_content_is_extracted(self):
        h, text, _r, _t = self._turn()
        asyncio.run(h.session_update(
            session_id="current",
            update=self._msg("agent_message_chunk", [{"type": "text", "text": "a"}, {"type": "text", "text": "b"}])))
        self.assertEqual(text, ["ab"])

    def test_thought_chunk_routes_to_reasoning_not_text(self):
        h, text, reasoning, _t = self._turn()
        asyncio.run(h.session_update(
            session_id="current", update=self._msg("agent_thought_chunk", {"type": "text", "text": "hmm"})))
        self.assertEqual(reasoning, ["hmm"])
        self.assertEqual(text, [])

    def test_tool_update_routes_to_tool_events_not_text(self):
        h, text, reasoning, tools = self._turn()
        asyncio.run(h.session_update(
            session_id="current",
            update={"sessionUpdate": "tool_call", "toolCallId": "t1", "title": "x", "kind": "other", "status": "pending"}))
        self.assertEqual(text, [])
        self.assertEqual(reasoning, [])
        self.assertIn("t1", tools)


# --------------------------------------------------------------------------- #
# Live model discovery from ACP config_options                                #
# --------------------------------------------------------------------------- #
class ModelDiscoveryTests(unittest.TestCase):
    def test_extract_model_ids_current_first(self) -> None:
        config_options = [
            {"id": "brave_mode", "type": "select", "options": [{"value": "on"}]},
            {"id": "model", "type": "select", "currentValue": "claude-fable-5",
             "options": [
                 {"value": "claude-opus-4-8", "name": "Opus 4.8"},
                 {"value": "claude-fable-5", "name": "Fable 5"},
                 {"value": "gpt-5.4", "name": "GPT-5.4"},
             ]},
        ]
        ids = _extract_model_ids(config_options)
        self.assertEqual(ids[0], "claude-fable-5")  # currentValue promoted
        self.assertEqual(set(ids), {"claude-opus-4-8", "claude-fable-5", "gpt-5.4"})

    def test_extract_model_ids_no_model_option(self) -> None:
        self.assertEqual(_extract_model_ids([{"id": "brave_mode", "options": []}]), [])

    def test_fetch_junie_models_returns_none_on_failure(self) -> None:
        async def _boom(*a, **k):
            raise RuntimeError("no junie here")

        junie_mod._model_cache.clear()
        with patch.object(junie_mod, "_afetch_junie_models", _boom), \
             patch.object(junie_mod, "_load_model_disk_cache", lambda cmd: None), \
             patch.object(junie_mod, "_save_model_disk_cache", lambda cmd, ids: None):
            self.assertIsNone(fetch_junie_models(command="junie", args=[], force_refresh=True))

    def test_fetch_junie_models_caches_in_memory(self) -> None:
        calls = {"n": 0}

        async def _ok(command, args, cwd):
            calls["n"] += 1
            return ["claude-fable-5", "gpt-5.4"]

        junie_mod._model_cache.clear()
        with patch.object(junie_mod, "_afetch_junie_models", _ok), \
             patch.object(junie_mod, "_load_model_disk_cache", lambda cmd: None), \
             patch.object(junie_mod, "_save_model_disk_cache", lambda cmd, ids: None):
            first = fetch_junie_models(command="junie", args=[], force_refresh=True)
            second = fetch_junie_models(command="junie", args=[])  # served from cache
        self.assertEqual(first, ["claude-fable-5", "gpt-5.4"])
        self.assertEqual(second, first)
        self.assertEqual(calls["n"], 1)


if __name__ == "__main__":
    unittest.main()
