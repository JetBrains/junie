"""OpenAI-compatible shim that forwards Hermes requests to `junie --acp=true`.

This adapter lets Hermes treat the JetBrains Junie CLI's ACP server as a
chat-style backend. Each request starts a short-lived ACP session, sends the
formatted conversation as a single prompt, collects text chunks, and converts
the result back into the minimal shape Hermes expects from an OpenAI client.

The JSON-RPC / stdio plumbing is delegated to the official Agent Client
Protocol Python SDK (``agent-client-protocol``): Hermes acts as an ACP *client*
(:class:`acp.ClientSideConnection`) driving the Junie agent subprocess, and a
small :class:`_HermesClient` implements the client-side callbacks (fs reads/
writes, permission prompts, and streamed ``session/update`` notifications).

The SDK is asyncio-native, but Hermes calls ``chat.completions.create`` on a
synchronous code path (see ``agent/chat_completion_helpers.py``). We therefore
own a dedicated asyncio event loop on a background daemon thread and bridge each
request with :func:`asyncio.run_coroutine_threadsafe`.

Two kinds of tool call meet here, and the distinction is load-bearing:

  * **Junie's own tools** (read / edit / execute) run inside the ACP session and
    arrive as native ``tool_call`` notifications — already executed. They are
    never returned as pending OpenAI ``tool_calls`` (Hermes would re-run
    finished work); they are projected into the transcript as completed
    ``assistant(tool_calls=[…])`` + ``tool(result)`` rows so Hermes'
    self-improvement loop can learn from the real work.
  * **Hermes' agent-level tools** (the memory + skills self-improvement surface
    and ``todo``) have no Junie equivalent and are dispatched from OpenAI
    ``tool_calls``. They are
    forwarded into the prompt as text and parsed back out of the response via
    the shared bridge in ``agent/acp_openai_bridge.py``. Without that, nothing
    agentic could be written for a whole junie-acp session. The forwarded set is
    an allowlist (``junie_acp.forwarded_tools`` in config.yaml overrides it;
    ``all`` forwards Hermes' entire toolset).

A Hermes tool call splits one user turn into several ACP prompts. The first
opens a fresh session with the full transcript; the continuations reuse that
session and carry only the tool results, so Junie keeps its own context instead
of restarting the task from scratch (which would redo every edit).

Junie specifics (vs Copilot):
  * launched as ``junie --acp=true`` (Copilot uses ``copilot --acp --stdio``);
  * auth is supplied via ``--auth <token>`` / ``JUNIE_API_KEY`` rather than
    being wholly owned by the CLI;
  * Junie wraps each JSON-RPC message with an extra
    ``"type": "com.agentclientprotocol.rpc.*"`` envelope field, which the SDK's
    parser simply ignores (messages are matched by ``id`` / ``method``).
"""

from __future__ import annotations

import asyncio
import concurrent.futures
import contextlib
import hashlib
import json
import logging
import os
from collections import deque
import shlex
import threading
import time
from pathlib import Path
from types import SimpleNamespace
from typing import Any

from agent.acp_openai_bridge import (
    completion_to_stream_chunks as _completion_to_stream_chunks,
    extract_tool_calls_from_text as _extract_tool_calls_from_text,
    render_tool_bridge_sections as _render_tool_bridge_sections,
    tool_specs_from_openai_tools as _tool_specs_from_openai_tools,
)
from agent.file_safety import get_read_block_error, is_write_denied
from agent.redact import redact_sensitive_text
from .secret_shield import shield_prompt
from tools.environments.local import hermes_subprocess_env

logger = logging.getLogger(__name__)

# The ACP SDK is an optional dependency (the ``acp`` extra). Import lazily-ish:
# module import must succeed for the pure helpers below (imported by tests and
# by callers that only touch resolution logic), but actually driving a Junie
# subprocess requires the SDK. ``_require_acp`` raises a clear, actionable error
# when it is missing.
try:  # pragma: no cover - trivial import guard
    import acp as _acp  # noqa: N813
    from acp.exceptions import RequestError
    from acp.schema import (
        AllowedOutcome,
        ClientCapabilities,
        DeniedOutcome,
        FileSystemCapabilities,
        Implementation,
        ReadTextFileResponse,
        RequestPermissionResponse,
    )

    _ACP_IMPORT_ERROR: Exception | None = None
except Exception as _exc:  # pragma: no cover - only hit without the extra
    _acp = None  # type: ignore[assignment]
    _ACP_IMPORT_ERROR = _exc


ACP_MARKER_BASE_URL = "acp://junie"
_DEFAULT_TIMEOUT_SECONDS = 900.0
# Used when the caller passes an explicit "no timeout" (httpx.Timeout(None)):
# a long-but-finite ceiling so a legitimate long coding run isn't cut at 900s
# but a truly hung subprocess still eventually unblocks.
_NO_TIMEOUT_FALLBACK_SECONDS = 3600.0
# Handshake (JVM cold start) can be slow; give initialize/session-setup room.
_HANDSHAKE_TIMEOUT_SECONDS = 90.0
# Per-call caps inside a turn so a wedged (but still "alive") reused process
# fails fast on session/new — recovering on a fresh process — instead of
# hanging the whole request until the outer turn timeout.
_SESSION_NEW_TIMEOUT_SECONDS = 60.0
_CONFIG_OPTION_TIMEOUT_SECONDS = 15.0
# stdin reader buffer for the agent subprocess. Junie streams large tool_call
# payloads (file contents) on a single line; the SDK default (64KB) would raise
# LimitOverrunError, so match the SDK's own 50MB ceiling for multimodal data.
_STDIO_LIMIT_BYTES = 50 * 1024 * 1024
# After session/prompt returns, wait until Junie has been quiet for this long
# before finalizing — the ACP completion response can precede a trailing
# agent_message_chunk / task finalization, and the latency that matters is the
# real subprocess stdout-flush / GC delay (NOT in-process dispatch), so keep the
# original conservative gap. Capped by ``_SETTLE_MAX_SECONDS``. Tests override
# both to tiny values (see tests/agent/test_junie_acp_client.py:_make_client).
_SETTLE_QUIET_GAP_SECONDS = 2.5
_SETTLE_MAX_SECONDS = 20.0

# Junie's ACP session/update kinds that report tool activity. Unlike an OpenAI
# model, Junie is an autonomous agent that EXECUTES its own tools and reports
# them here (status pending -> in_progress -> completed/failed) — these are NOT
# delegation requests for Hermes to run. We never turn them into *pending*
# OpenAI tool_calls; we project them into the transcript as already-completed
# assistant tool_call + tool-result pairs (see _project_tool_events) so Hermes'
# self-improvement loop can learn from the real work.
_TOOL_UPDATE_KINDS = ("tool_call", "tool_call_update")

# Hermes tools forwarded to Junie through the ACP text bridge. Junie runs its
# own read/edit/execute tools, so re-offering those would make Hermes re-run
# work Junie already finished. What Junie has NO equivalent for is Hermes'
# agent-level surface — the memory/skill self-improvement loop and the todo list
# — and those are dispatched from OpenAI tool_calls, so without the bridge they
# are unreachable for a whole junie-acp session.
#
# This set must COVER the background-review fork's tool whitelist (memory +
# skills toolsets, see agent/background_review.py), reads included: a review that
# can call skill_manage but cannot call skills_list/skill_view can only create
# skills blindly, never decide "update the existing one". A test asserts the two
# stay in sync — if a new agent-level tool appears, add it here.
_DEFAULT_FORWARDED_TOOLS = (
    "memory",
    "todo",
    "skill_manage",
    "skill_view",
    "skills_list",
)

# Namespace for projected tool names (junie_edit, junie_execute, …) so a
# projected row can never be mistaken for a Hermes tool Hermes should dispatch,
# and so tool-result continuations can tell Junie's own history apart from
# results Junie is actually waiting on.
_PROJECTED_TOOL_PREFIX = "junie_"

# Caps on projected tool activity so a chatty Junie turn can't flood the
# transcript (mirrors the codex projector's 4000-char result cap).
_PROJECTED_RESULT_MAX_CHARS = 4000
_PROJECTED_EVENT_LIMIT = 40

# Model values that mean "let Junie use its own default" — the provider
# sentinel/aliases, not real Junie model ids. These are NOT forwarded to
# session/set_config_option{model}.
_MODEL_PASSTHROUGH_SENTINELS = frozenset({
    "junie-acp", "junie", "jetbrains-junie-acp", "junie-acp-agent", "",
})

