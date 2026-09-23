"""Secret Shield — credential detection for the Junie ACP input path.

Opt-in via env var or config.yaml (off by default). Three modes::

    HERMES_JUNIE_ACP_SECRET_SHIELD=warn   # detect, log warning, send original
    HERMES_JUNIE_ACP_SECRET_SHIELD=mask   # detect, mask with [REDACTED], send masked
    HERMES_JUNIE_ACP_SECRET_SHIELD=block  # detect, block delivery entirely

    # 1/true/yes/on are aliases for "mask" (backward compatible)

    # or in config.yaml:
    junie_acp:
      secret_shield: warn   # or mask, block

Toggle precedence: env var > config.yaml > default (off).
When the env var is set (to any value including "0"), config.yaml is not read.
When off, ``shield_prompt`` / ``shield_messages`` return immediately with no
scanning, no config parsing, and no regex execution.

The existing ``agent.redact.redact_sensitive_text`` handles file-read output;
this module protects the *input* path.

Scope: provider prefix patterns, JSON sensitive fields, HTTP headers, auth
schemes, connection string URIs, JWT-shaped tokens (heuristic format recognition
via base64 header, not signature verification). Structured-format scanning
(YAML blocks, XML elements, PEM keys, entropy detection) is deferred to keep
this change reviewable.
"""
from __future__ import annotations

import base64
import binascii
import json
import logging
import os
import re
from dataclasses import dataclass
from typing import Any

logger = logging.getLogger(__name__)
REDACTED = "[REDACTED]"


# ── Public types ─────────────────────────────────────────────────────────────

class RedactionError(ValueError):
    """Redaction failed or blocked; callers must not send the original input."""


@dataclass
class RedactResult:
    text: str
    redacted_count: int


# ── Toggle ───────────────────────────────────────────────────────────────────

_MASK_ALIASES = frozenset({"1", "true", "yes", "on", "mask"})
_VALID_MODES = frozenset({"off", "warn", "mask", "block"})


def _resolve_mode() -> str:
    """Return the active mode: "off", "warn", "mask", or "block".

    Precedence: env var > config.yaml > default ("off").
    When the env var is set to any value (including "0"), config.yaml is never
    consulted.
    """
    raw = os.getenv("HERMES_JUNIE_ACP_SECRET_SHIELD")
    if raw is not None:
        val = raw.strip().lower()
        if val in _VALID_MODES:
            return val
        if val in _MASK_ALIASES:
            return "mask"
        return "off"
    try:
        from hermes_cli.config import load_config_readonly
        block = load_config_readonly().get("junie_acp")
        if isinstance(block, dict):
            val = str(block.get("secret_shield", "") or "").strip().lower()
            if val in _VALID_MODES:
                return val
            if val in _MASK_ALIASES:
                return "mask"
    except Exception:
        pass
    return "off"


def is_enabled() -> bool:
    """Return True if Secret Shield is active in any mode (warn, mask, or block)."""
    return _resolve_mode() != "off"


# ── Engine ───────────────────────────────────────────────────────────────────

