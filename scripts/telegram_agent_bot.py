# -*- coding: utf-8 -*-
"""
Sonivo Autonomous Telegram AI Developer Agent
==============================================
Полноценный автономный AI-разработчик для управления проектом Sonivo прямо из Telegram.
"""

import os
import sys

if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

import json
import time
import urllib.request
import urllib.parse
import urllib.error
import subprocess
from pathlib import Path

# --- КОНФИГУРАЦИЯ ---
CONFIG_FILE = Path(__file__).resolve().parent.parent / "agent_config.json"
_cfg = {}
if CONFIG_FILE.exists():
    try:
        _cfg = json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
    except Exception:
        pass

BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN") or _cfg.get("TELEGRAM_BOT_TOKEN", "")
ALLOWED_CHAT_ID = int(os.environ.get("TELEGRAM_CHAT_ID") or _cfg.get("TELEGRAM_CHAT_ID", 0))
GEMINI_API_KEY = os.environ.get("GEMINI_API_KEY") or _cfg.get("GEMINI_API_KEY", "")
MODEL_NAME = os.environ.get("GEMINI_MODEL") or _cfg.get("GEMINI_MODEL", "gemini-2.5-pro")

REPO_DIR = Path(__file__).resolve().parent.parent

SYSTEM_PROMPT = """Ты — Sonivo AI Agent, автономный Senior iOS Swift разработчик и DevOps инженер проекта Sonivo (музыкальный плеер для iOS на SwiftUI).
Твоя цель — выполнять любые задачи пользователя прямо из Telegram:
- Анализировать структуру проекта, искать нужные файлы и код.
- Исправлять ошибки компиляции, баги, краши и логи.
- Модифицировать интерфейс (SwiftUI, Apple Music стиль, анимации, Liquid Glass, плеер, экраны, жесты).
- Делать git commit и push в GitHub.
- Проверять статус сборки в GitHub Actions и читать логи при сбоях.

ВСЕГДА отвечай пользователю на русском языке вежливо, четко и структурированно.
Перед изменением файла ВСЕГДА читай его содержимое (read_file или search_code).
После успешного внесения правок сделай git_commit_and_push с понятным описанием изменений.
"""