# Prefer approving *once*: only grant persistent auto-approval if a request
# offers no single-shot option (see _choose_permission_option).
_ALLOW_OPTION_KINDS = ("allow_once", "allow_always")


def _client_capabilities() -> Any:
    """The ClientCapabilities Hermes advertises to Junie (fs on, no terminal)."""
    return ClientCapabilities(
        fs=FileSystemCapabilities(read_text_file=True, write_text_file=True),
        terminal=False,
    )


def _client_info() -> Any:
    return Implementation(name="hermes-agent", title="Hermes Agent", version="0.0.0")


def _require_acp() -> None:
    if _acp is None:
        raise RuntimeError(
            "The Agent Client Protocol SDK is required for the junie-acp "
            "provider. Add the `acp` extra to your hermes-agent install (the "
            "SDK is the `agent-client-protocol` package)."
        ) from _ACP_IMPORT_ERROR


def _rough_tokens(text: str | None) -> int:
    """Rough token estimate (~4 chars/token). Used only as a fallback when
    Junie does not report usage; see JunieACPClient._create_chat_completion."""
    return len(text) // 4 if text else 0


def _resolve_command() -> str:
    """Path to the Junie CLI. config.yaml: ``junie_acp.command``."""
    return (
        os.getenv("HERMES_JUNIE_ACP_COMMAND", "").strip()
        or os.getenv("JUNIE_CLI_PATH", "").strip()
        or str(_junie_config().get("command", "") or "").strip()
        or "junie"
    )


DEFAULT_ACP_ARGS = ("--acp=true", "--skip-update-check")


def _with_auth(args: list[str]) -> list[str]:
    """Append ``--auth <token>`` from ``JUNIE_API_KEY`` unless already supplied.

    The token is a credential, so it stays an env var rather than moving to
    config.yaml. Applied to args from every source — the provider profile's
    ``process_args``, config.yaml, or an explicit constructor argument — because
    only this function knows the arg name.
    """
    if "--auth" in args or any(a.startswith("--auth=") for a in args):
        return args
    token = os.getenv("JUNIE_API_KEY", "").strip()
    return args + ["--auth", token] if token else args


def _resolve_args() -> list[str]:
    """Launch args for the Junie CLI when the caller supplied none.

    The normal path is the provider profile (``process_args`` /
    ``process_args_env_var``), which the Hermes seam resolves and passes in.
    This fallback covers direct construction — tests, or a caller building the
    client without going through the registry. config.yaml: ``junie_acp.args``.
    """
    raw = os.getenv("HERMES_JUNIE_ACP_ARGS", "").strip()
    cfg_args = _junie_config().get("args") if not raw else None
    if isinstance(cfg_args, (list, tuple)):
        return [str(a) for a in cfg_args if str(a).strip()]
    raw = raw or str(cfg_args or "").strip()
    return shlex.split(raw) if raw else list(DEFAULT_ACP_ARGS)


def _junie_config() -> dict[str, Any]:
    """The ``junie_acp:`` block from config.yaml (empty dict when unset).

    Behavioral settings live here, not in ``HERMES_*`` env vars — ``.env`` is for
    secrets only (AGENTS.md). The env names are kept as an internal bridge for a
    one-off run or a test and take precedence when set, being the narrower scope;
    config.yaml is the documented, persistent surface.
    """
    try:
        from hermes_cli.config import load_config_readonly

        block = load_config_readonly().get("junie_acp")
    except Exception:
        return {}
    if not isinstance(block, dict):
        return {}
    # Empty values mean "not set" — the defaults stay in this module. Read
    # literally, an empty `forwarded_tools` would disable the tool bridge and an
    # empty `args` would launch Junie without --acp=true. Use the explicit
    # "none" keyword to forward nothing.
    #
    # As an out-of-tree plugin the block is not declared in Hermes'
    # config_defaults, so `hermes config set junie_acp.<key>` may not recognise
    # the path — edit config.yaml directly. Reading is unaffected: this loads
    # the file as written.
    return {k: v for k, v in block.items() if v not in (None, "", [], (), {})}


def _resolve_permission_policy() -> str:
    """How the client answers Junie's session/request_permission requests.

    "deny" (default, safe): reject every request (Junie can't act without
    explicit consent — matters only when Brave Mode is OFF). "allow": approve
    once. This is the seam a future Hermes-approval bridge would replace.

    config.yaml: ``junie_acp.permission: allow|deny``.
    """
    val = os.getenv("HERMES_JUNIE_ACP_PERMISSION", "").strip().lower()
    if not val:
        val = str(_junie_config().get("permission", "") or "").strip().lower()
    return "allow" if val in ("allow", "allow_once", "yes", "1", "true") else "deny"


def _resolve_forwarded_tools() -> frozenset[str] | None:
    """Which Hermes tools are described to Junie via the text bridge.

    Default: the agent-level allowlist (:data:`_DEFAULT_FORWARDED_TOOLS`).
    ``all`` forwards Hermes' entire toolset (returns None, i.e. no filtering),
    ``none`` forwards nothing, and a list forwards exactly those names.

    config.yaml: ``junie_acp.forwarded_tools: all | none | [memory, todo]``.
    """
    raw_env = os.getenv("HERMES_JUNIE_ACP_FORWARD_TOOLS", "").strip()
    raw_cfg = _junie_config().get("forwarded_tools") if not raw_env else None
    if isinstance(raw_cfg, (list, tuple, set)):
        names = frozenset(str(n).strip() for n in raw_cfg if str(n).strip())
        return names or frozenset()
    raw = raw_env or str(raw_cfg or "").strip()
    if not raw:
        return frozenset(_DEFAULT_FORWARDED_TOOLS)
    lowered = raw.lower()
    if lowered in ("all", "*"):
        return None
    if lowered in ("none", "off", "-"):
        return frozenset()
    return frozenset(p.strip() for p in raw.replace(",", " ").split() if p.strip())


def _resolve_brave_override() -> bool | None:
    """Optional override for Junie's Brave Mode (auto-execute without asking).

    Returns True/False to force it via session/set_config_option, or None to
    leave Junie on its own persisted/default setting.

    config.yaml: ``junie_acp.brave_mode: true|false`` (omit to not override).
    """
    val = os.getenv("HERMES_JUNIE_ACP_BRAVE", "").strip().lower()
    if not val:
        cfg_val = _junie_config().get("brave_mode")
        if isinstance(cfg_val, bool):
            return cfg_val
        val = str(cfg_val or "").strip().lower()
    if val in ("on", "1", "true", "yes"):
        return True
    if val in ("off", "0", "false", "no"):
        return False
    return None


def _resolve_home_dir() -> str:
    """Return a stable HOME for child ACP processes."""
    home = os.environ.get("HOME", "").strip()
    if home:
        return home

    expanded = os.path.expanduser("~")
    if expanded and expanded != "~":
        return expanded

    try:
        import pwd

        resolved = pwd.getpwuid(os.getuid()).pw_dir.strip()  # windows-footgun: ok — POSIX fallback inside try/except (pwd import fails on Windows)
        if resolved:
            return resolved
    except Exception:
        pass

    # Last resort: /tmp (writable on any POSIX system). Avoids crashing the
    # subprocess with no HOME; callers can set HERMES_HOME explicitly if they
    # need a different writable dir.
    return "/tmp"


def _build_subprocess_env() -> dict[str, str]:
    # Junie is a model-driving CLI executor: it legitimately needs LLM provider
    # credentials (BYOK keys, its own token). Route through the central helper so
    # Tier-1 secrets (gateway bot tokens, GitHub auth, remote-compute/infra) are
    # still stripped — a raw os.environ.copy() would hand every one of them to a
    # third-party subprocess. Same policy as agent/copilot_acp_client.py and
    # agent/transports/codex_app_server.py (#29157).
    env = hermes_subprocess_env(inherit_credentials=True)
    home = _resolve_home_dir()
    env["HOME"] = home
    from hermes_constants import apply_subprocess_home_env
    apply_subprocess_home_env(env)
    return env


def _choose_permission_option(options: list[dict[str, Any]], policy: str) -> str | None:
    """Pick the optionId to approve for a session/request_permission request.

    Returns None to reject (``policy="deny"`` or no allow-kind option offered).
    "allow" means approve *once*: prefer an allow_once option and only fall back
    to allow_always if the request offers no single-shot option — never grant
    persistent auto-approval just because it happened to be listed first.
    """
    if policy != "allow":
        return None
    opts = [o for o in options if isinstance(o, dict)]
    for kind in _ALLOW_OPTION_KINDS:
        for opt in opts:
            if str(opt.get("kind", "")).lower() == kind:
                chosen = opt.get("optionId") or opt.get("id")
                if chosen:
                    return str(chosen)
    return None


