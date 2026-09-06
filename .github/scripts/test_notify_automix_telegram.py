# Path: .github/scripts/test_notify_automix_telegram.py
import unittest
from unittest.mock import Mock

from notify_automix_telegram import DeliveryError, deliver


class DeliveryTests(unittest.TestCase):
    def setUp(self):
        self.environment = {
            "TELEGRAM_BOT_TOKEN": "123:test_placeholder",
            "TELEGRAM_CHAT_ID": "456",
            "GITHUB_REPOSITORY": "smosiarhei-hue/aura-player",
            "GITHUB_SHA": "a" * 40,
            "GITHUB_RUN_ID": "1234",
        }
        self.request = Mock(return_value={"message_id": 42})

    def test_missing_token_does_not_send(self):
        self.environment.pop("TELEGRAM_BOT_TOKEN")
        with self.assertRaises(DeliveryError):
            deliver(self.environment, self.request)
        self.request.assert_not_called()

    def test_missing_chat_does_not_fall_back(self):
        self.environment.pop("TELEGRAM_CHAT_ID")
        with self.assertRaises(DeliveryError):
            deliver(self.environment, self.request)
        self.request.assert_not_called()

    def test_bot_id_is_rejected(self):
        self.environment["TELEGRAM_CHAT_ID"] = "123"
        with self.assertRaises(DeliveryError):
            deliver(self.environment, self.request)
        self.request.assert_not_called()

    def test_receipt_does_not_include_secret(self):
        self.assertEqual(deliver(self.environment, self.request), 42)
        token, method, payload = self.request.call_args.args
        self.assertEqual(method, "sendMessage")
        self.assertEqual(payload["chat_id"], "456")
        self.assertNotIn(token, payload["text"])
        self.assertIn("не готовая IPA", payload["text"])
        self.request.assert_called_once()

    def test_group_chat_and_whitespace(self):
        self.environment["TELEGRAM_CHAT_ID"] = " -100456 "
        self.environment["TELEGRAM_BOT_TOKEN"] = " 123:test_placeholder\n"
        deliver(self.environment, self.request)
        token, _, payload = self.request.call_args.args
        self.assertEqual(token, "123:test_placeholder")
        self.assertEqual(payload["chat_id"], "-100456")

    def test_unconfirmed_result_is_failure(self):
        self.request.return_value = {}
        with self.assertRaises(DeliveryError):
            deliver(self.environment, self.request)


if __name__ == "__main__":
    unittest.main()
