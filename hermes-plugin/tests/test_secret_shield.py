"""Tests for secret_shield — credential masking on the prompt input path.

Synthetic data only. No real credentials, no network. Run:
    python3 -m pytest tests/test_secret_shield.py -v --import-mode=importlib --rootdir=tests
"""
from __future__ import annotations

import logging
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

_plugin_dir = Path(__file__).resolve().parent.parent / "junie_hermes"
if str(_plugin_dir) not in sys.path:
    sys.path.insert(0, str(_plugin_dir))

from secret_shield import (
    REDACTED, RedactResult, RedactionError, SecretRedactor,
    redact_secrets, redact_messages, redact_prompt,
    shield_prompt, shield_messages, _resolve_mode,
)

R = SecretRedactor()


# ── Provider prefix patterns ─────────────────────────────────────────────────

class TestPrefixPatterns(unittest.TestCase):

    CASES = {
        "google_api":    "AIza" + "a" * 32,
        "google_oauth":  "GOCSPX-" + "a" * 24,
        "google_access": "ya29." + "a" * 24,
        "openai":        "sk-proj-" + "a" * 30,
        "anthropic":     "sk-ant-api03-" + "a" * 30,
        "groq":          "gsk_" + "a" * 24,
        "github":        "ghp_" + "a" * 30,
        "github_fine":   "github_pat_" + "a" * 30,
        "gitlab":        "glpat-" + "a" * 24,
        "aws":           "AKIA" + "A" * 16,
        "junie":         "perm-" + "a" * 24,
        "stripe":        "sk_live_" + "a" * 24,
        "slack":         "xoxb-" + "a" * 24,
        "sendgrid":      "SG." + "a" * 24 + "." + "b" * 24,
        "huggingface":   "hf_" + "a" * 24,
        "npm":           "npm_" + "a" * 24,
        "pypi":          "pypi-" + "a" * 24,
        "vault":         "hvs." + "a" * 24,
    }

    def test_each_prefix(self):
        for name, key in self.CASES.items():
            with self.subTest(name=name):
                r = R.redact(f"my key is {key}")
                self.assertNotIn(key, r.text, f"key for {name} was not redacted")
                self.assertIn(REDACTED, r.text)
                self.assertEqual(r.redacted_count, 1)

    def test_prefix_in_code_context(self):
        r = R.redact('export OPENAI_API_KEY="sk-proj-abc123def456ghi789jkl012mno"')
        self.assertNotIn("abc123def456", r.text)
        self.assertGreaterEqual(r.redacted_count, 1)


# ── HTTP headers and auth schemes ────────────────────────────────────────────

class TestHeaders(unittest.TestCase):

    def test_authorization_header(self):
        r = R.redact("Authorization: Bearer eyJhbGciOiJSUzI1NiJ9.payload.sig")
        self.assertIn(REDACTED, r.text)

    def test_cookie_header(self):
        r = R.redact("Cookie: session=abc123; path=/")
        self.assertNotIn("abc123", r.text)

    def test_bearer_inline(self):
        r = R.redact("use Bearer my_token_value_here_1234 for auth")
        self.assertNotIn("my_token_value_here_1234", r.text)

    def test_x_api_key_header(self):
        r = R.redact("X-Api-Key: abcdefghij123456")
        self.assertNotIn("abcdefghij123456", r.text)


# ── Connection string URIs ───────────────────────────────────────────────────

class TestConnectionStrings(unittest.TestCase):

    def test_postgres(self):
        r = R.redact("postgres://admin:s3cret@db.example.com:5432/mydb")
        self.assertNotIn("s3cret", r.text)
        self.assertNotIn("admin", r.text)
        self.assertIn("@db.example.com", r.text)

    def test_mysql(self):
        r = R.redact("mysql://root:password123@localhost:3306/db")
        self.assertNotIn("password123", r.text)

    def test_mongodb_srv(self):
        r = R.redact("mongodb+srv://user:pass@cluster.example.com/db")
        self.assertNotIn("pass", r.text)

    def test_redis(self):
        r = R.redact("redis://default:mysecret@redis.host:6379")
        self.assertNotIn("mysecret", r.text)


# ── JWT-shaped tokens ────────────────────────────────────────────────────────