def _format_messages_as_prompt(
    messages: list[dict[str, Any]],
    model: str | None = None,
    tools: list[dict[str, Any]] | None = None,
    tool_choice: Any = None,
    *,
    forwarded_tools: frozenset[str] | None = None,
) -> str:
    # Junie is an autonomous coding agent: it runs its OWN tools (read/edit/
    # execute) inside the ACP session and reports them via native tool_call
    # notifications, so we don't ask it to route coding work through Hermes.
    # But Hermes' agent-level tools (the memory/skills loop, todo) have no Junie
    # equivalent and are dispatched from OpenAI tool_calls, so those travel into
    # the prompt as text and come back out of the response via the shared ACP
    # text bridge (agent/acp_openai_bridge.py).
    sections: list[str] = [
        "You are being used as the active ACP coding agent backend for Hermes.",
        "Use your own tools to complete the task, then answer normally.",
    ]
    if model:
        sections.append(f"Hermes requested model hint: {model}")

    if _tool_specs_from_openai_tools(tools, allowlist=forwarded_tools):
        sections.append(
            "Hermes owns a few tools of its own that you cannot execute: to use "
            "one, emit a <tool_call> block and stop — Hermes runs it and sends "
            "you the result, then you continue. Keep using YOUR OWN tools for "
            "reading, editing and running code; use these only for what their "
            "descriptions cover."
        )
        sections.extend(
            _render_tool_bridge_sections(tools, tool_choice, allowlist=forwarded_tools)
        )

    transcript: list[str] = []
    for message in messages:
        if not isinstance(message, dict):
            continue
        role = str(message.get("role") or "unknown").strip().lower()
        if role == "tool":
            role = "tool"
        elif role not in {"system", "user", "assistant"}:
            role = "context"

        content = message.get("content")
        rendered = _render_message_content(content)
        if not rendered:
            continue

        label = {
            "system": "System",
            "user": "User",
            "assistant": "Assistant",
            "tool": "Tool",
            "context": "Context",
        }.get(role, role.title())
        transcript.append(f"{label}:\n{rendered}")

    if transcript:
        sections.append("Conversation transcript:\n\n" + "\n\n".join(transcript))

    sections.append("Continue the conversation from the latest user request.")
    return "\n\n".join(section.strip() for section in sections if section and section.strip())


def _render_message_content(content: Any) -> str:
    if content is None:
        return ""
    if isinstance(content, str):
        return content.strip()
    if isinstance(content, dict):
        if "text" in content:
            return str(content.get("text") or "").strip()
        if "content" in content and isinstance(content.get("content"), str):
            return str(content.get("content") or "").strip()
        return json.dumps(content, ensure_ascii=True)
    if isinstance(content, list):
        parts: list[str] = []
        for item in content:
            if isinstance(item, str):
                parts.append(item)
            elif isinstance(item, dict):
                text = item.get("text")
                if isinstance(text, str) and text.strip():
                    parts.append(text.strip())
        return "\n".join(parts).strip()
    return str(content).strip()


