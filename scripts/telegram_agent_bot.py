# -*- coding: utf-8 -*-
"""
Sonivo Autonomous Telegram AI Developer Agent v2.0
===================================================
Полноценный автономный AI-разработчик и DevOps для проекта Sonivo в Telegram:
- Интерактивная клавиатура и inline-кнопки
- Пул аккаунтов Gemini API с автопереключением при исчерпании квот (Free Tier Failover)
- Мониторинг квот и оставшихся запросов в реальном времени
- Загрузка пользовательских Скиллов и Агентов (файлами или текстом)
- Автоматический сборщик IPA и самовосстановление при ошибках
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

# --- КОНФИГУРАЦИЯ И ПУТИ ---
REPO_DIR = Path(__file__).resolve().parent.parent
CONFIG_FILE = REPO_DIR / "agent_config.json"
SKILLS_DIR = REPO_DIR / "agent_skills"
SKILLS_DIR.mkdir(exist_ok=True)

user_states = {}

def load_config():
    default_cfg = {
        "TELEGRAM_BOT_TOKEN": os.environ.get("TELEGRAM_BOT_TOKEN", "8325367009:AAEk_r7mmJgRlYcdXVPsKYBKlApjzx1B0fA"),
        "TELEGRAM_CHAT_ID": int(os.environ.get("TELEGRAM_CHAT_ID", 8559869613)),
        "ACTIVE_MODEL": "gemini-3.6-flash",
        "GEMINI_KEYS": []
    }
    env_key = os.environ.get("GEMINI_API_KEY") or os.environ.get("GEMINI_KEY")
    if env_key:
        default_cfg["GEMINI_KEYS"].append({
            "id": 1,
            "name": "Основной (Cloud Env)",
            "key": env_key.strip(),
            "status": "active",
            "requests_today": 0,
            "requests_total": 0,
            "last_used": None,
            "cooldown_until": 0
        })
    if not CONFIG_FILE.exists():
        return default_cfg
    try:
        loaded = json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
        if not loaded.get("GEMINI_KEYS") and env_key:
            loaded["GEMINI_KEYS"] = default_cfg["GEMINI_KEYS"]
        return loaded
    except Exception:
        return default_cfg

def save_config(cfg):
    try:
        CONFIG_FILE.write_text(json.dumps(cfg, indent=2, ensure_ascii=False), encoding="utf-8")
    except Exception:
        pass

cfg = load_config()
BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN") or cfg.get("TELEGRAM_BOT_TOKEN", "8325367009:AAEk_r7mmJgRlYcdXVPsKYBKlApjzx1B0fA")
ALLOWED_CHAT_ID = int(os.environ.get("TELEGRAM_CHAT_ID") or cfg.get("TELEGRAM_CHAT_ID", 8559869613))

# --- ПУЛ КЛЮЧЕЙ GEMINI И УПРАВЛЕНИЕ КВОТАМИ ---

def get_keys():
    config = load_config()
    return config.get("GEMINI_KEYS", [])

def get_active_key_entry():
    keys = get_keys()
    now = time.time()
    for k in keys:
        if k.get("cooldown_until", 0) <= now and k.get("status") in ["active", "cooldown"]:
            return k
    return keys[0] if keys else None

def record_key_success(key_id):
    config = load_config()
    for k in config.get("GEMINI_KEYS", []):
        if k.get("id") == key_id:
            k["requests_today"] = k.get("requests_today", 0) + 1
            k["requests_total"] = k.get("requests_total", 0) + 1
            k["last_used"] = time.strftime("%Y-%m-%d %H:%M:%S")
            k["status"] = "active"
            break
    save_config(config)

def record_key_exhausted(key_id, cooldown_seconds=120):
    config = load_config()
    next_key_name = None
    for idx, k in enumerate(config.get("GEMINI_KEYS", [])):
        if k.get("id") == key_id:
            k["status"] = "cooldown"
            k["cooldown_until"] = time.time() + cooldown_seconds
            for other in config.get("GEMINI_KEYS", []):
                if other.get("id") != key_id and other.get("cooldown_until", 0) <= time.time():
                    next_key_name = other.get("name")
                    break
            break
    save_config(config)
    return next_key_name

def add_new_key(api_key, name=None):
    config = load_config()
    keys = config.setdefault("GEMINI_KEYS", [])
    new_id = max([k.get("id", 0) for k in keys] + [0]) + 1
    key_name = name or f"Аккаунт {new_id}"
    keys.append({
        "id": new_id,
        "name": key_name,
        "key": api_key.strip(),
        "status": "active",
        "requests_today": 0,
        "requests_total": 0,
        "last_used": None,
        "cooldown_until": 0
    })
    save_config(config)
    return key_name

# --- СКИЛЛЫ И КАСТОМНЫЕ АГЕНТЫ ---

def get_installed_skills():
    skills = []
    if SKILLS_DIR.exists():
        for p in SKILLS_DIR.iterdir():
            if p.is_file() and p.suffix.lower() in [".md", ".txt", ".py", ".json"]:
                skills.append(p.name)
    return sorted(skills)

def build_system_prompt():
    base = """Ты — Sonivo AI Agent, автономный Senior iOS Swift разработчик и DevOps инженер проекта Sonivo (музыкальный плеер для iOS на SwiftUI).
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
    custom_skills = []
    if SKILLS_DIR.exists():
        for p in SKILLS_DIR.iterdir():
            if p.is_file() and p.suffix.lower() in [".md", ".txt", ".py", ".json"]:
                try:
                    content = p.read_text(encoding="utf-8", errors="ignore")
                    custom_skills.append(f"\n--- [ЗАГРУЖЕННЫЙ СКИЛЛ: {p.name}] ---\n{content}\n")
                except Exception:
                    pass

    if custom_skills:
        base += "\n\n=== АКТИВНЫЕ ПОЛЬЗОВАТЕЛЬСКИЕ СКИЛЛЫ И ИНСТРУКЦИИ ===\n" + "\n".join(custom_skills)

    return base

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
        "name": "trigger_ipa_build",
        "description": "Запустить новую сборку IPA в GitHub Actions вручную.",
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