# --- ИНСТРУМЕНТЫ (TOOLS) ДЛЯ GEMINI ---
TOOL_DECLARATIONS = [
    {
        "name": "list_directory",
        "description": "Список файлов и папок в директории репозитория.",
        "parameters": {
            "type": "OBJECT",
            "properties": {
                "path": {"type": "STRING", "description": "Относительный путь к папке (например: 'Aurora' или '')"}
            }
        }
    },
    {
        "name": "read_file",
        "description": "Прочитать содержимое файла с номерами строк.",
        "parameters": {
            "type": "OBJECT",
            "properties": {
                "file_path": {"type": "STRING", "description": "Относительный путь к файлу (например: 'Aurora/PlayerScreenV2.swift')"},
                "start_line": {"type": "INTEGER", "description": "Начальная строка (1-based, опционально)"},
                "end_line": {"type": "INTEGER", "description": "Конечная строка (опционально)"}
            },
            "required": ["file_path"]
        }
    },
    {
        "name": "search_code",
        "description": "Поиск текста во всех файлах проекта.",
        "parameters": {
            "type": "OBJECT",
            "properties": {
                "query": {"type": "STRING", "description": "Текст для поиска"}
            },
            "required": ["query"]
        }
    },
    {
        "name": "edit_file",
        "description": "Заменить точный фрагмент текста в файле на новый код.",
        "parameters": {
            "type": "OBJECT",
            "properties": {
                "file_path": {"type": "STRING", "description": "Относительный путь к файлу"},
                "target_content": {"type": "STRING", "description": "Точный исходный текст, который нужно заменить"},
                "replacement_content": {"type": "STRING", "description": "Новый текст для вставки"}
            },
            "required": ["file_path", "target_content", "replacement_content"]
        }
    },
    {
        "name": "create_or_overwrite_file",
        "description": "Создать новый файл или полностью перезаписать существующий.",
        "parameters": {
            "type": "OBJECT",
            "properties": {
                "file_path": {"type": "STRING", "description": "Относительный путь к файлу"},
                "content": {"type": "STRING", "description": "Полное содержимое файла"}
            },
            "required": ["file_path", "content"]
        }
    },
    {
        "name": "git_status",
        "description": "Получить статус измененных файлов git.",
        "parameters": {"type": "OBJECT", "properties": {}}
    },
    {
        "name": "git_commit_and_push",
        "description": "Добавить все изменения (git add .), закоммитить и отправить в origin main.",
        "parameters": {
            "type": "OBJECT",
            "properties": {
                "commit_message": {"type": "STRING", "description": "Сообщение коммита (с префиксом feat:, fix:, refactor:)"}
            },
            "required": ["commit_message"]
        }
    },
    {
        "name": "check_ci_build",
        "description": "Проверить статус последних сборок GitHub Actions (CI/CD).",
        "parameters": {"type": "OBJECT", "properties": {}}
    },
    {
        "name": "get_failed_build_logs",
        "description": "Получить лог ошибки последней упавшей сборки GitHub Actions для диагностики.",
        "parameters": {"type": "OBJECT", "properties": {}}
    },
    {
        "name": "run_shell_command",
        "description": "Выполнить консольную команду в папке проекта.",
        "parameters": {
            "type": "OBJECT",
            "properties": {
                "command": {"type": "STRING", "description": "Команда shell"}
            },
            "required": ["command"]
        }
    }
]

# --- РЕАЛИЗАЦИЯ ИНСТРУМЕНТОВ ---

def tool_list_directory(path=""):
    target = (REPO_DIR / path).resolve()
    if not str(target).startswith(str(REPO_DIR)):
        return {"error": "Access denied outside repo"}
    if not target.exists():
        return {"error": f"Directory not found: {path}"}
    
    items = []
    for p in target.iterdir():
        if p.name.startswith(".") and p.name not in [".github"]:
            continue
        items.append({
            "name": p.name,
            "type": "directory" if p.is_dir() else "file",
            "size": p.stat().st_size if p.is_file() else None
        })
    return {"items": items, "path": path or "."}

def tool_read_file(file_path, start_line=1, end_line=None):
    target = (REPO_DIR / file_path).resolve()
    if not str(target).startswith(str(REPO_DIR)):
        return {"error": "Access denied outside repo"}
    if not target.exists():
        return {"error": f"File not found: {file_path}"}
    
    try:
        lines = target.read_text(encoding="utf-8", errors="replace").splitlines()
        total = len(lines)
        s = max(1, start_line)
        e = min(total, end_line) if end_line else min(total, s + 350)
        
        numbered = [f"{i+1}: {lines[i]}" for i in range(s - 1, e)]
        return {
            "file_path": file_path,
            "total_lines": total,
            "showing_range": f"{s}-{e}",
            "content": "\n".join(numbered)
        }
    except Exception as ex:
        return {"error": str(ex)}

def tool_search_code(query):
    results = []
    for root, dirs, files in os.walk(REPO_DIR):
        dirs[:] = [d for d in dirs if not d.startswith(".") or d == ".github"]
        for f in files:
            if f.endswith((".swift", ".py", ".yml", ".yaml", ".plist", ".md", ".json")):
                fpath = Path(root) / f
                rel = fpath.relative_to(REPO_DIR)
                try:
                    lines = fpath.read_text(encoding="utf-8", errors="ignore").splitlines()
                    for idx, line in enumerate(lines):
                        if query.lower() in line.lower():
                            results.append(f"{rel}:{idx+1}: {line.strip()[:140]}")
                            if len(results) >= 40:
                                break
                except Exception:
                    pass
        if len(results) >= 40:
            break
    return {"matches": results, "count": len(results)}