class SecretRedactor:
    """Single-class credential redactor.

    Detection strategies (in scan order):
    1. Known provider API key prefixes (16 providers)
    2. JSON sensitive fields (``"password": "value"``)
    3. HTTP headers (``Authorization:``, ``Cookie:``, ``X-Api-Key:``)
    4. Auth schemes (``Bearer``, ``Basic``, ``OAuth``)
    5. Connection string URIs (``postgres://user:pass@host``)
    6. JWT-shaped tokens (heuristic: base64-decoded header contains ``alg`` or ``enc``)

    Deferred to follow-up (to keep this change small and reviewable):
    YAML block scalars, XML elements, INI sections, PEM/SSH private key blocks,
    entropy-based opaque string detection. PEM keys are the highest-priority
    candidate for the next iteration.
    """

    # -- Known provider prefixes -------------------------------------------

    _PREFIX_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = tuple(
        (name, re.compile(pattern)) for name, pattern in (
            ("google_api",     r"AIza[A-Za-z0-9_-]{20,}"),
            ("google_oauth",   r"GOCSPX-[A-Za-z0-9_-]{10,}"),
            ("google_access",  r"ya29\.[A-Za-z0-9._~-]{10,}"),
            ("sk_family",      r"sk-[A-Za-z0-9_-]{12,}"),
            ("groq",           r"gsk_[A-Za-z0-9_-]{12,}"),
            ("github",         r"(?:gh[pousr]_[A-Za-z0-9_]{12,}|github_pat_[A-Za-z0-9_]{12,})"),
            ("gitlab",         r"(?:glpat|glrt|gldt|glsoat|glcbt)-[A-Za-z0-9_-]{10,}"),
            ("aws_id",         r"(?:AKIA|ASIA)[A-Z0-9]{16}"),
            ("junie",          r"perm-[A-Za-z0-9_-]{12,}"),
            ("stripe",         r"[sr]k_(?:live|test)_[A-Za-z0-9]{8,}"),
            ("slack",          r"(?:xox[a-z]|xapp)-[A-Za-z0-9_-]{8,}"),
            ("sendgrid",       r"SG\.[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}"),
            ("huggingface",    r"hf_[A-Za-z0-9]{12,}"),
            ("npm",            r"npm_[A-Za-z0-9]{12,}"),
            ("pypi",           r"pypi-[A-Za-z0-9_-]{12,}"),
            ("vault",          r"hv[sbr]\.[A-Za-z0-9_-]{12,}"),
        )
    )

    # -- Contextual patterns -----------------------------------------------

    _JSON_SENSITIVE = re.compile(
        r'"(?P<key>password|passwd|pwd|secret|token|api_key|apikey|'
        r'client_secret|access_token|refresh_token|private_key|authorization)"'
        r'\s*:\s*(?P<value>"(?:[^"\\]|\\.)*")'
    )
    _HEADER = re.compile(
        r"(?i)^[ \t]*(?:authorization|proxy-authorization|cookie|set-cookie|x-api-key)"
        r"[ \t]*:[ \t]*(?P<value>[^\r\n]+)",
        re.MULTILINE
    )
    _AUTH = re.compile(
        r"(?i)\b(?:Bearer|Basic|OAuth)\s+(?P<value>[A-Za-z0-9._+/=-]{8,})"
    )
    _URI = re.compile(
        r"\b(?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis(?:s)?|amqp(?:s)?)"
        r"://(?P<userinfo>[^/\s?#<>\"']+)@"
    )
    _JWT = re.compile(
        r"(?<![A-Za-z0-9_-])"
        r"(?P<token>[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*)"
        r"(?![A-Za-z0-9_.-])"
    )

    # -- Public API --------------------------------------------------------

    def redact(self, text: str) -> RedactResult:
        if not isinstance(text, str):
            raise TypeError("text must be str")
        result = text
        count = 0

        # 1. Known provider prefixes.
        for _name, pattern in self._PREFIX_PATTERNS:
            def _replace(m: re.Match[str]) -> str:
                nonlocal count
                count += 1
                return REDACTED
            result = pattern.sub(_replace, result)

        # 2. JSON sensitive fields.
        def _replace_json(m: re.Match[str]) -> str:
            nonlocal count
            value = m.group("value")
            if not value or value == f'"{REDACTED}"':
                return m.group(0)
            count += 1
            return m.group(0)[:m.start("value") - m.start()] + f'"{REDACTED}"' + m.group(0)[m.end("value") - m.start():]
        result = self._JSON_SENSITIVE.sub(_replace_json, result)

        # 3–4. Headers and auth schemes.
        for pattern in (self._HEADER, self._AUTH):
            def _replace_header(m: re.Match[str]) -> str:
                nonlocal count
                value = m.group("value")
                if value == REDACTED:
                    return m.group(0)
                count += 1
                return m.group(0)[:m.start("value") - m.start()] + REDACTED + m.group(0)[m.end("value") - m.start():]
            result = pattern.sub(_replace_header, result)

        # 5. Connection string URIs.
        def _replace_uri(m: re.Match[str]) -> str:
            nonlocal count
            userinfo = m.group("userinfo")
            if userinfo == REDACTED:
                return m.group(0)
            count += 1
            return m.group(0)[:m.start("userinfo") - m.start()] + REDACTED + m.group(0)[m.end("userinfo") - m.start():]
        result = self._URI.sub(_replace_uri, result)

        # 6. JWT-shaped tokens (heuristic format recognition, not signature verification).
        def _replace_jwt(m: re.Match[str]) -> str:
            nonlocal count
            token = m.group("token")
            parts = token.split(".")
            if len(parts) != 3:
                return token
            try:
                raw = base64.b64decode(parts[0] + "=" * (-len(parts[0]) % 4), altchars=b"-_", validate=True)
                header = json.loads(raw)
            except (ValueError, UnicodeError, binascii.Error):
                return token
            if isinstance(header, dict) and ("alg" in header or "enc" in header):
                count += 1
                return REDACTED
            return token
        result = self._JWT.sub(_replace_jwt, result)

        return RedactResult(text=result, redacted_count=count)

    def scan(self, text: str) -> int:
        """Detect credentials without masking. Returns the number of findings."""
        if not isinstance(text, str):
            raise TypeError("text must be str")
        return self.redact(text).redacted_count

    def redact_messages(self, messages: list[dict[str, object]]) -> tuple[list[dict[str, object]], int]:
        """Redact secrets in OpenAI-format message dicts.

        Only string ``content`` fields are scanned. Returns a new list
        (original is not mutated) and the total count of masked secrets.
        """
        if not isinstance(messages, list):
            raise TypeError("messages must be a list of dictionaries")
        total = 0
        out: list[dict[str, object]] = []
        for msg in messages:
            if not isinstance(msg, dict):
                raise TypeError("messages must be a list of dictionaries")
            content = msg.get("content")
            if isinstance(content, str):
                r = self.redact(content)
                total += r.redacted_count
                out.append({**msg, "content": r.text})
            else:
                out.append(msg)
        if total:
            logger.warning("Redacted %d sensitive spans/fields in outbound messages", total)
        return out, total

    def scan_messages(self, messages: list[dict[str, object]]) -> int:
        """Detect credentials in messages without masking. Returns finding count."""
        if not isinstance(messages, list):
            raise TypeError("messages must be a list of dictionaries")
        total = 0
        for msg in messages:
            if not isinstance(msg, dict):
                raise TypeError("messages must be a list of dictionaries")
            content = msg.get("content")
            if isinstance(content, str):
                total += self.redact(content).redacted_count
        return total