def configure_git_auth():
    config = load_config()
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or config.get("GITHUB_TOKEN", "")
    subprocess.run(["git", "config", "user.name", "Sonivo AI Agent"], cwd=REPO_DIR, capture_output=True)
    subprocess.run(["git", "config", "user.email", "agent@sonivo.app"], cwd=REPO_DIR, capture_output=True)
    if token:
        remote_url = f"https://x-access-token:{token.strip()}@github.com/smosiarhei-hue/aura-player.git"
        subprocess.run(["git", "remote", "set-url", "origin", remote_url], cwd=REPO_DIR, capture_output=True)

def tool_git_status():
    res = subprocess.run(["git", "status", "-s"], cwd=REPO_DIR, capture_output=True, text=True)
    return {"status_output": res.stdout.strip() or "Working tree clean"}

def tool_git_commit_and_push(commit_message):
    configure_git_auth()
    add_res = subprocess.run(["git", "add", "."], cwd=REPO_DIR, capture_output=True, text=True)
    commit_res = subprocess.run(["git", "commit", "-m", commit_message], cwd=REPO_DIR, capture_output=True, text=True)
    push_res = subprocess.run(["git", "push", "origin", "main"], cwd=REPO_DIR, capture_output=True, text=True)
    
    success = push_res.returncode == 0
    err_out = push_res.stderr.strip()
    if not success and ("Permission" in err_out or "Authentication" in err_out or "403" in err_out or "fatal" in err_out):
        return {
            "success": False,
            "error": "Git Push Error: Требуется GitHub Token для авторизации на облачном сервере.",
            "hint": "Отправьте боту команду /set_gh_token <ваш_токен_github> (создается в github.com/settings/tokens)",
            "raw": err_out
        }
        
    return {
        "add": add_res.returncode == 0,
        "commit": commit_res.stdout.strip() or commit_res.stderr.strip(),
        "push": push_res.stdout.strip() or push_res.stderr.strip(),
        "success": success
    }

def tool_check_ci_build():
    config = load_config()
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or config.get("GITHUB_TOKEN", "")
    
    # Сначала пробуем через GitHub REST API
    if token:
        try:
            req = urllib.request.Request(
                "https://api.github.com/repos/smosiarhei-hue/aura-player/actions/runs?per_page=3",
                headers={
                    "Authorization": f"Bearer {token}",
                    "Accept": "application/vnd.github+json",
                    "User-Agent": "Sonivo-Agent"
                }
            )
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = json.loads(resp.read().decode())
                runs = []
                for r in data.get("workflow_runs", []):
                    runs.append(f"• #{r.get('run_number')} ({r.get('name')}): {r.get('status')} / {r.get('conclusion')} ({r.get('html_url')})")
                return {"recent_runs": "\n".join(runs) or "No runs found"}
        except Exception as e:
            pass

    res = subprocess.run(["gh", "run", "list", "-L", "3"], cwd=REPO_DIR, capture_output=True, text=True)
    if res.returncode != 0:
        return {"output": "GitHub CLI error or token not set. Use /set_gh_token <token>", "raw": res.stderr}
    return {"recent_runs": res.stdout.strip()}