def tool_edit_file(file_path, target_content, replacement_content):
    target = (REPO_DIR / file_path).resolve()
    if not str(target).startswith(str(REPO_DIR)):
        return {"error": "Access denied outside repo"}
    if not target.exists():
        return {"error": f"File not found: {file_path}"}
    
    text = target.read_text(encoding="utf-8")
    if target_content not in text:
        return {"error": "target_content not found in file. Make sure lines match exactly."}
    
    occurrences = text.count(target_content)
    if occurrences > 1:
        return {"error": f"target_content is not unique (found {occurrences} occurrences). Provide more context."}
    
    new_text = text.replace(target_content, replacement_content, 1)
    target.write_text(new_text, encoding="utf-8")
    return {"status": "success", "file_path": file_path, "message": "Replacement applied successfully."}

def tool_create_or_overwrite_file(file_path, content):
    target = (REPO_DIR / file_path).resolve()
    if not str(target).startswith(str(REPO_DIR)):
        return {"error": "Access denied outside repo"}
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content, encoding="utf-8")
    return {"status": "success", "file_path": file_path, "bytes_written": len(content)}

def tool_git_status():
    res = subprocess.run(["git", "status", "-s"], cwd=REPO_DIR, capture_output=True, text=True)
    return {"status_output": res.stdout.strip() or "Working tree clean"}

def tool_git_commit_and_push(commit_message):
    add_res = subprocess.run(["git", "add", "."], cwd=REPO_DIR, capture_output=True, text=True)
    commit_res = subprocess.run(["git", "commit", "-m", commit_message], cwd=REPO_DIR, capture_output=True, text=True)
    push_res = subprocess.run(["git", "push", "origin", "main"], cwd=REPO_DIR, capture_output=True, text=True)
    return {
        "add": add_res.returncode == 0,
        "commit": commit_res.stdout.strip() or commit_res.stderr.strip(),
        "push": push_res.stdout.strip() or push_res.stderr.strip(),
        "success": push_res.returncode == 0
    }

def tool_check_ci_build():
    res = subprocess.run(["gh", "run", "list", "-L", "3"], cwd=REPO_DIR, capture_output=True, text=True)
    if res.returncode != 0:
        return {"output": "GitHub CLI error or not logged in", "raw": res.stderr}
    return {"recent_runs": res.stdout.strip()}

def tool_get_failed_build_logs():
    res = subprocess.run(["gh", "run", "view", "--log-failed"], cwd=REPO_DIR, capture_output=True, text=True)
    out = res.stdout.strip() or res.stderr.strip()
    return {"failed_logs": out[-4000:] if len(out) > 4000 else out}

def tool_run_shell_command(command):
    res = subprocess.run(command, cwd=REPO_DIR, capture_output=True, text=True, shell=True)
    return {
        "returncode": res.returncode,
        "stdout": res.stdout.strip()[:2000],
        "stderr": res.stderr.strip()[:2000]
    }

TOOL_MAP = {
    "list_directory": tool_list_directory,
    "read_file": tool_read_file,
    "search_code": tool_search_code,
    "edit_file": tool_edit_file,
    "create_or_overwrite_file": tool_create_or_overwrite_file,
    "git_status": tool_git_status,
    "git_commit_and_push": tool_git_commit_and_push,
    "check_ci_build": tool_check_ci_build,
    "get_failed_build_logs": tool_get_failed_build_logs,
    "run_shell_command": tool_run_shell_command
}

# --- TELEGRAM API HELPER ---

def tg_request(method, payload=None):
    url = f"https://api.telegram.org/bot{BOT_TOKEN}/{method}"
    data = json.dumps(payload).encode("utf-8") if payload else None
    headers = {"Content-Type": "application/json"} if payload else {}
    req = urllib.request.Request(url, data=data, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=35) as resp:
            return json.loads(resp.read().decode())
    except Exception as e:
        print(f"[TG Error {method}]: {e}")
        return None