def _trailing_tool_results(messages: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """The unbroken run of ``role="tool"`` messages at the end of ``messages``.

    Non-empty exactly when Hermes has just executed tool calls that Junie asked
    for and is calling back for the continuation of the SAME turn.
    """
    trailing: list[dict[str, Any]] = []
    for message in reversed(messages or []):
        if not isinstance(message, dict):
            break
        if str(message.get("role") or "").strip().lower() != "tool":
            break
        # Rows we projected from Junie's OWN activity are history, not results
        # Junie is waiting on — reusing the session for those would tell Junie
        # "here are your tool results" about work it already did itself. They are
        # identified by the namespaced tool name rather than a private message
        # key, so nothing non-standard ends up on the wire for strict providers.
        # A session reloaded from the DB carries the name under ``tool_name``
        # (hermes_state.get_messages_as_conversation), so check both spellings.
        # Even if neither survives, _answers_last_request still blocks reuse: a
        # fresh client is owed no call ids.
        if any(
            str(message.get(key) or "").startswith(_PROJECTED_TOOL_PREFIX)
            for key in ("name", "tool_name")
        ):
            continue
        trailing.append(message)
    trailing.reverse()
    return trailing


def _format_tool_results_as_prompt(tool_messages: list[dict[str, Any]]) -> str:
    """Continuation prompt for a reused ACP session.

    When Hermes returns tool results mid-turn we must NOT replay the whole
    transcript into a fresh Junie session: Junie would treat it as a new request
    and redo the coding work it already finished (files re-edited, commands
    re-run). Instead we reuse the live session — which still holds Junie's own
    context — and send only the results it was waiting on.
    """
    parts: list[str] = [
        "Hermes executed the tool call(s) you requested. Results follow.",
        "Do NOT redo any work you already completed in this session.",
    ]
    for message in tool_messages:
        rendered = _render_message_content(message.get("content"))
        name = str(message.get("name") or "").strip()
        call_id = str(message.get("tool_call_id") or "").strip()
        label = "Tool result"
        if name:
            label += f" from {name}"
        if call_id:
            label += f" (id={call_id})"
        parts.append(f"{label}:\n{rendered}" if rendered else f"{label}: (no output)")
    parts.append("Continue from where you left off and answer the user's request.")
    return "\n\n".join(p.strip() for p in parts if p and p.strip())


def _chunk_text(content: Any) -> str:
    """Extract text from a session/update content that may be a dict or a list
    of {type,text} blocks."""
    if isinstance(content, dict):
        return str(content.get("text") or "")
    if isinstance(content, list):
        return "".join(
            str(b.get("text") or "") for b in content if isinstance(b, dict)
        )
    return ""


def _tool_update_text(update: dict[str, Any]) -> str:
    """Best-effort plain-text extraction from an ACP tool_call content list."""
    parts: list[str] = []
    for block in update.get("content") or []:
        if not isinstance(block, dict):
            continue
        inner = block.get("content")
        if isinstance(inner, dict) and isinstance(inner.get("text"), str):
            parts.append(inner["text"])
        elif isinstance(block.get("text"), str):
            parts.append(block["text"])
    return "\n".join(p for p in parts if p and p.strip()).strip()


def _merge_tool_update(store: dict[str, dict[str, Any]], update: dict[str, Any]) -> None:
    """Fold a tool_call / tool_call_update notification into ``store`` by id.

    Junie streams a ``tool_call`` (first-seen) then zero or more
    ``tool_call_update`` messages sharing the same ``toolCallId`` as the tool
    progresses (pending -> in_progress -> completed/failed). We keep the latest
    non-empty value for each field so ``store`` ends up with the final state.
    """
    tcid = str(update.get("toolCallId") or f"tool_{len(store)}")
    entry = store.setdefault(tcid, {"id": tcid})
    for field in ("title", "kind", "status"):
        val = update.get(field)
        if val:
            entry[field] = val
    text = _tool_update_text(update)
    if text:
        entry["result"] = text
    locations = update.get("locations")
    if locations:
        entry["locations"] = locations
    # rawInput/rawOutput carry the substance the self-improvement loop learns
    # from — the actual command, patch or query, and its raw result — so keep
    # them for the transcript projection (see _project_tool_events).
    for field in ("rawInput", "rawOutput"):
        val = update.get(field)
        if val:
            entry[field] = val


def _render_tool_activity(tool_events: dict[str, dict[str, Any]]) -> str:
    """Render captured tool activity as a compact, human-readable summary.

    Surfaced via the assistant message's ``reasoning`` so the operator can see
    what Junie actually did, without misrepresenting completed actions as
    OpenAI tool_calls Hermes must execute.
    """
    lines: list[str] = []
    for ev in tool_events.values():
        kind = ev.get("kind", "tool")
        status = ev.get("status", "")
        title = ev.get("title", "")
        head = f"[{kind}] {title}".strip()
        if status:
            head = f"{head} ({status})"
        lines.append(head)
        result = ev.get("result")
        if result:
            snippet = result if len(result) <= 500 else result[:500] + "…"
            lines.append(f"    → {snippet}")
    return "\n".join(lines).strip()


def _projected_tool_name(kind: Any) -> str:
    """Hermes-side name for a projected Junie tool call.

    Namespaced (``junie_edit``, ``junie_execute``, …) so the transcript can never
    be mistaken for a Hermes tool Hermes should dispatch, while still telling the
    review fork *what kind* of work happened. Underscores only — some providers
    validate tool names against ``[A-Za-z0-9_-]``.
    """
    slug = "".join(c if c.isalnum() or c == "_" else "_" for c in str(kind or "other").strip().lower())
    return f"{_PROJECTED_TOOL_PREFIX}{slug or 'other'}"


def _truncate(text: str, limit: int = _PROJECTED_RESULT_MAX_CHARS) -> str:
    if len(text) <= limit:
        return text
    return text[:limit] + f"\n… [truncated, {len(text) - limit} more chars]"


def _projected_call_id(session_id: str | None, tool_call_id: str, index: int) -> str:
    """Stable, transcript-unique id for a projected tool call.

    Junie's ``toolCallId`` is only unique *within* its session ("t1", "t2", …),
    and Hermes opens a session per user turn — so the raw id would repeat across
    the transcript, and providers that pair calls with results by id (Anthropic)
    reject duplicates. Namespacing with the session id makes it unique while
    staying deterministic, so a resumed session projects the same ids and the
    prompt-cache prefix survives (AGENTS.md Pitfall #16).
    """
    base = tool_call_id or f"idx{index}"
    if session_id:
        return f"junie_{session_id}_{base}"
    digest = hashlib.sha256(f"{base}|{index}".encode()).hexdigest()[:16]
    return f"junie_{digest}"


def _project_tool_events(
    tool_events: dict[str, dict[str, Any]], session_id: str | None = None
) -> list[dict[str, Any]]:
    """Project Junie's native tool activity into OpenAI-shaped history messages.

    Junie does the real work (files read, edits applied, commands run) inside its
    own ACP session; a one-line activity summary in ``reasoning`` is not enough
    for Hermes' self-improvement loop, which distils skills and memories from the
    *transcript*. So we mirror what the codex app-server path already does
    (``agent/transports/codex_event_projector.py``): emit already-completed
    ``assistant(tool_calls=[…])`` + ``tool(result)`` pairs so the background
    review fork replays real calls, real results and real errors.

    These are history rows only — they are appended to ``messages`` after the
    turn, never returned as pending ``tool_calls`` for Hermes to execute.
    """
    projected: list[dict[str, Any]] = []
    for index, ev in enumerate(tool_events.values()):
        if index >= _PROJECTED_EVENT_LIMIT:
            logger.info(
                "Junie ACP tool activity truncated in transcript projection: %d of %d events kept",
                _PROJECTED_EVENT_LIMIT,
                len(tool_events),
            )
            break
        call_id = _projected_call_id(session_id, str(ev.get("id") or ""), index)
        name = _projected_tool_name(ev.get("kind"))
        args: dict[str, Any] = {}
        title = ev.get("title")
        if title:
            args["title"] = str(title)
        raw_input = ev.get("rawInput")
        if isinstance(raw_input, dict):
            args.update(raw_input)
        elif raw_input:
            args["input"] = raw_input
        locations = ev.get("locations")
        if locations:
            args["locations"] = locations
        try:
            arguments = json.dumps(args, ensure_ascii=False, default=str)
        except Exception:
            arguments = json.dumps({"title": str(title or "")}, ensure_ascii=False)

        result = ev.get("result")
        if not result:
            raw_output = ev.get("rawOutput")
            if raw_output:
                try:
                    result = json.dumps(raw_output, ensure_ascii=False, default=str)
                except Exception:
                    result = str(raw_output)
        status = str(ev.get("status") or "").strip()
        content = _truncate(str(result or "").strip())
        if status and status not in ("completed", "success"):
            content = f"[status {status}]\n{content}".strip()
        if not content:
            content = f"[status {status or 'unknown'}] (no output reported)"

        projected.append(
            {
                "role": "assistant",
                "content": None,
                "tool_calls": [
                    {
                        "id": call_id,
                        "type": "function",
                        "function": {"name": name, "arguments": arguments},
                    }
                ],
            }
        )
        projected.append(
            {
                "role": "tool",
                "tool_call_id": call_id,
                "name": name,
                "content": content,
            }
        )
    return projected


def _ensure_path_within_cwd(path_text: str, cwd: str) -> Path:
    candidate = Path(path_text)
    if not candidate.is_absolute():
        raise PermissionError("ACP file-system paths must be absolute.")
    resolved = candidate.resolve()
    root = Path(cwd).resolve()
    try:
        resolved.relative_to(root)
    except ValueError as exc:
        raise PermissionError(f"Path '{resolved}' is outside the session cwd '{root}'.") from exc
    return resolved


def _read_text_file_content(
    path_text: str, cwd: str, *, line: int | None, limit: int | None
) -> str:
    """Safely read a file for an fs/read_text_file request.

    Enforces path-within-cwd, honors Hermes' read-blocklist, redacts secrets,
    and applies ACP line/limit pagination (honoring ``limit`` even from the top
    so a paginated read doesn't return the whole file).
    """
    path = _ensure_path_within_cwd(path_text, cwd)
    block_error = get_read_block_error(str(path))
    if block_error:
        raise PermissionError(block_error)
    try:
        content = path.read_text()
    except FileNotFoundError:
        content = ""
    has_line = isinstance(line, int) and line > 1
    has_limit = isinstance(limit, int) and limit > 0
    if has_line or has_limit:
        lines = content.splitlines(keepends=True)
        start = line - 1 if has_line else 0
        end = start + limit if has_limit else None
        content = "".join(lines[start:end])
    if content:
        content = redact_sensitive_text(content, force=True)
    return content


def _write_text_file(path_text: str, cwd: str, content: str) -> None:
    """Safely write a file for an fs/write_text_file request.

    Enforces path-within-cwd and Hermes' write-deny policy (protected
    system/credential files).
    """
    path = _ensure_path_within_cwd(path_text, cwd)
    if is_write_denied(str(path)):
        raise PermissionError(
            f"Write denied: '{path}' is a protected system/credential file."
        )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)


# --------------------------------------------------------------------------- #
# Live model discovery for the /model picker                                  #
# --------------------------------------------------------------------------- #
# Junie advertises its selectable models in the session/new response's
# ``config_options`` (the ``model`` Select option). Discovering them live keeps
# the picker in sync with whatever the account/CLI actually offers, without
# hardcoding ids into _PROVIDER_MODELS (which would make detect_provider_for_model
# mis-resolve claude/gemini/gpt ids to junie-acp). Cached because each probe
# spawns Junie (JVM cold start).
_MODEL_CACHE_TTL_SECONDS = 6 * 3600
# Negative results (unauthed / offline / timeout) are cached in-memory only, for
# a short window, so a wedged /model picker doesn't re-spawn Junie on every open
# — but a fresh process (or a re-auth after this window) re-probes promptly.
_MODEL_NEG_TTL_SECONDS = 300
# key -> (ts, ids); an empty ids list is a cached negative result.
_model_cache: dict[str, tuple[float, list[str]]] = {}


def _account_fingerprint(args: list[str]) -> str:
    """Short, non-reversible tag for the Junie account behind these args.

    Keys the model cache so switching accounts (different --auth token /
    JUNIE_API_KEY) doesn't serve the previous account's catalog. Only the hash
    is ever stored — never the raw token, on disk or in memory.
    """
    import hashlib

    token = ""
    for i, a in enumerate(args):
        if a == "--auth" and i + 1 < len(args):
            token = args[i + 1]
            break
        if a.startswith("--auth="):
            token = a.split("=", 1)[1]
            break
    if not token:
        token = os.getenv("JUNIE_API_KEY", "").strip()
    if not token:
        return "noauth"
    return hashlib.sha256(token.encode("utf-8", "ignore")).hexdigest()[:12]


def _model_cache_key(command: str, args: list[str]) -> str:
    return f"{command}#{_account_fingerprint(args)}"


def _extract_model_ids(config_options: Any) -> list[str]:
    """Pull the ``model`` config option's advertised value ids (current first)."""
    for opt in config_options or []:
        data = opt.model_dump(by_alias=True, exclude_none=True) if hasattr(opt, "model_dump") else dict(opt)
        if data.get("id") != "model" and data.get("configId") != "model":
            continue
        ids: list[str] = []
        for o in data.get("options") or []:
            if isinstance(o, dict):
                val = o.get("value") or o.get("valueId") or o.get("optionId")
                if val:
                    ids.append(str(val))
        current = data.get("currentValue")
        if current and current in ids:
            ids = [current] + [i for i in ids if i != current]
        return ids
    return []


def _model_disk_cache_path() -> Path:
    from hermes_constants import get_hermes_home
    return Path(get_hermes_home()) / "junie_acp_models_cache.json"