def tool_get_failed_build_logs():
    res = subprocess.run(["gh", "run", "view", "--log-failed"], cwd=REPO_DIR, capture_output=True, text=True)
    out = res.stdout.strip() or res.stderr.strip()
    return {"failed_logs": out[-4000:] if len(out) > 4000 else out}

def tool_trigger_ipa_build():
    config = load_config()
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or config.get("GITHUB_TOKEN", "")
    
    if token:
        try:
            req = urllib.request.Request(
                "https://api.github.com/repos/smosiarhei-hue/aura-player/actions/workflows/build-ipa.yml/dispatches",
                data=json.dumps({"ref": "main"}).encode("utf-8"),
                headers={
                    "Authorization": f"Bearer {token}",
                    "Accept": "application/vnd.github+json",
                    "User-Agent": "Sonivo-Agent"
                }
            )
            with urllib.request.urlopen(req, timeout=15) as resp:
                return {"success": True, "output": "Build triggered successfully via GitHub API"}
        except Exception as e:
            pass
            
    res = subprocess.run(["gh", "workflow", "run", "build-ipa.yml"], cwd=REPO_DIR, capture_output=True, text=True)
    return {"success": res.returncode == 0, "output": res.stdout.strip() or res.stderr.strip()}

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
    "trigger_ipa_build": tool_trigger_ipa_build,
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

def tg_send(text, chat_id=ALLOWED_CHAT_ID, reply_to=None, reply_markup=None):
    payload = {"chat_id": chat_id, "text": text, "parse_mode": "Markdown"}
    if reply_to:
        payload["reply_to_message_id"] = reply_to
    if reply_markup:
        payload["reply_markup"] = reply_markup
    res = tg_request("sendMessage", payload)
    if not res or not res.get("ok"):
        payload.pop("parse_mode", None)
        return tg_request("sendMessage", payload)
    return res

def tg_edit(text, chat_id, message_id, reply_markup=None):
    payload = {"chat_id": chat_id, "message_id": message_id, "text": text, "parse_mode": "Markdown"}
    if reply_markup:
        payload["reply_markup"] = reply_markup
    res = tg_request("editMessageText", payload)
    if not res or not res.get("ok"):
        payload.pop("parse_mode", None)
        return tg_request("editMessageText", payload)
    return res

def get_main_keyboard():
    return {
        "keyboard": [
            [{"text": "🚀 Собрать IPA"}, {"text": "📊 Статус & Билды"}],
            [{"text": "🔑 Ключи & Квоты"}, {"text": "📦 Мои Скиллы"}],
            [{"text": "📋 Логи ошибок"}, {"text": "🧠 Сменить модель"}]
        ],
        "resize_keyboard": True,
        "persistent": True
    }

# --- GEMINI AGENT CORE WITH AUTOMATIC POOL ROTATION ---

