# Path: .github/scripts/test_send_ipa_telegram.py
import contextlib
from email import policy
from email.parser import BytesParser
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

import send_ipa_telegram as sender


class IPADeliveryTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "Sonivo-unsigned.ipa"
        self.path.write_bytes(b"PK\x03\x04test-ipa\x00\xff")
        self.env = {"TELEGRAM_BOT_TOKEN": "123456:TEST_ONLY_NOT_A_SECRET",
                    "TELEGRAM_CHAT_ID": "987654", "GITHUB_REPOSITORY": "owner/repo",
                    "GITHUB_SHA": "a" * 40, "GITHUB_RUN_ID": "42"}
        self.transport = Mock(return_value=(200, json.dumps({
            "ok": True, "result": {"message_id": 7, "document": {"file_id": "file"}}
        }).encode()))

    def invoke(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = sender.main(self.env, self.path, self.transport)
        self.assertNotIn(self.env.get("TELEGRAM_BOT_TOKEN", "NEVER"), output.getvalue())
        return status, output.getvalue()

    def test_success_uploads_exact_file_and_unsigned_caption(self):
        self.assertEqual(self.invoke()[0], 0)
        self.transport.assert_called_once()
        token, body, content_type = self.transport.call_args.args
        message = BytesParser(policy=policy.default).parsebytes(
            f"Content-Type: {content_type}\r\nMIME-Version: 1.0\r\n\r\n".encode() + body)
        parts = {p.get_param("name", header="content-disposition"): p
                 for p in message.iter_parts()}
        self.assertEqual(parts["document"].get_payload(decode=True), self.path.read_bytes())
        self.assertEqual(parts["document"].get_filename(), "Sonivo-unsigned.ipa")
        caption = parts["caption"].get_payload(decode=True).decode()
        self.assertIn("без подписи", caption)
        self.assertIn("https://github.com/owner/repo/actions/runs/42", caption)
        self.assertNotIn("{{", caption)
        self.assertNotIn(token.encode(), body)
        self.assertEqual(parts["chat_id"].get_payload(decode=True), b"987654")

    def test_no_fallback_chat(self):
        del self.env["TELEGRAM_CHAT_ID"]
        status, output = self.invoke()
        self.assertEqual(status, 1)
        self.assertIn("missing_chat", output)
        self.transport.assert_not_called()

    def test_invalid_configuration_never_sends(self):
        cases = [("TELEGRAM_BOT_TOKEN", "", "missing_token"),
                 ("TELEGRAM_BOT_TOKEN", "bad token", "invalid_token"),
                 ("TELEGRAM_CHAT_ID", "0", "invalid_chat"),
                 ("TELEGRAM_CHAT_ID", "123456", "bot_as_chat"),
                 ("GITHUB_SHA", "invalid", "invalid_context")]
        for key, value, code in cases:
            with self.subTest(code=code), patch.dict(self.env, {key: value}):
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    self.assertEqual(sender.main(self.env, self.path, self.transport), 1)
                self.assertIn(code, output.getvalue())
        self.transport.assert_not_called()

    def test_group_chat_and_trimmed_credentials(self):
        self.env["TELEGRAM_CHAT_ID"] = " -1001234567890\n"
        self.env["TELEGRAM_BOT_TOKEN"] += "\n"
        self.assertEqual(self.invoke()[0], 0)
        self.assertEqual(self.transport.call_args.args[0], self.env["TELEGRAM_BOT_TOKEN"].strip())

    def test_missing_or_empty_file_never_sends(self):
        self.path.unlink()
        self.assertIn("missing_ipa", self.invoke()[1])
        self.path.touch()
        self.assertIn("missing_ipa", self.invoke()[1])
        self.transport.assert_not_called()

    def test_oversized_file_never_sends(self):
        with patch.object(sender, "MAX_FILE_BYTES", 1):
            self.assertIn("ipa_too_large", self.invoke()[1])
        self.transport.assert_not_called()

    def test_error_codes_are_safe_and_not_retried(self):
        for status, code in [(400, "chat_not_found"), (401, "unauthorized"),
                             (403, "forbidden"), (429, "rate_limited"),
                             (500, "unconfirmed")]:
            with self.subTest(status=status):
                self.transport.reset_mock()
                self.transport.return_value = (status, json.dumps({
                    "ok": False, "error_code": status,
                    "description": "chat not found " + self.env["TELEGRAM_BOT_TOKEN"]
                }).encode())
                result, output = self.invoke()
                self.assertEqual(result, 1)
                self.assertIn(code, output)
                self.transport.assert_called_once()

    def test_ok_without_document_confirmation_is_not_success(self):
        for payload in [{"ok": True}, {"ok": True, "result": {"message_id": 1}},
                        {"ok": False}, [], {"ok": True, "result": {
                            "message_id": True, "document": {"file_id": "file"}}}]:
            with self.subTest(payload=payload):
                self.transport.return_value = (200, json.dumps(payload).encode())
                self.assertEqual(self.invoke()[0], 1)

    def test_malformed_response_is_unconfirmed(self):
        self.transport.return_value = (200, b"not JSON")
        self.assertIn("unconfirmed", self.invoke()[1])

    def test_network_error_never_leaks_token_or_resends(self):
        self.transport.side_effect = TimeoutError(self.env["TELEGRAM_BOT_TOKEN"])
        self.assertIn("unconfirmed", self.invoke()[1])
        self.transport.assert_called_once()

    def test_status_files_contain_only_safe_summary(self):
        env_path = Path(self.directory.name) / "env"
        summary_path = Path(self.directory.name) / "summary"
        self.env.update(GITHUB_ENV=str(env_path), GITHUB_STEP_SUMMARY=str(summary_path))
        self.assertEqual(self.invoke()[0], 0)
        self.assertIn("TELEGRAM_STATUS=success", env_path.read_text())
        for path in (env_path, summary_path):
            self.assertNotIn(self.env["TELEGRAM_BOT_TOKEN"], path.read_text())
            self.assertNotIn(self.env["TELEGRAM_CHAT_ID"], path.read_text())


if __name__ == "__main__":
    unittest.main()