class TestJWT(unittest.TestCase):

    def _make_jwt(self, header: dict, payload: str = "eyJzdWIiOiJ4In0", sig: str = "signature") -> str:
        import base64, json
        h = base64.urlsafe_b64encode(json.dumps(header).encode()).decode().rstrip("=")
        return f"{h}.{payload}.{sig}"

    def test_valid_jwt(self):
        jwt = self._make_jwt({"alg": "HS256", "typ": "JWT"})
        r = R.redact(f"token: {jwt}")
        self.assertNotIn(jwt, r.text)
        self.assertIn(REDACTED, r.text)

    def test_not_a_jwt(self):
        r = R.redact("some.dotted.path is fine")
        self.assertEqual(r.redacted_count, 0)

    def test_jwt_in_env_var(self):
        jwt = self._make_jwt({"alg": "RS256"})
        r = R.redact(f'export TOKEN="{jwt}"')
        self.assertNotIn(jwt, r.text)


# ── JSON sensitive fields ────────────────────────────────────────────────────

class TestJsonFields(unittest.TestCase):

    def test_password_field(self):
        r = R.redact('{"password":"mysecret","port":5432}')
        self.assertNotIn("mysecret", r.text)
        self.assertIn("port", r.text)

    def test_api_key_field(self):
        r = R.redact('{"api_key":"sk-abc123"}')
        self.assertNotIn("sk-abc123", r.text)

    def test_nested_token(self):
        r = R.redact('{"config":{"token":"secret123"}}')
        self.assertNotIn("secret123", r.text)

    def test_non_sensitive_preserved(self):
        text = '{"name":"alice","port":5432}'
        r = R.redact(text)
        self.assertEqual(r.text, text)
        self.assertEqual(r.redacted_count, 0)


# ── Clean passthrough (no false positives) ───────────────────────────────────

class TestCleanPassthrough(unittest.TestCase):

    def test_plain_text(self):
        self.assertEqual(R.redact("Hello, please review this code for bugs.").redacted_count, 0)

    def test_code_snippet(self):
        text = 'fn main() {\n    let x = 42;\n    println!("hello {}", x);\n}'
        self.assertEqual(R.redact(text).redacted_count, 0)

    def test_url_without_creds(self):
        self.assertEqual(R.redact("visit https://example.com/api/v1/users").redacted_count, 0)

    def test_port_number(self):
        self.assertEqual(R.redact("port=5432 host=localhost").redacted_count, 0)

    def test_empty(self):
        self.assertEqual(R.redact("").redacted_count, 0)

    def test_password_discussion(self):
        """Developer prose about auth must not be redacted."""
        self.assertEqual(R.redact("The password is hashed with bcrypt before it hits the DB").redacted_count, 0)

    def test_auth_middleware_discussion(self):
        self.assertEqual(R.redact("auth: middleware order is wrong, fix it").redacted_count, 0)

    def test_api_key_test_discussion(self):
        self.assertEqual(R.redact("Add a test: api_key=missing should return 401, not 500").redacted_count, 0)

    def test_password_docs_discussion(self):
        self.assertEqual(R.redact("In the docs, password: required must become password: optional").redacted_count, 0)

    def test_client_secret_discussion(self):
        self.assertEqual(R.redact("The client_secret is read from Vault at boot; document that.").redacted_count, 0)


# ── Multiple secrets ─────────────────────────────────────────────────────────

class TestMultipleSecrets(unittest.TestCase):

    def test_two_prefixes(self):
        key1 = "ghp_" + "a" * 30
        key2 = "gsk_" + "b" * 24
        r = R.redact(f"keys: {key1} and {key2}")
        self.assertNotIn(key1, r.text)
        self.assertNotIn(key2, r.text)
        self.assertEqual(r.redacted_count, 2)

    def test_prefix_and_uri(self):
        key = "AIza" + "a" * 32
        r = R.redact(f"key={key} db=postgres://user:pass@host/db")
        self.assertNotIn(key, r.text)
        self.assertNotIn("user:pass", r.text)
        self.assertGreaterEqual(r.redacted_count, 2)


# ── Idempotency ──────────────────────────────────────────────────────────────

class TestIdempotency(unittest.TestCase):

    EXAMPLES = [
        "my key is ghp_" + "a" * 30,
        "Authorization: Bearer my_token_value_here_1234",
        "postgres://admin:s3cret@db.example.com/mydb",
        '{"password":"mysecret","port":5432}',
        "use Bearer " + "x" * 20 + " for auth",
    ]

    def test_double_redact(self):
        for text in self.EXAMPLES:
            with self.subTest(text=text[:40]):
                first = R.redact(text)
                second = R.redact(first.text)
                self.assertEqual(first.text, second.text, "output changed on second pass")
                self.assertEqual(second.redacted_count, 0, "second pass found new secrets")