def call_gemini_with_fallback(contents, chat_id=None):
    config = load_config()
    model = config.get("ACTIVE_MODEL", "gemini-2.5-pro")
    keys = config.get("GEMINI_KEYS", [])
    
    if not keys:
        return {"error": "Нет добавленных ключей Gemini API! Нажмите '🔑 Ключи & Квоты' и добавьте ключ."}
        
    system_prompt = build_system_prompt()
    
    for attempt in range(len(keys)):
        key_entry = get_active_key_entry()
        if not key_entry:
            return {"error": "Все ключи Gemini временно исчерпали квоту (кулдаун). Подождите 1-2 минуты или добавьте ещё один аккаунт."}
            
        key_val = key_entry.get("key")
        key_id = key_entry.get("id")
        key_name = key_entry.get("name")
        
        for m in [model, "gemini-3.6-flash", "gemini-3.7-flash", "gemini-flash-latest", "gemini-3.5-flash", "gemini-3.1-pro-preview"]:
            url = f"https://generativelanguage.googleapis.com/v1beta/models/{m}:generateContent?key={key_val}"
            payload = {
                "contents": contents,
                "systemInstruction": {"parts": [{"text": system_prompt}]},
                "tools": [{"functionDeclarations": TOOL_DECLARATIONS}],
                "generationConfig": {"temperature": 0.2}
            }
            
            req = urllib.request.Request(
                url,
                data=json.dumps(payload).encode("utf-8"),
                headers={"Content-Type": "application/json"}
            )
            try:
                with urllib.request.urlopen(req, timeout=90) as resp:
                    data = json.loads(resp.read().decode())
                    record_key_success(key_id)
                    return data
            except urllib.error.HTTPError as e:
                err_body = e.read().decode()
                print(f"[Gemini HTTP {e.code} on {m} / {key_name}]: {err_body}")
                
                if e.code in [429, 403]:
                    next_name = record_key_exhausted(key_id, cooldown_seconds=90)
                    if chat_id:
                        msg = f"⚠️ *Квота на ключе '{key_name}' исчерпана!*"
                        if next_name:
                            msg += f"\n🔄 Автоматически переключился на *'{next_name}'*..."
                        else:
                            msg += "\n⏳ Ожидаю сброса лимита..."
                        tg_send(msg, chat_id=chat_id)
                    break
                elif e.code in [404, 400]:
                    continue
                else:
                    return {"error": f"HTTP {e.code}: {err_body}"}
            except Exception as e:
                print(f"[Gemini Error on {m} / {key_name}]: {e}")
                return {"error": str(e)}
                
    return {"error": "Все доступные аккаунты Gemini исчерпали свои квоты. Добавьте новый бесплатный ключ через '🔑 Ключи & Квоты'."}

def execute_agent_loop(user_prompt, status_msg_id, chat_id):
    history = [
        {"role": "user", "parts": [{"text": user_prompt}]}
    ]
    
    max_steps = 15
    for step in range(max_steps):
        if status_msg_id:
            tg_edit(f"🤖 *Sonivo AI Agent* (Шаг {step+1}/{max_steps}):\nДумаю над решением...", chat_id, status_msg_id)
        
        response = call_gemini_with_fallback(history, chat_id=chat_id)
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
            elif name == "trigger_ipa_build":
                action_desc = "🚀 Запускаю новую сборку IPA в GitHub Actions..."
                
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

# --- ОБРАБОТЧИКИ МЕНЮ И КОМАНД ---

def show_keys_menu(chat_id, reply_to=None):
    keys = get_keys()
    now = time.time()
    
    text = "🔑 *Управление ключами и квотами Gemini API*\n\n"
    if not keys:
        text += "_У вас пока нет добавленных ключей!_\n"
    else:
        for k in keys:
            k_id = k.get("id")
            k_name = k.get("name")
            k_val = k.get("key", "")
            masked = k_val[:6] + "..." + k_val[-4:] if len(k_val) > 10 else "***"
            status = k.get("status", "active")
            cooldown = max(0, int(k.get("cooldown_until", 0) - now))
            
            status_icon = "🟢 Активен"
            if cooldown > 0:
                status_icon = f"⏳ Кулдаун ({cooldown} сек)"
            elif status != "active":
                status_icon = "🔴 Ошибка"
                
            req_today = k.get("requests_today", 0)
            req_total = k.get("requests_total", 0)
            
            text += f"*{k_name}* (`{masked}`)\n"
            text += f"• Статус: {status_icon}\n"
            text += f"• Запросов сегодня: `{req_today}` (Всего: `{req_total}`)\n\n"
            
    text += "💡 _При исчерпании лимита бот автоматически переключится на следующий свободный аккаунт!_\n"
    text += "Чтобы добавить новый ключ, отправьте: `/add_key <API_KEY> [Название]` или нажмите кнопку ниже:"
    
    inline_kb = {
        "inline_keyboard": [
            [{"text": "➕ Добавить ключ API", "callback_data": "btn_add_key"}],
            [{"text": "🔄 Обновить статус", "callback_data": "btn_refresh_keys"}]
        ]
    }
    tg_send(text, chat_id=chat_id, reply_to=reply_to, reply_markup=inline_kb)

def show_skills_menu(chat_id, reply_to=None):
    skills = get_installed_skills()
    text = "📦 *Загруженные Скиллы и Агенты*\n\n"
    if not skills:
        text += "_Скиллы пока не установлены._\n\n"
    else:
        text += "Активные скиллы, внедрённые в системный промпт агента:\n"
        for s in skills:
            text += f"• 📄 *{s}*\n"
        text += "\n"
        
    text += "📥 *Как добавить скилл:*\n"
    text += "Просто перешлите боту любой файл (`.md`, `.txt`, `.py`, `.json`) со своими инструкциями, правилами кода или дизайном!\n"
    text += "Бот мгновенно сохранит его в `agent_skills/` и начнёт использовать."
    
    tg_send(text, chat_id=chat_id, reply_to=reply_to)

