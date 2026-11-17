#!/usr/bin/env python3
"""Lightweight HTTP Receiver for AutoMixSessionLog reports.

Accepts POST /upload and /api/log with log text, saves to logs/ directory,
and runs analyze_automix_session_log.py automatically.
Zero external dependencies (pure Python standard library).
"""

import http.server
import json
import os
import socket
import subprocess
import sys
from datetime import datetime
from pathlib import Path

PORT = 8080
LOG_DIR = Path(__file__).resolve().parent / "received_logs"
LOG_DIR.mkdir(parents=True, exist_ok=True)
ANALYZER_SCRIPT = Path(__file__).resolve().parent / "analyze_automix_session_log.py"


def get_local_ip() -> str:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except Exception:
        return "127.0.0.1"
    finally:
        s.close()


HTML_PAGE = """<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>AutoMix Log Receiver</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            background: #000;
            color: #fff;
            margin: 0;
            padding: 20px;
            display: flex;
            flex-direction: column;
            align-items: center;
        }
        .container { max-width: 600px; width: 100%; }
        h2 { font-size: 20px; margin-bottom: 8px; font-weight: 600; text-align: center; }
        p { color: #888; font-size: 14px; margin-bottom: 16px; text-align: center; }
        textarea {
            width: 100%; height: 260px; background: #1c1c1e; color: #fff;
            border: 1px solid #333; border-radius: 12px; padding: 12px; font-size: 14px;
            box-sizing: border-box; resize: vertical; outline: none; font-family: monospace;
        }
        .btn-group { display: flex; gap: 10px; margin-top: 14px; }
        button {
            flex: 1; padding: 14px; border-radius: 12px; border: none;
            font-size: 16px; font-weight: 600; cursor: pointer;
        }
        .btn-paste { background: #2c2c2e; color: #fff; }
        .btn-submit { background: #007aff; color: #fff; }
        #status { margin-top: 16px; padding: 12px; border-radius: 10px; display: none; text-align: center; font-size: 14px; }
        .status-success { background: #1c3829; color: #34c759; display: block !important; }
    </style>
</head>
<body>
    <div class="container">
        <h2>Логи AutoMix</h2>
        <p>Вставьте скопированный отчёт из плеера или отправьте прямо из настроек</p>
        <textarea id="logText" placeholder="Вставьте сюда лог AutoMix..."></textarea>
        <div class="btn-group">
            <button class="btn-paste" onclick="pasteClipboard()">Вставить</button>
            <button class="btn-submit" onclick="sendLogs()">Отправить агенту</button>
        </div>
        <div id="status"></div>
    </div>
    <script>
        async function pasteClipboard() {
            try {
                const text = await navigator.clipboard.readText();
                document.getElementById('logText').value = text;
            } catch (err) {
                alert('Вставьте текст вручную в поле.');
            }
        }
        async function sendLogs() {
            const text = document.getElementById('logText').value.trim();
            if (!text) { alert('Поле логов пустое.'); return; }
            const status = document.getElementById('status');
            status.className = ''; status.style.display = 'block';
            status.style.background = '#222'; status.style.color = '#fff';
            status.innerText = 'Отправка...';
            try {
                const resp = await fetch('/upload', {
                    method: 'POST',
                    headers: {'Content-Type': 'text/plain; charset=utf-8'},
                    body: text
                });
                if (resp.ok) {
                    status.className = 'status-success';
                    status.innerText = '✓ Логи успешно переданы и проанализированы!';
                    document.getElementById('logText').value = '';
                } else {
                    status.innerText = 'Ошибка отправки: ' + resp.statusText;
                }
            } catch (e) {
                status.innerText = 'Ошибка соединения: ' + e;
            }
        }
    </script>
</body>
</html>
"""

class LogReceiverHandler(http.server.BaseHTTPRequestHandler):
    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(HTML_PAGE.encode("utf-8"))

    def do_POST(self):
        if self.path not in ("/upload", "/api/log", "/"):
            self.send_response(404)
            self.end_headers()
            return

        content_length = int(self.headers.get("Content-Length", 0))
        post_data = self.rfile.read(content_length).decode("utf-8", errors="replace")

        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        log_file = LOG_DIR / f"automix_{timestamp}.log"
        log_file.write_text(post_data, encoding="utf-8")

        print(f"\n[+] Received log ({len(post_data)} bytes) -> {log_file.name}", flush=True)

        analysis_json = "{}"
        if ANALYZER_SCRIPT.exists():
            try:
                res = subprocess.run(
                    [sys.executable, str(ANALYZER_SCRIPT), str(log_file)],
                    capture_output=True,
                    text=True,
                    check=False,
                )
                print("--- AutoMix Triage Result ---", flush=True)
                print(res.stdout, flush=True)
                analysis_json = res.stdout.strip()
            except Exception as e:
                print(f"[!] Analysis failed: {e}", flush=True)

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        response = {
            "status": "ok",
            "saved_as": log_file.name,
            "bytes": len(post_data),
            "analysis": analysis_json,
        }
        self.wfile.write(json.dumps(response).encode("utf-8"))

    def log_message(self, format, *args):
        pass


def main():
    ip = get_local_ip()
    server = http.server.ThreadingHTTPServer(("0.0.0.0", PORT), LogReceiverHandler)
    print("=" * 60)
    print(" AutoMix Session Log Receiver started!")
    print(f" Local URL for iPhone: http://{ip}:{PORT}/")
    print("=" * 60)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping server...")
        server.server_close()


if __name__ == "__main__":
    main()