def tg_send(text, chat_id=ALLOWED_CHAT_ID, reply_to=None):
    payload = {"chat_id": chat_id, "text": text, "parse_mode": "Markdown"}
    if reply_to:
        payload["reply_to_message_id"] = reply_to
    res = tg_request("sendMessage", payload)
    if not res or not res.get("ok"):
        payload.pop("parse_mode", None)
        return tg_request("sendMessage", payload)
    return res

def tg_edit(text, chat_id, message_id):
    payload = {"chat_id": chat_id, "message_id": message_id, "text": text, "parse_mode": "Markdown"}
    res = tg_request("editMessageText", payload)
    if not res or not res.get("ok"):
        payload.pop("parse_mode", None)
        return tg_request("editMessageText", payload)
    return res

# --- GEMINI AGENT CORE ---

def call_gemini(contents):
    for model in [MODEL_NAME, "gemini-2.5-pro", "gemini-2.5-flash", "gemini-1.5-pro"]:
        url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={GEMINI_API_KEY}"
        payload = {
            "contents": contents,
            "systemInstruction": {"parts": [{"text": SYSTEM_PROMPT}]},
            "tools": [{"functionDeclarations": TOOL_DECLARATIONS}],
            "generationConfig": {
                "temperature": 0.2
            }
        }
        
        req = urllib.request.Request(
            url,
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"}
        )
        try:
            with urllib.request.urlopen(req, timeout=90) as resp:
                data = json.loads(resp.read().decode())
                return data
        except urllib.error.HTTPError as e:
            err_body = e.read().decode()
            print(f"[Gemini HTTP {e.code} on {model}]: {err_body}")
            if e.code in [404, 400]:
                continue
            return {"error": f"HTTP {e.code}: {err_body}"}
        except Exception as e:
            print(f"[Gemini Error on {model}]: {e}")
            return {"error": str(e)}
            
    return {"error": "All Gemini models failed to respond."}

def execute_agent_loop(user_prompt, status_msg_id, chat_id):
    history = [
        {"role": "user", "parts": [{"text": user_prompt}]}
    ]
    
    max_steps = 15
    for step in range(max_steps):
        if status_msg_id:
            tg_edit(f"🤖 *Sonivo AI Agent* (Шаг {step+1}/{max_steps}):\nДумаю над решением...", chat_id, status_msg_id)
        
        response = call_gemini(history)
        if "error" in response:
            return f"❌ Ошибка Gemini API: {response['error']}"
        
        candidates = response.get("candidates", [])
        if not candidates:
            return "❌ Gemini вернул пустой ответ."
        
        candidate = candidates[0]
        content = candidate.get("content", {})
        parts = content.get("parts", [])
        
        history.append(content)
        
        function_calls = [p["functionCall"] for p in parts if "functionCall" in p]
        
        if not function_calls:
            text_parts = [p.get("text", "") for p in parts if "text" in p]
            return "\n".join(text_parts)
        
        response_parts = []
        for fc in function_calls:
            name = fc.get("name")
            args = fc.get("args", {})
            
            action_desc = f"⚙️ Выполняю `{name}`..."
            if name == "read_file":
                action_desc = f"📖 Читаю `{args.get('file_path')}`..."
            elif name == "edit_file":
                action_desc = f"✏️ Редактирую `{args.get('file_path')}`..."
            elif name == "git_commit_and_push":
                action_desc = f"🚀 Отправляю коммит в GitHub: *{args.get('commit_message')}*..."
            elif name == "check_ci_build":
                action_desc = "🔍 Проверяю статус сборки IPA в GitHub Actions..."
                
            if status_msg_id:
                tg_edit(f"🤖 *Sonivo AI Agent* (Шаг {step+1}):\n{action_desc}", chat_id, status_msg_id)
            
            tool_func = TOOL_MAP.get(name)
            if tool_func:
                try:
                    result = tool_func(**args)
                except Exception as ex:
                    result = {"error": str(ex)}
            else:
                result = {"error": f"Unknown tool: {name}"}
                
            response_parts.append({
                "functionResponse": {
                    "name": name,
                    "response": result
                }
            })
            
        history.append({
            "role": "function",
            "parts": response_parts
        })
        
    return "⚠️ Достигнут лимит шагов (15). Завершаю сессию."