def show_model_menu(chat_id, reply_to=None):
    config = load_config()
    current = config.get("ACTIVE_MODEL", "gemini-3.6-flash")
    
    text = f"🧠 *Выбор модели AI*\n\nТекущая модель: *{current}*\n\n"
    text += "• *gemini-3.6-flash* — молниеносная скорость, высокие лимиты, стабильный анализ кода (Рекомендуется).\n"
    text += "• *gemini-3.7-flash* — новейшая модель Flash с улучшенным рассуждением.\n"
    text += "• *gemini-3.1-pro-preview* — максимальный интеллект для масштабных рефакторингов."
    
    inline_kb = {
        "inline_keyboard": [
            [{"text": f"{'✅ ' if current=='gemini-3.6-flash' else ''}Gemini 3.6 Flash (Рекомендуется)", "callback_data": "model_gemini-3.6-flash"}],
            [{"text": f"{'✅ ' if current=='gemini-3.7-flash' else ''}Gemini 3.7 Flash", "callback_data": "model_gemini-3.7-flash"}],
            [{"text": f"{'✅ ' if current=='gemini-3.1-pro-preview' else ''}Gemini 3.1 Pro", "callback_data": "model_gemini-3.1-pro-preview"}]
        ]
    }
    tg_send(text, chat_id=chat_id, reply_to=reply_to, reply_markup=inline_kb)

# --- ОСНОВНОЙ ЦИКЛ ОПРОСА TELEGRAM ---