# ── Overlapping detectors ────────────────────────────────────────────────────

class TestOverlap(unittest.TestCase):

    def test_prefix_inside_assignment_context(self):
        key = "sk-proj-" + "a" * 30
        r = R.redact(f"api_key={key}")
        self.assertNotIn(key, r.text)

    def test_bearer_with_prefix_token(self):
        r = R.redact("Authorization: Bearer ghp_" + "a" * 30)
        self.assertNotIn("ghp_", r.text)

    def test_uri_with_prefix_password(self):
        key = "gsk_" + "a" * 24
        r = R.redact(f"postgres://user:{key}@host/db")
        self.assertNotIn(key, r.text)


# ── Error behavior (fail-closed) ─────────────────────────────────────────────

class TestErrorBehavior(unittest.TestCase):

    def test_mask_raises_on_internal_error(self):
        with patch.dict(os.environ, {"HERMES_JUNIE_ACP_SECRET_SHIELD": "mask"}):
            with patch.object(SecretRedactor, "redact", side_effect=RuntimeError("boom")):
                with self.assertRaises(RedactionError):
                    shield_prompt("some input")

    def test_warn_raises_on_internal_error(self):
        with patch.dict(os.environ, {"HERMES_JUNIE_ACP_SECRET_SHIELD": "warn"}):
            with patch.object(SecretRedactor, "scan", side_effect=RuntimeError("boom")):
                with self.assertRaises(RedactionError):
                    shield_prompt("some input")

    def test_block_raises_on_internal_error(self):
        with patch.dict(os.environ, {"HERMES_JUNIE_ACP_SECRET_SHIELD": "block"}):
            with patch.object(SecretRedactor, "scan", side_effect=RuntimeError("boom")):
                with self.assertRaises(RedactionError):
                    shield_prompt("some input")

    def test_off_does_not_raise(self):
        with patch.dict(os.environ, {"HERMES_JUNIE_ACP_SECRET_SHIELD": "0"}):
            with patch.object(SecretRedactor, "redact", side_effect=RuntimeError("boom")):
                text, count = shield_prompt("some input")
                self.assertEqual(count, 0)

    def test_error_message_has_no_secrets(self):
        with patch.dict(os.environ, {"HERMES_JUNIE_ACP_SECRET_SHIELD": "mask"}):
            with patch.object(SecretRedactor, "redact", side_effect=RuntimeError("boom")):
                with self.assertRaises(RedactionError) as ctx:
                    shield_prompt("some input")
                self.assertNotIn("some input", str(ctx.exception))


# ── Mode resolution ──────────────────────────────────────────────────────────

