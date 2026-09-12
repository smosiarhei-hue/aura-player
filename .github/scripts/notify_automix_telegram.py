# Path: .github/scripts/notify_automix_telegram.py
"""Send a commit receipt, never a claim that CI or device testing passed."""

import json
import os
import re
import sys
import urllib.error
import urllib.request


class DeliveryError(Exception):
    """A safe error that never contains a token or an authenticated URL."""


def telegram_request(token, method, payload):
    url = "https://api.telegram.org/" + "bot" + token + "/" + method
    request = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            result = json.load(response)
    except urllib.error.HTTPError as error:
        raise DeliveryError("Telegram HTTP " + str(error.code)) from None
    except (urllib.error.URLError, TimeoutError, ValueError, OSError):
        raise DeliveryError("Telegram network error or invalid response") from None
    if not isinstance(result, dict) or result.get("ok") is not True:
        raise DeliveryError("Telegram did not confirm delivery")
    return result.get("result")


def deliver(environment, request=telegram_request):
    token = environment.get("TELEGRAM_BOT_TOKEN", "").strip()
    chat_id = environment.get("TELEGRAM_CHAT_ID", "").strip()
    if not re.fullmatch(r"[0-9]+:[A-Za-z0-9_-]+", token):
        raise DeliveryError("Configure TELEGRAM_BOT_TOKEN in GitHub Actions secrets")
    if not re.fullmatch(r"-?[0-9]+", chat_id) or int(chat_id) == 0:
        raise DeliveryError("Configure TELEGRAM_CHAT_ID in GitHub Actions secrets")
    if int(chat_id) == int(token.split(":", 1)[0]):
        raise DeliveryError("TELEGRAM_CHAT_ID must identify your chat, not the bot")

    repository = environment.get("GITHUB_REPOSITORY", "")
    sha = environment.get("GITHUB_SHA", "")
    run_id = environment.get("GITHUB_RUN_ID", "")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise DeliveryError("Invalid repository context")
    if not re.fullmatch(r"[0-9a-f]{40}", sha) or not run_id.isdigit():
        raise DeliveryError("Invalid commit or run context")

    base = "https://github.com/" + repository
    text = (
        "AutoMix V2 — сохранён новый коммит\n"
        "Ветка: feature/automix-engine-v2\n"
        "Коммит: " + sha[:7] + "\n"
        + base + "/commit/" + sha + "\n\n"
        "Это уведомление о коде, не готовая IPA и не приёмка этапа.\n"
        "Результаты сборки и тестов: " + base + "/pull/6/checks\n"
        "Отправка: " + base + "/actions/runs/" + run_id
    )
    result = request(token, "sendMessage", {"chat_id": chat_id, "text": text})
    if not isinstance(result, dict) or not isinstance(result.get("message_id"), int):
        raise DeliveryError("Telegram response has no message confirmation")
    return result["message_id"]


def main():
    try:
        message_id = deliver(os.environ)
    except DeliveryError as error:
        print("Telegram delivery failed: " + str(error), file=sys.stderr)
        return 1
    print("Telegram delivery confirmed; message " + str(message_id))
    return 0


if __name__ == "__main__":
    sys.exit(main())