def start_bot():
    print("="*60)
    print("🤖 Sonivo Autonomous Telegram AI Developer Agent v2.0")
    print(f"📌 Авторизованный Chat ID: {ALLOWED_CHAT_ID}")
    print(f"📁 Репозиторий: {REPO_DIR}")
    print("="*60)
    
    tg_send(
        "🚀 *Sonivo AI Agent v2.0 активирован!*\n\n"
        "✨ *Что нового:*\n"
        "• 📱 Удобные кнопки меню прямо под клавиатурой\n"
        "• 🔑 Пул ключей Gemini с *автоматическим переключением* при исчерпании квот\n"
        "• 📦 Возможность загружать свои *Скиллы и Агентов* файлами прямо в чат\n"
        "• 🚀 Запуск сборки IPA в один клик\n\n"
        "Пишите любые задачи или выберите действие в меню ниже! 🎧",
        reply_markup=get_main_keyboard()
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
                
                if "callback_query" in u:
                    cq = u["callback_query"]
                    cq_id = cq["id"]
                    cq_data = cq.get("data", "")
                    cq_from = cq.get("from", {}).get("id")
                    
                    if cq_from != ALLOWED_CHAT_ID:
                        continue
                        
                    tg_request("answerCallbackQuery", {"callback_query_id": cq_id})
                    
                    if cq_data == "btn_add_key":
                        user_states[ALLOWED_CHAT_ID] = "WAITING_FOR_API_KEY"
                        tg_send("🔑 *Отправьте ваш ключ Gemini API следующим сообщением:*")
                    elif cq_data == "btn_refresh_keys":
                        show_keys_menu(ALLOWED_CHAT_ID)
                    elif cq_data.startswith("model_"):
                        new_model = cq_data.replace("model_", "")
                        config = load_config()
                        config["ACTIVE_MODEL"] = new_model
                        save_config(config)
                        tg_send(f"✅ Активная модель переключена на: *{new_model}*")
                    continue
                    
                msg = u.get("message")
                if not msg:
                    continue
                    
                sender_id = msg.get("from", {}).get("id")
                if sender_id != ALLOWED_CHAT_ID:
                    print(f"[Security] Ignored message from unauthorized user: {sender_id}")
                    continue
                    
                msg_id = msg["message_id"]
                
                if "document" in msg:
                    doc = msg["document"]
                    doc_name = doc.get("file_name", "custom_skill.md")
                    file_id = doc.get("file_id")
                    
                    file_info = tg_request("getFile", {"file_id": file_id})
                    if file_info and file_info.get("ok"):
                        f_path = file_info["result"]["file_path"]
                        download_url = f"https://api.telegram.org/file/bot{BOT_TOKEN}/{f_path}"
                        try:
                            with urllib.request.urlopen(download_url) as r:
                                content = r.read().decode("utf-8", errors="replace")
                                target_file = SKILLS_DIR / doc_name
                                target_file.write_text(content, encoding="utf-8")
                                tg_send(f"📦 *Скилл `{doc_name}` успешно загружен и активирован!*\nТеперь AI-агент использует эти инструкции в своей работе.", reply_to=msg_id)
                                continue
                        except Exception as ex:
                            tg_send(f"❌ Ошибка сохранения файла: {ex}", reply_to=msg_id)
                            continue
                            
                text = msg.get("text", "").strip()
                if not text:
                    if "caption" in msg:
                        text = msg["caption"].strip()
                    else:
                        continue
                        
                print(f"\n[User Request]: {text}")
                
                if user_states.get(ALLOWED_CHAT_ID) == "WAITING_FOR_API_KEY":
                    user_states.pop(ALLOWED_CHAT_ID, None)
                    if len(text) > 15:
                        k_name = add_new_key(text)
                        tg_send(f"✅ *Ключ успешно добавлен!* Название: *{k_name}*\nТеперь агент может автоматически переключаться на него при исчерпании квот.", reply_to=msg_id)
                        show_keys_menu(ALLOWED_CHAT_ID)
                    else:
                        tg_send("⚠️ Текст не похож на ключ Gemini API. Добавление отменено.", reply_to=msg_id)
                    continue
                    
                if text in ["/start", "Меню"]:
                    tg_send(
                        "👋 Привет! Я твой личный AI-разработчик Sonivo.\n\n"
                        "Отправь мне задачу, ошибку, лог или пожелание — я всё сделаю сам!",
                        reply_to=msg_id,
                        reply_markup=get_main_keyboard()
                    )
                    continue
                elif text in ["/keys", "🔑 Ключи & Квоты"]:
                    show_keys_menu(ALLOWED_CHAT_ID, reply_to=msg_id)
                    continue
                elif text in ["/skills", "📦 Мои Скиллы"]:
                    show_skills_menu(ALLOWED_CHAT_ID, reply_to=msg_id)
                    continue
                elif text in ["/model", "🧠 Сменить модель"]:
                    show_model_menu(ALLOWED_CHAT_ID, reply_to=msg_id)
                    continue
                elif text.startswith("/set_gh_token"):
                    parts = text.split(maxsplit=1)
                    if len(parts) >= 2:
                        tok = parts[1].strip()
                        config = load_config()
                        config["GITHUB_TOKEN"] = tok
                        save_config(config)
                        os.environ["GH_TOKEN"] = tok
                        configure_git_auth()
                        tg_send("✅ *GitHub Token сохранен!*\nТеперь бот может отправлять коммиты и запускать сборки прямо из облака.", reply_to=msg_id)
                    else:
                        tg_send("Использование: `/set_gh_token <ghp_...>`\nТокен создается в https://github.com/settings/tokens (права: repo + workflow)", reply_to=msg_id)
                    continue
                elif text.startswith("/add_key"):
                    parts = text.split(maxsplit=2)
                    if len(parts) >= 2:
                        k_val = parts[1]
                        k_name = parts[2] if len(parts) > 2 else None
                        added_name = add_new_key(k_val, k_name)
                        tg_send(f"✅ *Ключ успешно добавлен!* Название: *{added_name}*", reply_to=msg_id)
                    else:
                        tg_send("Использование: `/add_key <API_KEY> [Название]`", reply_to=msg_id)
                    continue
                elif text in ["/status", "📊 Статус & Билды"]:
                    status = tool_git_status()
                    ci = tool_check_ci_build()
                    tg_send(
                        f"📊 *Статус Git*:\n```\n{status.get('status_output')}\n```\n\n"
                        f"⚙️ *Сборки GitHub Actions*:\n```\n{ci.get('recent_runs')}\n```",
                        reply_to=msg_id
                    )
                    continue
                elif text in ["/logs", "📋 Логи ошибок"]:
                    logs = tool_get_failed_build_logs()
                    tg_send(f"📋 *Логи последней ошибки*:\n```\n{logs.get('failed_logs')}\n```", reply_to=msg_id)
                    continue
                elif text in ["/build", "🚀 Собрать IPA"]:
                    res = tool_trigger_ipa_build()
                    if res.get("success"):
                        tg_send("🚀 *Сборка IPA запущена в GitHub Actions!*\nКак только билд завершится, готовый `.ipa` прилетит сюда в чат.", reply_to=msg_id)
                    else:
                        tg_send(f"⚠️ Ошибка запуска сборки: {res.get('output')}", reply_to=msg_id)
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