def _load_model_disk_cache(key: str) -> tuple[float, list[str]] | None:
    """Return ``(stored_ts, ids)`` for ``key`` or None. Freshness is judged by
    the caller against the original timestamp (so loading never re-stamps the
    TTL). Only positive (non-empty) results are ever on disk."""
    try:
        path = _model_disk_cache_path()
        if not path.exists():
            return None
        blob = json.loads(path.read_text())
        entry = blob.get(key)
        if not entry:
            return None
        ids = entry.get("ids")
        if not (isinstance(ids, list) and ids):
            return None
        return float(entry.get("ts", 0)), [str(i) for i in ids]
    except Exception:
        return None


def _save_model_disk_cache(key: str, ids: list[str]) -> None:
    # ``key`` = "<command>#<account-hash>": never persists the raw --auth token.
    # Negatives are NOT written (they live in-memory only) so a fresh process
    # after re-auth re-probes immediately instead of honoring a stale miss.
    if not ids:
        return
    try:
        path = _model_disk_cache_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        blob = {}
        if path.exists():
            with contextlib.suppress(Exception):
                blob = json.loads(path.read_text())
        if not isinstance(blob, dict):
            blob = {}
        blob[key] = {"ts": time.time(), "ids": ids}
        path.write_text(json.dumps(blob))
    except Exception:
        pass


async def _afetch_junie_models(command: str, args: list[str], cwd: str) -> list[str]:
    handler = _HermesClient(cwd=cwd, permission_policy="deny")
    async with contextlib.AsyncExitStack() as stack:
        conn, _proc = await stack.enter_async_context(
            _acp.spawn_agent_process(
                handler, command, *args,
                env=_build_subprocess_env(), cwd=cwd,
                transport_kwargs={"limit": _STDIO_LIMIT_BYTES},
            )
        )
        await conn.initialize(
            protocol_version=_acp.PROTOCOL_VERSION,
            client_capabilities=_client_capabilities(),
            client_info=_client_info(),
        )
        session = await conn.new_session(cwd=cwd, mcp_servers=[])
        return _extract_model_ids(getattr(session, "config_options", None))


def fetch_junie_models(
    *,
    command: str | None = None,
    args: list[str] | None = None,
    cwd: str | None = None,
    timeout: float = 20.0,
    force_refresh: bool = False,
) -> list[str] | None:
    """Return the models Junie advertises over ACP, or None if unavailable.

    Spawns ``junie --acp=true`` and reads the ``model`` config option from the
    session/new response. Positive results are cached in-memory + on disk (6h,
    keyed per account); failures (SDK missing, CLI absent, not authed, timeout)
    return None and are negatively cached in-memory for a short window so the
    /model picker doesn't re-spawn a JVM on every open. Callers fall back to the
    curated sentinel list on None.
    """
    if _acp is None:
        return None
    command = command or _resolve_command()
    args = list(args if args is not None else _resolve_args())
    cwd = str(Path(cwd or os.getcwd()).resolve())
    key = _model_cache_key(command, args)
    now = time.time()

    def _fresh(ts: float, ids: list[str]) -> bool:
        ttl = _MODEL_CACHE_TTL_SECONDS if ids else _MODEL_NEG_TTL_SECONDS
        return (now - ts) < ttl

    if not force_refresh:
        mem = _model_cache.get(key)
        if mem and _fresh(*mem):
            return mem[1] or None
        disk = _load_model_disk_cache(key)  # positives only; original ts preserved
        if disk and _fresh(*disk):
            _model_cache[key] = disk  # keep the disk timestamp — don't re-stamp the TTL
            return disk[1] or None

    async def _runner() -> list[str]:
        return await asyncio.wait_for(_afetch_junie_models(command, args, cwd), timeout)

    try:
        try:
            asyncio.get_running_loop()
        except RuntimeError:
            ids = asyncio.run(_runner())
        else:
            # Called from within a running loop: run on a private loop thread.
            # (This still blocks the caller — provider_model_ids is a sync API —
            # but avoids the "asyncio.run() inside a running loop" error.)
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as ex:
                ids = ex.submit(lambda: asyncio.run(_runner())).result(timeout + 5)
    except Exception as exc:
        logger.debug("fetch_junie_models failed: %s", exc)
        ids = []  # negative cache below so we don't re-spawn Junie every open

    _model_cache[key] = (time.time(), ids)
    if ids:
        _save_model_disk_cache(key, ids)
        return ids
    return None


class _ACPChatCompletions:
    def __init__(self, client: "JunieACPClient"):
        self._client = client

    def create(self, **kwargs: Any) -> Any:
        return self._client._create_chat_completion(**kwargs)


class _ACPChatNamespace:
    def __init__(self, client: "JunieACPClient"):
        self.completions = _ACPChatCompletions(client)