# ── Module-level convenience API ─────────────────────────────────────────────

_DEFAULT = SecretRedactor()


def redact_secrets(text: str) -> RedactResult:
    return _DEFAULT.redact(text)


def redact_messages(messages: list[dict[str, object]]) -> tuple[list[dict[str, object]], int]:
    return _DEFAULT.redact_messages(messages)


def redact_prompt(prompt_text: str) -> tuple[str, int]:
    result = _DEFAULT.redact(prompt_text)
    if result.redacted_count:
        logger.warning("Redacted %d sensitive spans/fields in outbound prompt", result.redacted_count)
    return result.text, result.redacted_count


# ── Toggle-aware public API ──────────────────────────────────────────────────
#
# These are the entry points used by client.py.
#
# Modes:
#   off   — no scanning, immediate passthrough
#   warn  — detect, log a warning with finding count, send original unchanged
#   mask  — detect, replace findings with [REDACTED], send masked version
#   block — detect, raise RedactionError if findings > 0, never send
#
# In all active modes, if the redactor itself raises an unexpected exception,
# RedactionError is raised (fail-closed).

def shield_prompt(prompt_text: str) -> tuple[str, int]:
    """Apply Secret Shield to a prompt string. Returns (text, finding_count).

    In "warn" mode the original text is returned (findings are only logged).
    In "mask" mode the masked text is returned.
    In "block" mode RedactionError is raised if any findings.
    """
    mode = _resolve_mode()
    if mode == "off":
        return prompt_text, 0
    try:
        if mode == "warn":
            count = _DEFAULT.scan(prompt_text)
            if count:
                logger.warning(
                    "\U0001f6e1 Secret Shield [warn]: detected %d potential credential(s) in prompt, sending original",
                    count,
                )
            return prompt_text, count
        if mode == "block":
            count = _DEFAULT.scan(prompt_text)
            if count:
                raise RedactionError(
                    f"Secret Shield [block]: detected {count} potential credential(s), delivery blocked"
                )
            return prompt_text, 0
        # mode == "mask"
        return redact_prompt(prompt_text)
    except RedactionError:
        raise
    except Exception as exc:
        raise RedactionError(
            "Secret Shield failed; blocking delivery to prevent credential leak"
        ) from exc


def shield_messages(
    messages: list[dict[str, object]],
) -> tuple[list[dict[str, object]], int]:
    """Apply Secret Shield to a message list. Returns (messages, finding_count).

    In "warn" mode the original list is returned (findings are only logged).
    In "mask" mode a new list with masked content is returned.
    In "block" mode RedactionError is raised if any findings.
    """
    mode = _resolve_mode()
    if mode == "off":
        return messages, 0
    try:
        if mode == "warn":
            count = _DEFAULT.scan_messages(messages)
            if count:
                logger.warning(
                    "\U0001f6e1 Secret Shield [warn]: detected %d potential credential(s) in messages, sending original",
                    count,
                )
            return messages, count
        if mode == "block":
            count = _DEFAULT.scan_messages(messages)
            if count:
                raise RedactionError(
                    f"Secret Shield [block]: detected {count} potential credential(s), delivery blocked"
                )
            return messages, 0
        # mode == "mask"
        return redact_messages(messages)
    except RedactionError:
        raise
    except Exception as exc:
        raise RedactionError(
            "Secret Shield failed; blocking delivery to prevent credential leak"
        ) from exc
