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
                    "GITHUB_SHA": "a" * 40, "GITHUB_RUN_ID": "42",
                    "GITHUB_REF_NAME": "feature/modern-my-wave-home"}
        self.message_transport = Mock(return_value=(200, json.dumps({
            "ok": True, "result": {"message_id": 8, "text": "build notification"}
        }).encode()))
        self.transport = Mock(return_value=(200, json.dumps({
            "ok": True, "result": {"message_id": 7, "document": {"file_id": "file"}}
        }).encode()))

    def invoke(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = sender.main(self.env, self.path, self.transport, self.message_transport)
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

    def test_success_signed_caption_has_ota_url(self):
        self.env.update(IPA_IS_SIGNED="true", MARKETING_VERSION="1.2.3", BUILD_NUMBER="777", OTA_PUBLISHED="true")
        self.assertEqual(self.invoke()[0], 0)
        body = self.transport.call_args.args[1]
        content_type = self.transport.call_args.args[2]
        message = BytesParser(policy=policy.default).parsebytes(
            f"Content-Type: {content_type}\r\nMIME-Version: 1.0\r\n\r\n".encode() + body)
        parts = {p.get_param("name", header="content-disposition"): p
                 for p in message.iter_parts()}
        caption = parts["caption"].get_payload(decode=True).decode()
        self.assertIn("Подписанная IPA", caption)
        self.assertIn("https://owner.github.io/repo/", caption)
        self.assertIn("1.2.3", caption)
        self.assertIn("#777", caption)

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
                    self.assertEqual(sender.main(self.env, self.path, self.transport, self.message_transport), 1)
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

    def test_oversized_file_sends_link_without_reading_or_uploading_ipa(self):
        with patch.object(sender, "MAX_FILE_BYTES", 1), patch.object(Path, "read_bytes", side_effect=AssertionError("large IPA read")):
            status, output = self.invoke()
        self.assertEqual(status, 0)
        self.assertIn("success_link", output)
        self.transport.assert_not_called()
        self.message_transport.assert_called_once()
        token, body, content_type = self.message_transport.call_args.args
        payload=json.loads(body)
        self.assertEqual(payload["chat_id"], "987654")
        self.assertIn("https://github.com/owner/repo/actions/runs/42", payload["text"])
        self.assertIn("Коммит: aaaaaaa", payload["text"])
        self.assertIn("feature/modern-my-wave-home", payload["text"])
        self.assertNotIn("MAIN", payload["text"])
        self.assertNotIn("https://owner.github.io/repo/", payload["text"])
        self.assertNotIn(token.encode(), body)

    def test_signed_large_build_has_ota_only_when_published(self):
        self.env.update(IPA_IS_SIGNED="true", OTA_PUBLISHED="true", MARKETING_VERSION="1.2.3")
        with patch.object(sender, "MAX_FILE_BYTES", 1):
            self.assertEqual(self.invoke()[0],0)
        text=json.loads(self.message_transport.call_args.args[1])["text"]
        self.assertIn("https://owner.github.io/repo/",text)
        self.assertIn("1.2.3",text)
        self.env["OTA_PUBLISHED"]="false"
        with patch.object(sender, "MAX_FILE_BYTES", 1):
            self.assertEqual(self.invoke()[0],0)
        self.assertNotIn("https://owner.github.io/repo/",json.loads(self.message_transport.call_args.args[1])["text"])

    def test_limit_boundary_still_uploads_document(self):
        with patch.object(sender, "MAX_FILE_BYTES", self.path.stat().st_size):
            self.assertEqual(self.invoke()[0],0)
        self.transport.assert_called_once()
        self.message_transport.assert_not_called()

    def test_message_failure_and_timeout_never_retry_or_upload(self):
        cases=[(403, {"ok":False,"error_code":403}, "forbidden"),
               (429, {"ok":False,"error_code":429}, "rate_limited"),
               (200, {"ok":True,"result":{"message_id":8}}, "unconfirmed"),
               (200, {"ok":True,"result":{"message_id":True,"text":"x"}}, "unconfirmed")]
        for status, payload, code in cases:
            self.message_transport.reset_mock()
            self.message_transport.return_value=(status,json.dumps(payload).encode())
            with patch.object(sender, "MAX_FILE_BYTES", 1):
                result, output=self.invoke()
            self.assertEqual(result,1); self.assertIn(code,output)
            self.message_transport.assert_called_once(); self.transport.assert_not_called()
        self.message_transport.reset_mock()
        self.message_transport.side_effect=TimeoutError(self.env["TELEGRAM_BOT_TOKEN"])
        with patch.object(sender, "MAX_FILE_BYTES", 1):
            self.assertIn("unconfirmed",self.invoke()[1])
        self.message_transport.assert_called_once(); self.transport.assert_not_called()

    def test_message_transport_uses_send_message_not_document(self):
        with patch.object(sender, "post_request", return_value=(200,b"{}")) as request:
            sender.post_message("TEST_TOKEN",b"{}","application/json")
        self.assertEqual(request.call_args.args[1],"sendMessage")

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