class TestModeResolution(unittest.TestCase):

    def test_default_is_off(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(_resolve_mode(), "off")

    def test_env_0_is_off(self):
        with patch.dict(os.environ, {"HERMES_JUNIE_ACP_SECRET_SHIELD": "0"}):
            self.assertEqual(_resolve_mode(), "off")

    def test_env_false_is_off(self):
        with patch.dict(os.environ, {"HERMES_JUNIE_ACP_SECRET_SHIELD": "false"}):
            self.assertEqual(_resolve_mode(), "off")

    def test_env_off_is_off(self):
        with patch.dict(os.environ, {"HERMES_JUNIE_ACP_SECRET_SHIELD": "off"}):
            self.assertEqual(_resolve_mode(), "off")

    def test_env_1_is_mask(self):
        with patch.dict(os.environ, {"HERMES_JUNIE_ACP_SECRET_SHIELD": "1"}):
            self.assertEqual(_resolve_mode(), "mask")

    def test_env_true_is_mask(self):
        with patch.dict(os.environ, {"HERMES_JUNIE_ACP_SECRET_SHIELD": "true"}):
            self.assertEqual(_resolve_mode(), "mask")

    def test_env_mask_is_mask(self):
        with patch.dict(os.environ, {"HERMES_JUNIE_ACP_SECRET_SHIELD": "mask"}):
            self.assertEqual(_resolve_mode(), "mask")

    def test_env_warn_is_warn(self):
        with patch.dict(os.environ, {"HERMES_JUNIE_ACP_SECRET_SHIELD": "warn"}):
            self.assertEqual(_resolve_mode(), "warn")

    def test_env_block_is_block(self):
        with patch.dict(os.environ, {"HERMES_JUNIE_ACP_SECRET_SHIELD": "block"}):
            self.assertEqual(_resolve_mode(), "block")

    def test_env_skips_config_yaml(self):
        with patch.dict(os.environ, {"HERMES_JUNIE_ACP_SECRET_SHIELD": "0"}):
            with patch.dict(sys.modules, {"hermes_cli": None, "hermes_cli.config": None}):
                self.assertEqual(_resolve_mode(), "off")


# ── Warn mode ────────────────────────────────────────────────────────────────

class TestWarnMode(unittest.TestCase):

    _KEY = "ghp_" + "a" * 30

    def test_warn_returns_original_text(self):
        with patch.dict(os.environ, {"HERMES_JUNIE_ACP_SECRET_SHIELD": "warn"}):
            text, count = shield_prompt(f"key is {self._KEY}")
        self.assertEqual(count, 1)
        self.assertIn(self._KEY, text)

    def test_warn_logs_warning(self):
        with patch.dict(os.environ, {"HERMES_JUNIE_ACP_SECRET_SHIELD": "warn"}):
            with self.assertLogs("secret_shield", level="WARNING") as logs:
                shield_prompt(f"key is {self._KEY}")
        combined = "\n".join(logs.output)
        self.assertIn("warn", combined)
        self.assertIn("1", combined)
        self.assertNotIn(self._KEY, combined)

    def test_warn_messages_returns_original(self):
        messages = [{"role": "user", "content": f"key is {self._KEY}"}]
        with patch.dict(os.environ, {"HERMES_JUNIE_ACP_SECRET_SHIELD": "warn"}):
            result, count = shield_messages(messages)
        self.assertEqual(count, 1)
        self.assertIs(result, messages)

    def test_warn_clean_input_no_log(self):
        with patch.dict(os.environ, {"HERMES_JUNIE_ACP_SECRET_SHIELD": "warn"}):
            text, count = shield_prompt("just normal text")
        self.assertEqual(count, 0)
        self.assertEqual(text, "just normal text")


# ── Mask mode ────────────────────────────────────────────────────────────────

class TestMaskMode(unittest.TestCase):

    _KEY = "ghp_" + "a" * 30

    def test_mask_replaces_secret(self):
        with patch.dict(os.environ, {"HERMES_JUNIE_ACP_SECRET_SHIELD": "mask"}):
            text, count = shield_prompt(f"key is {self._KEY}")
        self.assertEqual(count, 1)
        self.assertNotIn(self._KEY, text)
        self.assertIn(REDACTED, text)

    def test_mask_messages(self):
        messages = [{"role": "user", "content": f"key is {self._KEY}"}]
        with patch.dict(os.environ, {"HERMES_JUNIE_ACP_SECRET_SHIELD": "mask"}):
            result, count = shield_messages(messages)
        self.assertEqual(count, 1)
        self.assertNotIn(self._KEY, repr(result))

    def test_1_is_alias_for_mask(self):
        with patch.dict(os.environ, {"HERMES_JUNIE_ACP_SECRET_SHIELD": "1"}):
            text, count = shield_prompt(f"key is {self._KEY}")
        self.assertNotIn(self._KEY, text)
        self.assertEqual(count, 1)


# ── Block mode ───────────────────────────────────────────────────────────────

class TestBlockMode(unittest.TestCase):

    _KEY = "ghp_" + "a" * 30

    def test_block_raises_on_finding(self):
        with patch.dict(os.environ, {"HERMES_JUNIE_ACP_SECRET_SHIELD": "block"}):
            with self.assertRaises(RedactionError) as ctx:
                shield_prompt(f"key is {self._KEY}")
            self.assertIn("block", str(ctx.exception))
            self.assertNotIn(self._KEY, str(ctx.exception))

    def test_block_messages_raises_on_finding(self):
        messages = [{"role": "user", "content": f"key is {self._KEY}"}]
        with patch.dict(os.environ, {"HERMES_JUNIE_ACP_SECRET_SHIELD": "block"}):
            with self.assertRaises(RedactionError):
                shield_messages(messages)

    def test_block_clean_input_passes(self):
        with patch.dict(os.environ, {"HERMES_JUNIE_ACP_SECRET_SHIELD": "block"}):
            text, count = shield_prompt("just normal text")
        self.assertEqual(count, 0)
        self.assertEqual(text, "just normal text")


# ── Off mode ─────────────────────────────────────────────────────────────────

class TestOffMode(unittest.TestCase):

    _KEY = "ghp_" + "a" * 30

    def test_off_returns_original(self):
        with patch.dict(os.environ, {"HERMES_JUNIE_ACP_SECRET_SHIELD": "off"}):
            text, count = shield_prompt(f"key is {self._KEY}")
        self.assertEqual(count, 0)
        self.assertIn(self._KEY, text)

    def test_off_messages_returns_same_object(self):
        messages = [{"role": "user", "content": f"key is {self._KEY}"}]
        with patch.dict(os.environ, {"HERMES_JUNIE_ACP_SECRET_SHIELD": "off"}):
            result, count = shield_messages(messages)
        self.assertEqual(count, 0)
        self.assertIs(result, messages)

    def test_default_off(self):
        with patch.dict(os.environ, {}, clear=True):
            text, count = shield_prompt(f"key is {self._KEY}")
        self.assertEqual(count, 0)
        self.assertIn(self._KEY, text)


# ── Logging safety ───────────────────────────────────────────────────────────

class TestLogging(unittest.TestCase):

    def test_no_secrets_in_log_output(self):
        key = "ghp_" + "x" * 30
        with self.assertLogs("secret_shield", level="WARNING") as logs:
            redact_prompt(f"my key is {key}")
        combined = "\n".join(logs.output)
        self.assertNotIn(key, combined)
        self.assertIn("Redacted", combined)

    def test_no_secrets_in_messages_log(self):
        key = "gsk_" + "y" * 24
        with self.assertLogs("secret_shield", level="WARNING") as logs:
            R.redact_messages([{"role": "user", "content": f"use {key}"}])
        self.assertNotIn(key, "\n".join(logs.output))


# ── Malformed and edge-case input ────────────────────────────────────────────

class TestMalformed(unittest.TestCase):

    def test_very_long_input(self):
        key = "ghp_" + "a" * 30
        text = f"key is {key} " + "x" * 100_000
        r = R.redact(text)
        self.assertNotIn(key, r.text)

    def test_prefix_at_end_of_input(self):
        key = "AKIA" + "A" * 16
        r = R.redact(f"key is {key}")
        self.assertNotIn(key, r.text)

    def test_prefix_surrounded_by_quotes(self):
        key = "ghp_" + "a" * 30
        r = R.redact(f'"{key}"')
        self.assertNotIn(key, r.text)

    def test_newlines_around_prefix(self):
        key = "gsk_" + "b" * 24
        r = R.redact(f"first line\n{key}\nlast line")
        self.assertNotIn(key, r.text)

    def test_only_redacted_marker(self):
        r = R.redact(REDACTED)
        self.assertEqual(r.redacted_count, 0)

    def test_unicode_around_prefix(self):
        key = "perm-" + "c" * 24
        r = R.redact(f"chiave è {key} usala")
        self.assertNotIn(key, r.text)


# ── Message wrapper ──────────────────────────────────────────────────────────

class TestMessages(unittest.TestCase):

    def test_masks_content(self):
        key = "ghp_" + "a" * 30
        messages = [
            {"role": "system", "content": "You are helpful."},
            {"role": "user", "content": f"my key is {key}"},
        ]
        result, count = R.redact_messages(messages)
        self.assertEqual(count, 1)
        self.assertIn(REDACTED, result[1]["content"])
        self.assertIn("ghp_", messages[1]["content"])

    def test_non_string_preserved(self):
        messages = [{"role": "user", "content": [{"type": "text", "text": "hello"}]}]
        result, count = R.redact_messages(messages)
        self.assertEqual(count, 0)

    def test_clean_passthrough(self):
        messages = [{"role": "user", "content": "fix the bug"}]
        result, count = R.redact_messages(messages)
        self.assertEqual(count, 0)
        self.assertEqual(result[0]["content"], "fix the bug")


# ── Type safety ──────────────────────────────────────────────────────────────

class TestTypes(unittest.TestCase):

    def test_none_raises(self):
        with self.assertRaises(TypeError):
            redact_secrets(None)

    def test_int_raises(self):
        with self.assertRaises(TypeError):
            redact_secrets(123)

    def test_prompt_wrapper_returns(self):
        key = "ghp_" + "z" * 30
        text, count = redact_prompt(f"use {key}")
        self.assertIsInstance(text, str)
        self.assertEqual(count, 1)

    def test_empty_messages(self):
        self.assertEqual(redact_messages([]), ([], 0))

    def test_bad_messages_type(self):
        with self.assertRaises(TypeError):
            redact_messages("not a list")

    def test_bad_message_item(self):
        with self.assertRaises(TypeError):
            redact_messages(["not a dict"])


if __name__ == "__main__":
    unittest.main()