# --- ОСНОВНОЙ ЦИКЛ ОПРОСА TELEGRAM ---

def start_bot():
    print("="*60)
    print("🤖 Sonivo Autonomous Telegram AI Developer Agent")
    print(f"📌 Авторизованный Chat ID: {ALLOWED_CHAT_ID}")
    print(f"📁 Репозиторий: {REPO_DIR}")
    print("="*60)
    
    tg_send(
        "🚀 *Sonivo AI Agent активирован и готов к работе!*\n\n"
        "Вы можете писать мне любые задачи на русском языке:\n"
        "• «_Сделай фон плеера более ярким_»\n"
        "• «_Почини краш в PlayerCore, вот лог..._»\n"
        "• «_Добавь новую кнопку в меню_»\n"
        "• «_Проверь статус сборки IPA_»\n\n"
        "Я сам найду код, внесу изменения, сделаю коммит, запущу сборку и пришлю вам IPA! 🎧"
    )
    
    last_update_id = 0
    while True:
        try:
            updates = tg_request("getUpdates", {"offset": last_update_id + 1, "timeout": 25})
            if not updates or not updates.get("ok"):
                time.sleep(2)
                continue
                
            for u in updates.get("result", []):
                last_update_id = u["update_id"]
                msg = u.get("message")
                if not msg:
                    continue
                    
                sender_id = msg.get("from", {}).get("id")
                if sender_id != ALLOWED_CHAT_ID:
                    print(f"[Security] Ignored message from unauthorized user: {sender_id}")
                    continue
                    
                text = msg.get("text", "").strip()
                if not text:
                    if "caption" in msg:
                        text = msg["caption"].strip()
                    else:
                        continue
                        
                msg_id = msg["message_id"]
                print(f"\n[User Request]: {text}")
                
                if text == "/start":
                    tg_send(
                        "👋 Привет! Я твой личный AI-разработчик Sonivo.\n\n"
                        "Отправь мне задачу, ошибку, лог или пожелание — я всё сделаю сам!",
                        reply_to=msg_id
                    )
                    continue
                elif text == "/status":
                    status = tool_git_status()
                    ci = tool_check_ci_build()
                    tg_send(
                        f"📊 *Статус Git*:\n```\n{status.get('status_output')}\n```\n\n"
                        f"⚙️ *Сборки GitHub Actions*:\n```\n{ci.get('recent_runs')}\n```",
                        reply_to=msg_id
                    )
                    continue
                elif text == "/logs":
                    logs = tool_get_failed_build_logs()
                    tg_send(f"📋 *Логи последней ошибки*:\n```\n{logs.get('failed_logs')}\n```", reply_to=msg_id)
                    continue
                    
                status_res = tg_send("⏳ *Принял задачу!* Начинаю работу...", reply_to=msg_id)
                status_msg_id = status_res.get("result", {}).get("message_id") if status_res else None
                
                final_answer = execute_agent_loop(text, status_msg_id, ALLOWED_CHAT_ID)
                tg_send(f"✅ *Готово!*\n\n{final_answer}", reply_to=msg_id)
                
        except KeyboardInterrupt:
            print("\n[!] Bot stopped by user.")
            break
        except Exception as e:
            print(f"[Loop Error]: {e}")
            time.sleep(3)

if __name__ == "__main__":
    start_bot()