class _HermesClient:
    """Client-side ACP callbacks Hermes exposes to the Junie agent.

    Implements the parts of :class:`acp.Client` that Junie exercises: streamed
    ``session/update`` notifications (text / thought / tool activity), the
    ``session/request_permission`` prompt, and sandboxed ``fs/read_text_file`` /
    ``fs/write_text_file``. Terminal methods are intentionally unimplemented —
    the SDK router treats them as optional and returns a null default.

    One instance is reused across turns on the client's event loop; per-turn
    collection buffers are installed by :meth:`begin_turn` and cleared by
    :meth:`end_turn`, so notifications are single-threaded on that loop and need
    no locking.
    """

    def __init__(self, *, cwd: str, permission_policy: str):
        self._cwd = cwd
        self._policy = permission_policy
        self._session_id: str | None = None
        self._text_parts: list[str] | None = None
        self._reasoning_parts: list[str] | None = None
        self._tool_events: dict[str, dict[str, Any]] | None = None
        self._last_activity = 0.0
        # True once Junie has said or done ANYTHING this turn (an update, a
        # permission prompt, an fs call). Read by the client's retry policy: a
        # prompt that failed without a single inbound message almost certainly
        # never ran, which is what makes a retry safe. See
        # JunieACPClient._continuation_retry_allowed.
        self._saw_agent_activity = False

    @property
    def saw_agent_activity(self) -> bool:
        return self._saw_agent_activity

    def begin_turn(
        self,
        session_id: str,
        text_parts: list[str],
        reasoning_parts: list[str],
        tool_events: dict[str, dict[str, Any]],
    ) -> None:
        self._session_id = session_id
        self._text_parts = text_parts
        self._reasoning_parts = reasoning_parts
        self._tool_events = tool_events
        self._last_activity = time.monotonic()
        self._saw_agent_activity = False

    def end_turn(self) -> None:
        self._session_id = None
        self._text_parts = None
        self._reasoning_parts = None
        self._tool_events = None

    async def settle(self, quiet_gap: float, max_wait: float) -> None:
        """Wait until Junie has been quiet for ``quiet_gap`` (capped at
        ``max_wait``) so a trailing chunk after the completion isn't lost."""
        if max_wait <= 0:
            return
        deadline = time.monotonic() + max_wait
        while time.monotonic() < deadline:
            if time.monotonic() - self._last_activity >= quiet_gap:
                return
            await asyncio.sleep(0.05)

    async def session_update(self, session_id: str, update: Any, **_: Any) -> None:
        # One reused process serves many sessions over one connection. Drop
        # updates belonging to a *different* session (e.g. a straggler chunk
        # from a previous turn) so a prior answer can't leak into this turn.
        if self._session_id is not None and session_id and session_id != self._session_id:
            return
        self._last_activity = time.monotonic()
        self._saw_agent_activity = True
        data = update.model_dump(by_alias=True, exclude_none=True) if hasattr(update, "model_dump") else dict(update)
        kind = str(data.get("sessionUpdate") or "").strip()
        if kind in _TOOL_UPDATE_KINDS:
            # Native structured tool activity — captured for observability, NOT
            # turned into OpenAI tool_calls.
            if self._tool_events is not None:
                _merge_tool_update(self._tool_events, data)
            return
        chunk_text = _chunk_text(data.get("content"))
        if kind == "agent_message_chunk" and chunk_text and self._text_parts is not None:
            self._text_parts.append(chunk_text)
        elif kind == "agent_thought_chunk" and chunk_text and self._reasoning_parts is not None:
            self._reasoning_parts.append(chunk_text)

    async def request_permission(
        self, options: list[Any], session_id: str, tool_call: Any, **_: Any
    ) -> Any:
        opt_dicts = [
            (o.model_dump(by_alias=True, exclude_none=True) if hasattr(o, "model_dump") else dict(o))
            for o in (options or [])
        ]
        self._saw_agent_activity = True
        tc = tool_call.model_dump(by_alias=True, exclude_none=True) if hasattr(tool_call, "model_dump") else dict(tool_call or {})
        title = tc.get("title") or tc.get("toolCallId") or "?"
        chosen = _choose_permission_option(opt_dicts, self._policy)
        if chosen:
            logger.info("Junie ACP permission ALLOW: %s (option=%s)", title, chosen)
            return RequestPermissionResponse(outcome=AllowedOutcome(option_id=chosen, outcome="selected"))
        logger.info("Junie ACP permission DENY: %s (policy=%s)", title, self._policy)
        return RequestPermissionResponse(outcome=DeniedOutcome(outcome="cancelled"))

    async def read_text_file(
        self, path: str, session_id: str, limit: int | None = None, line: int | None = None, **_: Any
    ) -> Any:
        self._saw_agent_activity = True
        try:
            content = _read_text_file_content(path, self._cwd, line=line, limit=limit)
        except Exception as exc:
            raise RequestError.invalid_params({"details": str(exc)}) from exc
        return ReadTextFileResponse(content=content)

    async def write_text_file(self, content: str, path: str, session_id: str, **_: Any) -> None:
        self._saw_agent_activity = True
        try:
            _write_text_file(path, self._cwd, content or "")
        except Exception as exc:
            raise RequestError.invalid_params({"details": str(exc)}) from exc
        return None

    async def ext_method(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        raise RequestError.method_not_found(method)

    async def ext_notification(self, method: str, params: dict[str, Any]) -> None:
        return None


class JunieACPClient:
    """Minimal OpenAI-client-compatible facade for JetBrains Junie ACP."""

    # Hermes' agent-level tools reach this provider through the ACP text bridge,
    # so tool-call-dependent subsystems (memory/skill writes, the background
    # review fork) work here. Checked by agent/background_review.py, which skips
    # the review fork for an agent-as-provider that CANNOT emit Hermes tool calls
    # rather than spawning one that could only no-op.
    SUPPORTS_HERMES_TOOL_CALLS = True

    # This shim drives an ACP subprocess over stdio, so it is already a complete
    # client: never re-dispatch it through an HTTP wire adapter, and it is safe
    # to use from async code as-is. Read by agent/auxiliary_client.py — see
    # "External-process (ACP) providers" in the Hermes model-provider-plugin docs.
    HERMES_SKIP_TRANSPORT_WRAP = True
    HERMES_SKIP_ASYNC_WRAP = True

    def __init__(
        self,
        *,
        api_key: str | None = None,
        base_url: str | None = None,
        default_headers: dict[str, str] | None = None,
        acp_command: str | None = None,
        acp_args: list[str] | None = None,
        acp_cwd: str | None = None,
        command: str | None = None,
        args: list[str] | None = None,
        permission_policy: str | None = None,
        brave_mode: bool | None = None,
        forwarded_tools: frozenset[str] | None = None,
        **_: Any,
    ):
        self.api_key = api_key or "junie-acp"
        self.base_url = base_url or ACP_MARKER_BASE_URL
        self._default_headers = dict(default_headers or {})
        self._acp_command = acp_command or command or _resolve_command()
        self._acp_args = _with_auth(list(acp_args or args or _resolve_args()))
        self._acp_cwd = str(Path(acp_cwd or os.getcwd()).resolve())
        self._permission_policy = permission_policy or _resolve_permission_policy()
        # None => don't override Junie's own Brave Mode setting.
        self._brave_override = brave_mode if brave_mode is not None else _resolve_brave_override()
        # None => forward every Hermes tool; a set => forward only those names.
        self._forwarded_tools = (
            forwarded_tools if forwarded_tools is not None else _resolve_forwarded_tools()
        )
        self.chat = _ACPChatNamespace(self)
        self.is_closed = False

        # Persistent subprocess reused across requests (avoids Junie/JVM cold
        # start on every Hermes step). One process handles many independent
        # sessions; we open a fresh session per request and re-send the full
        # transcript, so we never rely on Junie's cross-turn memory matching
        # Hermes' history (no divergence risk).
        self._handler = _HermesClient(cwd=self._acp_cwd, permission_policy=self._permission_policy)
        # SDK objects live on a dedicated event loop running on a daemon thread.
        self._loop: asyncio.AbstractEventLoop | None = None
        self._loop_thread: threading.Thread | None = None
        self._conn: Any = None  # acp.ClientSideConnection
        self._proc: Any = None  # asyncio subprocess.Process
        self._exit_stack: contextlib.AsyncExitStack | None = None
        self._initialized = False
        # Last lines of the subprocess's stderr, surfaced in failure messages so
        # a crash/auth-rejection gives an actionable reason (not an opaque
        # timeout/connection error).
        self._stderr_tail: deque[str] = deque(maxlen=40)
        # Overridable for tests (fast settle); production keeps the safe gap.
        self._settle_quiet_gap = _SETTLE_QUIET_GAP_SECONDS
        self._settle_max = _SETTLE_MAX_SECONDS
        # True once session/prompt has been dispatched this turn — gates the
        # no-replay retry policy (Junie may already have applied side effects).
        self._prompt_in_flight = False
        # Last ACP session id, reused for a mid-turn tool-result continuation so
        # Junie keeps its own context instead of restarting the task. Cleared
        # whenever the subprocess is closed/respawned.
        self._last_session_id: str | None = None
        # The Hermes tool_call ids Junie asked for in that session's last
        # response. A continuation is only routed back into the session when the
        # incoming tool results answer one of them — otherwise a history that
        # merely ENDS with a tool row (session resume, host-fed transcript) would
        # be delivered to Junie as "here are your results" for work it never
        # requested.
        self._last_requested_call_ids: frozenset[str] = frozenset()
        self._req_lock = threading.Lock()

    # ---- lifecycle ---------------------------------------------------------

    def close(self) -> None:
        self.is_closed = True
        loop = self._loop
        if loop is not None and not loop.is_closed():
            try:
                self._submit(self._aclose_proc(), timeout=5.0)
            except Exception:
                pass
            loop.call_soon_threadsafe(loop.stop)
        thread = self._loop_thread
        if thread is not None:
            thread.join(timeout=3.0)
        if loop is not None and not loop.is_closed() and not (thread and thread.is_alive()):
            # Release the loop's selector/selfpipe fds once its thread has
            # stopped (avoids ResourceWarning: unclosed event loop).
            with contextlib.suppress(Exception):
                loop.close()
        self._loop = None
        self._loop_thread = None

    def _stderr_suffix(self) -> str:
        text = "\n".join(self._stderr_tail).strip()
        return f" (Junie stderr: {text})" if text else ""

    def _ensure_loop(self) -> asyncio.AbstractEventLoop:
        loop = self._loop
        if loop is not None and not loop.is_closed() and self._loop_thread and self._loop_thread.is_alive():
            return loop
        _require_acp()
        loop = asyncio.new_event_loop()
        thread = threading.Thread(target=loop.run_forever, name="junie-acp-loop", daemon=True)
        thread.start()
        self._loop = loop
        self._loop_thread = thread
        return loop

    def _submit(self, coro: Any, *, timeout: float) -> Any:
        """Run ``coro`` on the background loop and block until it finishes."""
        loop = self._loop
        if loop is None:
            raise RuntimeError("Junie ACP event loop is not running.")
        future = asyncio.run_coroutine_threadsafe(coro, loop)
        try:
            return future.result(timeout)
        except concurrent.futures.TimeoutError as exc:
            future.cancel()
            raise TimeoutError("Timed out waiting for the Junie ACP subprocess.") from exc

    async def _aensure_proc(self) -> None:
        """Spawn + handshake the Junie subprocess on demand, reusing a live one."""
        if (
            self._conn is not None
            and self._proc is not None
            and getattr(self._proc, "returncode", 0) is None
            and self._initialized
        ):
            return

        await self._aclose_proc()

        stack = contextlib.AsyncExitStack()
        try:
            conn, proc = await stack.enter_async_context(
                _acp.spawn_agent_process(
                    self._handler,
                    self._acp_command,
                    *self._acp_args,
                    env=_build_subprocess_env(),
                    cwd=self._acp_cwd,
                    transport_kwargs={"limit": _STDIO_LIMIT_BYTES},
                )
            )
        except FileNotFoundError as exc:
            await stack.aclose()
            raise RuntimeError(
                f"Could not start Junie ACP command '{self._acp_command}'. "
                "Install the JetBrains Junie CLI or set HERMES_JUNIE_ACP_COMMAND/JUNIE_CLI_PATH."
            ) from exc

        self._exit_stack = stack
        self._conn = conn
        self._proc = proc
        self._stderr_tail = deque(maxlen=40)
        if getattr(proc, "stderr", None) is not None:
            asyncio.ensure_future(self._adrain_stderr(proc))
        # If the subprocess dies (crash / self-exit), close the connection so any
        # in-flight request is rejected promptly instead of blocking until the
        # turn's wall-clock timeout. The SDK rejects outstanding futures on
        # close(); a clean stdout EOF alone would not.
        asyncio.ensure_future(self._awatch_proc(proc, conn))
        await conn.initialize(
            protocol_version=_acp.PROTOCOL_VERSION,
            client_capabilities=_client_capabilities(),
            client_info=_client_info(),
        )
        self._initialized = True
        self.is_closed = False

    async def _adrain_stderr(self, proc: Any) -> None:
        stream = getattr(proc, "stderr", None)
        if stream is None:
            return
        try:
            async for raw in stream:
                line = raw.decode("utf-8", "replace").rstrip("\n") if isinstance(raw, (bytes, bytearray)) else str(raw).rstrip("\n")
                if line:
                    self._stderr_tail.append(line)
        except Exception:
            return

    async def _awatch_proc(self, proc: Any, conn: Any) -> None:
        try:
            await proc.wait()
        except Exception:
            return
        # Only tear down if this is still the active process (a respawn may have
        # already replaced it).
        if conn is self._conn:
            self._initialized = False
        with contextlib.suppress(Exception):
            await conn.close()

    async def _aclose_proc(self) -> None:
        self._initialized = False
        stack = self._exit_stack
        self._exit_stack = None
        self._conn = None
        self._proc = None
        # Sessions die with the process; never reuse an id across a respawn.
        self._last_session_id = None
        self._last_requested_call_ids = frozenset()
        if stack is not None:
            with contextlib.suppress(Exception):
                await stack.aclose()

    # ---- request path ------------------------------------------------------

    def _create_chat_completion(
        self,
        *,
        model: str | None = None,
        messages: list[dict[str, Any]] | None = None,
        timeout: float | None = None,
        tools: list[dict[str, Any]] | None = None,
        tool_choice: Any = None,
        stream: bool = False,
        **_: Any,
    ) -> Any:
        messages = list(messages or [])
        prompt_text = _format_messages_as_prompt(
            messages,
            model=model,
            tools=tools,
            tool_choice=tool_choice,
            forwarded_tools=self._forwarded_tools,
        )
        # Mid-turn continuation: Hermes just ran the tool call(s) Junie asked for.
        # Replaying the full transcript into a fresh session would make Junie
        # redo the coding work it already did, so send only the results and let
        # _ado_turn reuse the live session (falling back to the full prompt if
        # that session is gone).
        # Secret Shield: scan prompts for credentials (opt-in, off by default).
        # Mode determines behavior: warn (log only), mask (replace), block (raise).
        prompt_text, shield_findings = shield_prompt(prompt_text)

        _trailing = _trailing_tool_results(messages)
        continuation_prompt = (
            _format_tool_results_as_prompt(_trailing)
            if _trailing and self._answers_last_request(_trailing)
            else None
        )
        if continuation_prompt:
            continuation_prompt, cont_findings = shield_prompt(continuation_prompt)
            shield_findings += cont_findings

        # Normalise timeout: run_agent.py may pass an httpx.Timeout object
        # (used natively by the OpenAI SDK) rather than a plain float.
        if timeout is None:
            _effective_timeout = _DEFAULT_TIMEOUT_SECONDS
        elif isinstance(timeout, (int, float)):
            _effective_timeout = float(timeout)
        else:
            _candidates = [
                getattr(timeout, attr, None)
                for attr in ("read", "write", "connect", "pool", "timeout")
            ]
            _numeric = [float(v) for v in _candidates if isinstance(v, (int, float))]
            # An httpx.Timeout with every component None means "no timeout".
            _effective_timeout = max(_numeric) if _numeric else _NO_TIMEOUT_FALLBACK_SECONDS

        response_text, reasoning_text, tool_events, usage_obj = self._run_prompt(
            prompt_text,
            timeout_seconds=_effective_timeout,
            model=model,
            continuation_prompt=continuation_prompt,
        )

        # Junie's OWN tools are already executed by the time we see them, so they
        # are never returned as pending tool_calls (that would make Hermes re-run
        # finished work). They are logged, summarised into `reasoning` for the
        # operator, and projected into the transcript as completed call/result
        # pairs so the self-improvement loop can learn from the real work.
        activity = _render_tool_activity(tool_events)
        if tool_events:
            for ev in tool_events.values():
                logger.info(
                    "Junie ACP tool activity: kind=%s status=%s title=%s",
                    ev.get("kind"), ev.get("status"), ev.get("title"),
                )
        combined_reasoning = "\n\n".join(
            p for p in (
                (f"Junie tool activity:\n{activity}" if activity else ""),
                reasoning_text or "",
            ) if p
        ).strip() or None

        # HERMES tool calls, in contrast, are delegations Junie asks Hermes to
        # run: they arrive as <tool_call> blocks in the response text.
        tool_calls, cleaned_text = _extract_tool_calls_from_text(response_text)
        # Remember what we're owed, so only a matching tool result re-enters this
        # session (see _answers_last_request).
        self._last_requested_call_ids = frozenset(
            str(getattr(tc, "id", "") or "") for tc in tool_calls
        )

        usage = self._build_usage(prompt_text, response_text, reasoning_text, usage_obj)
        assistant_message = SimpleNamespace(
            content=cleaned_text,
            tool_calls=tool_calls,
            reasoning=combined_reasoning,
            reasoning_content=combined_reasoning,
            reasoning_details=None,
        )
        choice = SimpleNamespace(
            message=assistant_message,
            finish_reason="tool_calls" if tool_calls else "stop",
        )
        completion = SimpleNamespace(
            choices=[choice],
            usage=usage,
            model=model or "junie-acp",
            # Consumed by agent/conversation_loop.py: history rows to splice into
            # the transcript, and the tool-iteration count that ticks the
            # skill-review nudge (Junie's iterations happen inside its session,
            # so Hermes' per-iteration counter would otherwise never move).
            hermes_projected_messages=_project_tool_events(
                tool_events, self._last_session_id
            ),
            hermes_provider_tool_iterations=len(tool_events),
        )
        if stream:
            # An ACP turn is one-shot, so "streaming" is a re-shape. The chunk
            # carrier keeps the hermes_* extras (see acp_openai_bridge) so the
            # transcript projection is not silently lost on this path.
            return _completion_to_stream_chunks(completion)
        return completion

    @staticmethod
    def _build_usage(
        prompt_text: str, response_text: str, reasoning_text: str, usage_obj: Any
    ) -> SimpleNamespace:
        """Prefer Junie's own token counts (PromptResponse.usage) and fall back
        to a ~4-chars/token estimate. ACP historically reported no counts, which
        froze the context gauge at 0% and starved the compressor; either source
        keeps both working."""
        prompt_tokens = completion_tokens = cached = 0
        if usage_obj is not None:
            prompt_tokens = int(getattr(usage_obj, "input_tokens", 0) or 0)
            completion_tokens = int(getattr(usage_obj, "output_tokens", 0) or 0)
            completion_tokens += int(getattr(usage_obj, "thought_tokens", 0) or 0)
            cached = int(getattr(usage_obj, "cached_read_tokens", 0) or 0)
        if prompt_tokens <= 0 and completion_tokens <= 0:
            prompt_tokens = _rough_tokens(prompt_text)
            completion_tokens = _rough_tokens(response_text) + _rough_tokens(reasoning_text)
        return SimpleNamespace(
            prompt_tokens=prompt_tokens,
            completion_tokens=completion_tokens,
            total_tokens=prompt_tokens + completion_tokens,
            prompt_tokens_details=SimpleNamespace(cached_tokens=cached),
        )

    def _run_prompt(
        self,
        prompt_text: str,
        *,
        timeout_seconds: float,
        model: str | None = None,
        continuation_prompt: str | None = None,
    ) -> tuple[str, str, dict[str, dict[str, Any]], Any]:
        # Serialize requests: one shared connection + process.
        with self._req_lock:
            self._ensure_loop()
            last_exc: BaseException | None = None
            for attempt in (1, 2):
                self._prompt_in_flight = False
                try:
                    self._submit(self._aensure_proc(), timeout=_HANDSHAKE_TIMEOUT_SECONDS)
                    # Give the turn a bit more wall-clock than the prompt itself
                    # so the post-prompt settle can complete before we bail.
                    turn_timeout = timeout_seconds + self._settle_max + 5.0
                    return self._submit(
                        self._ado_turn(
                            prompt_text,
                            timeout_seconds,
                            model=model,
                            continuation_prompt=continuation_prompt,
                        ),
                        timeout=turn_timeout,
                    )
                except (TimeoutError, RuntimeError, OSError, ConnectionError) as exc:
                    last_exc = exc
                    _retry_continuation = self._continuation_retry_allowed(continuation_prompt)
                    self._safe_close_proc()
                    # Junie is autonomous: once session/prompt is dispatched it may
                    # already have edited files / run commands. Never replay a
                    # dispatched prompt — that would double-apply side effects.
                    # Only retry failures that happened BEFORE the prompt was sent
                    # (e.g. a stale reused subprocess died on session/new), or a
                    # reused-session prompt Junie never acted on (see
                    # _continuation_retry_allowed).
                    if self._prompt_in_flight and not _retry_continuation:
                        logger.warning("Junie ACP turn failed after prompt dispatch; not retrying: %s", exc)
                        raise
                    if _retry_continuation:
                        continuation_prompt = None
                    logger.warning(
                        "Junie ACP turn failed before prompt (attempt %d/2), respawning: %s", attempt, exc
                    )
                except Exception as exc:
                    # RequestError (SDK) and any other agent-side failure.
                    last_exc = exc
                    _retry_continuation = self._continuation_retry_allowed(continuation_prompt)
                    self._safe_close_proc()
                    if self._prompt_in_flight and not _retry_continuation:
                        logger.warning("Junie ACP turn failed after prompt dispatch; not retrying: %s", exc)
                        raise RuntimeError(f"Junie ACP prompt failed: {exc}{self._stderr_suffix()}") from exc
                    if _retry_continuation:
                        continuation_prompt = None
                    logger.warning(
                        "Junie ACP turn failed before prompt (attempt %d/2), respawning: %s", attempt, exc
                    )
            assert last_exc is not None
            # Exhausted the pre-prompt retries — surface Junie's stderr (auth
            # rejection, missing runtime, …) so the failure is actionable.
            suffix = self._stderr_suffix()
            if suffix:
                raise RuntimeError(f"Junie ACP failed to start: {last_exc}{suffix}") from last_exc
            raise last_exc

    def _answers_last_request(self, tool_messages: list[dict[str, Any]]) -> bool:
        """True when these tool results answer the call ids Junie last requested."""
        if not self._last_requested_call_ids:
            return False
        ids = {str(m.get("tool_call_id") or "") for m in tool_messages}
        return bool(ids & self._last_requested_call_ids)

    def _continuation_retry_allowed(self, continuation_prompt: str | None) -> bool:
        """Whether a failed *reused-session* prompt may be retried.

        Session reuse is the one case where a dispatched prompt can fail without
        Junie having done anything: Hermes reuses a session id that Junie may no
        longer know (it reaped the session, or the process was replaced between
        turns), and the agent rejects the request outright. Hard-failing the user
        turn there would be a regression versus never reusing sessions at all.

        The safety condition is that Junie sent us NOTHING for this prompt — no
        session/update, no permission request, no fs call. Junie reports its tool
        calls as they start (status ``pending``) and routes its file writes through
        our fs bridge, so silence means it never acted and the retry cannot
        double-apply a side effect. The retry falls back to a fresh session with
        the full transcript (``continuation_prompt`` is cleared by the caller).
        """
        return continuation_prompt is not None and not self._handler.saw_agent_activity

    def _safe_close_proc(self) -> None:
        with contextlib.suppress(Exception):
            self._submit(self._aclose_proc(), timeout=5.0)

    async def _ado_turn(
        self,
        prompt_text: str,
        timeout_seconds: float,
        model: str | None = None,
        continuation_prompt: str | None = None,
    ) -> tuple[str, str, dict[str, dict[str, Any]], Any]:
        # Mid-turn continuation on a still-live session: keep Junie's own
        # context and send only the tool results. If the session is gone (fresh
        # or respawned process) fall back to the full-transcript prompt in a new
        # session — never send the bare results into a session that has no idea
        # what they belong to.
        reused_session_id = self._last_session_id if continuation_prompt else None
        if reused_session_id:
            logger.debug("Junie ACP reusing session %s for tool-result continuation", reused_session_id)
            buffers = self._new_turn_buffers()
            self._handler.begin_turn(reused_session_id, *buffers)
            return await self._aprompt(
                reused_session_id, continuation_prompt, timeout_seconds, buffers=buffers
            )

        # Cap session/new so a wedged-but-alive reused process fails fast here
        # (pre-prompt → safe to respawn+retry) instead of hanging the whole turn.
        session = await asyncio.wait_for(
            self._conn.new_session(cwd=self._acp_cwd, mcp_servers=[]),
            min(_SESSION_NEW_TIMEOUT_SECONDS, timeout_seconds),
        )
        session_id = str(getattr(session, "session_id", "") or "").strip()
        if not session_id:
            raise RuntimeError("Junie ACP did not return a sessionId.")

        # Forward the requested model to Junie via its ACP config. Skip the
        # "junie-acp" provider sentinel / aliases (those mean "use Junie's own
        # default"); only real Junie model ids (gemini-3-flash-preview,
        # claude-opus-4-8, gpt-5.x, …) are set. Best-effort: an unknown id or a
        # set failure must not abort the prompt.
        requested = (model or "").strip()
        if requested and requested.lower() not in _MODEL_PASSTHROUGH_SENTINELS:
            try:
                await asyncio.wait_for(
                    self._conn.set_config_option(config_id="model", session_id=session_id, value=requested),
                    _CONFIG_OPTION_TIMEOUT_SECONDS,
                )
                logger.info("Junie ACP model set to %s", requested)
            except Exception as exc:
                logger.warning("Junie ACP set model %s failed: %s", requested, exc)

        # Optionally force Junie's Brave Mode. Junie accepts a boolean
        # (true -> ON, false -> OFF) for backward compatibility; best-effort.
        if self._brave_override is not None:
            try:
                await asyncio.wait_for(
                    self._conn.set_config_option(
                        config_id="brave_mode", session_id=session_id, value=bool(self._brave_override)
                    ),
                    _CONFIG_OPTION_TIMEOUT_SECONDS,
                )
                logger.info("Junie ACP brave_mode set to %s", self._brave_override)
            except Exception as exc:
                logger.warning("Junie ACP set brave_mode failed: %s", exc)

        buffers = self._new_turn_buffers()
        self._handler.begin_turn(session_id, *buffers)
        return await self._aprompt(session_id, prompt_text, timeout_seconds, buffers=buffers)

    @staticmethod
    def _new_turn_buffers() -> tuple[list[str], list[str], dict[str, dict[str, Any]]]:
        """Fresh (text, reasoning, tool_events) collection buffers for one turn."""
        return [], [], {}

    async def _aprompt(
        self,
        session_id: str,
        prompt_text: str,
        timeout_seconds: float,
        *,
        buffers: tuple[list[str], list[str], dict[str, dict[str, Any]]],
    ) -> tuple[str, str, dict[str, dict[str, Any]], Any]:
        """Send one session/prompt on an already-prepared session and collect it.

        The caller installs ``buffers`` via ``begin_turn`` and passes the same
        tuple here; the handler fills them from ``session/update`` notifications.
        """
        text_parts, reasoning_parts, tool_events = buffers
        # Mark dispatch so _run_prompt won't replay a prompt Junie may have
        # already acted on (see the retry guard).
        self._prompt_in_flight = True
        self._last_session_id = session_id
        usage_obj: Any = None
        try:
            result = await self._conn.prompt(
                prompt=[_acp.text_block(prompt_text)], session_id=session_id
            )
            usage_obj = getattr(result, "usage", None)
            # The ACP completion response can precede a trailing message chunk;
            # settle until Junie is quiet so we don't truncate the answer.
            await self._handler.settle(self._settle_quiet_gap, min(self._settle_max, timeout_seconds))
        finally:
            self._handler.end_turn()
        # A fresh session is opened per USER turn (we re-send the full
        # transcript), so we never rely on Junie's cross-turn memory matching
        # Hermes' history. The only reuse is within a turn, for tool-result
        # continuations. Sessions are left for the persistent process to reap.
        return "".join(text_parts), "".join(reasoning_parts), tool_events, usage_obj
