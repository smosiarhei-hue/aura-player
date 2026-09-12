# Path: .github/scripts/send_ipa_telegram.py
"""Deliver an unsigned IPA without logging credentials or Telegram response bodies."""

import http.client
import json
import os
from pathlib import Path
import re
import secrets
import sys

MAX_FILE_BYTES = 50_000_000


class DeliveryError(Exception):
    """Only fixed, non-sensitive diagnostic codes may leave the sender."""


MESSAGES = {
    "missing_token": "Configure TELEGRAM_BOT_TOKEN in GitHub Actions secrets.",
    "invalid_token": "TELEGRAM_BOT_TOKEN has an invalid format.",
    "missing_chat": "Configure TELEGRAM_CHAT_ID in GitHub Actions secrets; no fallback is used.",
    "invalid_chat": "TELEGRAM_CHAT_ID must be a nonzero numeric chat ID.",
    "bot_as_chat": "TELEGRAM_CHAT_ID is the bot ID, not the destination chat ID.",
    "invalid_context": "Missing or invalid GitHub build context.",
    "missing_ipa": "The IPA file is missing or empty.",
    "ipa_too_large": "IPA exceeds the 50 MB upload limit; download the GitHub Actions artifact.",
    "unauthorized": "Telegram rejected authentication. Check or rotate the GitHub bot token.",
    "forbidden": "Telegram denied delivery. Check whether the bot is blocked or lacks chat access.",
    "chat_not_found": "Telegram could not find the chat. Check its ID and start the bot first.",
    "bad_request": "Telegram rejected the request. Check the configured destination chat.",
    "rate_limited": "Telegram rate limited delivery; no automatic resend was attempted.",
    "telegram_error": "Telegram returned an error; the response body was not logged.",
    "unconfirmed": "Delivery is unconfirmed. Check Telegram before retrying to avoid duplicates.",
    "internal_error": "Delivery failed locally; exception details were suppressed to protect secrets.",
    "success": "Telegram confirmed the IPA document message. Installation requires signing.",
}


def configuration(env):
    token = env.get("TELEGRAM_BOT_TOKEN", "").strip()
    chat = env.get("TELEGRAM_CHAT_ID", "").strip()
    if not token:
        raise DeliveryError("missing_token")
    if not re.fullmatch(r"[0-9]+:[A-Za-z0-9_-]+", token):
        raise DeliveryError("invalid_token")
    if not chat:
        raise DeliveryError("missing_chat")
    if not re.fullmatch(r"-?[0-9]+", chat) or int(chat) == 0:
        raise DeliveryError("invalid_chat")
    if int(chat) == int(token.split(":", 1)[0]):
        raise DeliveryError("bot_as_chat")
    repository = env.get("GITHUB_REPOSITORY", "")
    sha = env.get("GITHUB_SHA", "")
    run = env.get("GITHUB_RUN_ID", "")
    if not (re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository)
            and re.fullmatch(r"[0-9a-fA-F]{40}", sha)
            and re.fullmatch(r"[0-9]+", run)):
        raise DeliveryError("invalid_context")
    caption = ("Sonivo — тестовая IPA без подписи.\n"
               "Для установки требуется подпись.\n"
               f"Коммит: {sha[:7]}\n"
               f"Сборка: https://github.com/{repository}/actions/runs/{run}")
    return token, chat, caption


def multipart(chat, caption, data):
    boundary = "Sonivo" + secrets.token_hex(24)
    chunks = []
    for name, value in (("chat_id", chat), ("caption", caption)):
        chunks.append((f"--{boundary}\r\nContent-Disposition: form-data; "
                       f'name="{name}"\r\n\r\n{value}\r\n').encode("utf-8"))
    chunks.extend([
        (f"--{boundary}\r\nContent-Disposition: form-data; name=\"document\"; "
         'filename="Sonivo-unsigned.ipa"\r\nContent-Type: application/octet-stream\r\n\r\n').encode(),
        data,
        f"\r\n--{boundary}--\r\n".encode(),
    ])
    return b"".join(chunks), f"multipart/form-data; boundary={boundary}"


def post_document(token, body, content_type):
    # Use a fixed host, TLS, no redirects, no automatic retries and no request logging.
    connection = http.client.HTTPSConnection("api.telegram.org", timeout=180)
    try:
        connection.request("POST", f"/bot{token}/sendDocument", body=body,
                           headers={"Content-Type": content_type})
        response = connection.getresponse()
        return response.status, response.read(1_000_001)
    finally:
        connection.close()


def confirm_response(status, raw):
    try:
        payload = json.loads(raw)
    except (ValueError, UnicodeError):
        payload = {}
    if not isinstance(payload, dict):
        payload = {}
    code = payload.get("error_code", status)
    description = str(payload.get("description", "")).lower()
    if status != 200 or payload.get("ok") is not True:
        if code in (401, 404):
            raise DeliveryError("unauthorized")
        if code == 403:
            raise DeliveryError("forbidden")
        if code == 429:
            raise DeliveryError("rate_limited")
        if code == 400:
            raise DeliveryError("chat_not_found" if "chat not found" in description else "bad_request")
        raise DeliveryError("unconfirmed" if status >= 500 or status == 200 else "telegram_error")
    result = payload.get("result")
    if not isinstance(result, dict):
        raise DeliveryError("unconfirmed")
    message_id = result.get("message_id")
    document = result.get("document")
    if (type(message_id) is not int or message_id <= 0
            or not isinstance(document, dict)
            or not isinstance(document.get("file_id"), str)
            or not document["file_id"]):
        raise DeliveryError("unconfirmed")


def deliver(env, path, transport=post_document):
    token, chat, caption = configuration(env)
    if not path.is_file() or path.stat().st_size == 0:
        raise DeliveryError("missing_ipa")
    if path.stat().st_size > MAX_FILE_BYTES:
        raise DeliveryError("ipa_too_large")
    body, content_type = multipart(chat, caption, path.read_bytes())
    try:
        status, raw = transport(token, body, content_type)
    except Exception:
        # A timeout after upload does not prove that Telegram did not receive it.
        raise DeliveryError("unconfirmed") from None
    confirm_response(status, raw)


def record_status(code, env):
    message = MESSAGES[code]
    print(f"Telegram delivery: {code}. {message}")
    if env.get("GITHUB_ENV"):
        with open(env["GITHUB_ENV"], "a", encoding="utf-8") as output:
            output.write(f"TELEGRAM_STATUS={code}\nTELEGRAM_RESPONSE={message}\n")
    if env.get("GITHUB_STEP_SUMMARY"):
        with open(env["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as output:
            output.write(f"## Telegram IPA delivery\n\n**{code}** — {message}\n")


def main(env=None, path=None, transport=post_document):
    env = os.environ if env is None else env
    path = Path("Sonivo-unsigned.ipa") if path is None else path
    try:
        deliver(env, path, transport)
        code = "success"
    except DeliveryError as error:
        code = error.args[0] if error.args[0] in MESSAGES else "internal_error"
    except Exception:
        code = "internal_error"
    try:
        record_status(code, env)
    except OSError:
        print("Unable to persist safe delivery status.")
        return 1
    return 0 if code == "success" else 1


if __name__ == "__main__":
    sys.exit(main())
