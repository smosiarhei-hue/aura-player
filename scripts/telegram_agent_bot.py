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
import base64
import urllib.request
import urllib.parse
import urllib.error
import subprocess
import shutil
import http.server
import threading
from pathlib import Path

# --- КОНФИГУРАЦИЯ И ПУТИ ---
REPO_DIR = Path(__file__).resolve().parent.parent
CONFIG_FILE = REPO_DIR / "agent_config.json"
SKILLS_DIR = REPO_DIR / "agent_skills"
SKILLS_DIR.mkdir(exist_ok=True)

user_states = {}

def sanitize_keys(keys_list):
    valid = []
    for k in keys_list:
        val = str(k.get("key", "")).strip()
        if val and len(val) >= 20 and not any(ord(c) > 127 or c.isspace() for c in val):
            valid.append(k)
    return valid

def load_config():
    default_cfg = {
        "TELEGRAM_BOT_TOKEN": os.environ.get("TELEGRAM_BOT_TOKEN", "8325367009:AAEk_r7mmJgRlYcdXVPsKYBKlApjzx1B0fA"),
        "TELEGRAM_CHAT_ID": int(os.environ.get("TELEGRAM_CHAT_ID", 8559869613)),
        "ACTIVE_MODEL": "gemini-3.6-flash",
        "BOT_MODE": "dev",
        "GEMINI_KEYS": [],
        "HF_TOKEN": os.environ.get("HF_TOKEN", ""),
        "HF_SPACE": os.environ.get("HF_SPACE", "IsseT/sonivo-bot")
    }
    
    env_agy = os.environ.get("ANTIGRAVITY_CREDS_JSON")
    if env_agy:
        try:
            default_cfg["ANTIGRAVITY_CREDS"] = json.loads(env_agy)
        except Exception:
            pass

    env_key = os.environ.get("GEMINI_API_KEY") or os.environ.get("GEMINI_KEY")
    if env_key and not any(ord(c) > 127 or c.isspace() for c in env_key.strip()):
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
        loaded["GEMINI_KEYS"] = sanitize_keys(loaded.get("GEMINI_KEYS", []))
        if "BOT_MODE" not in loaded:
            loaded["BOT_MODE"] = "dev"
        if not loaded.get("ANTIGRAVITY_CREDS") and env_agy:
            try:
                loaded["ANTIGRAVITY_CREDS"] = json.loads(env_agy)
            except Exception:
                pass
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

# --- ПУЛ КЛЮЧЕЙ И МУЛЬТИ-ПРОВАЙДЕРЫ (Gemini, DeepSeek, OpenRouter, Groq, Custom API) ---

def get_keys():
    config = load_config()
    return config.get("AI_KEYS") or config.get("GEMINI_KEYS", [])

def get_active_key_entry():
    keys = get_keys()
    now = time.time()
    for k in keys:
        if k.get("cooldown_until", 0) <= now and k.get("status") in ["active", "cooldown"]:
            return k
    return keys[0] if keys else None

def record_key_success(key_id):
    config = load_config()
    key_list = config.get("AI_KEYS") or config.get("GEMINI_KEYS", [])
    for k in key_list:
        if k.get("id") == key_id:
            k["requests_today"] = k.get("requests_today", 0) + 1
            k["requests_total"] = k.get("requests_total", 0) + 1
            k["last_used"] = time.strftime("%Y-%m-%d %H:%M:%S")
            k["status"] = "active"
            break
    config["AI_KEYS"] = key_list
    config["GEMINI_KEYS"] = key_list
    save_config(config)

def record_key_exhausted(key_id, cooldown_seconds=120):
    config = load_config()
    key_list = config.get("AI_KEYS") or config.get("GEMINI_KEYS", [])
    next_key_name = None
    for k in key_list:
        if k.get("id") == key_id:
            k["status"] = "cooldown"
            k["cooldown_until"] = time.time() + cooldown_seconds
            for other in key_list:
                if other.get("id") != key_id and other.get("cooldown_until", 0) <= time.time():
                    next_key_name = other.get("name")
                    break
            break
    config["AI_KEYS"] = key_list
    config["GEMINI_KEYS"] = key_list
    save_config(config)
    return next_key_name

def test_and_discover_models(base_url, api_key, provider_type=None):
    clean_key = api_key.strip()
    if not provider_type:
        if clean_key.startswith("AQ.") or clean_key.startswith("AIza"):
            provider_type = "gemini"
        elif clean_key.startswith("sk-or-"):
            provider_type = "openrouter"
        elif clean_key.startswith("gsk_"):
            provider_type = "groq"
        elif clean_key.startswith("sk-"):
            provider_type = "deepseek"
        else:
            provider_type = "openai_compatible"
            
    if provider_type == "gemini":
        url = f"https://generativelanguage.googleapis.com/v1beta/models?key={clean_key}"
        req = urllib.request.Request(url, headers={"User-Agent": "Sonivo-Agent"})
        try:
            with urllib.request.urlopen(req, timeout=12) as resp:
                data = json.loads(resp.read().decode())
                models = [m.get("name", "").replace("models/", "") for m in data.get("models", []) if "generateContent" in m.get("supportedGenerationMethods", [])]
                curated = [m for m in models if "flash" in m or "pro" in m]
                free_list = [m for m in curated if "flash" in m]
                top_list = [m for m in curated if "pro" in m or "3.7" in m]
                return {
                    "valid": True,
                    "provider": "gemini",
                    "models": curated or models[:15],
                    "free_models": free_list,
                    "top_models": top_list,
                    "status_msg": f"🟢 Ключ Gemini рабочий! Доступно моделей: {len(models)}"
                }
        except urllib.error.HTTPError as e:
            if e.code == 429:
                return {"valid": True, "provider": "gemini", "status_msg": "⏳ Ключ верный, но лимит исчерпан", "models": ["gemini-3.6-flash", "gemini-3.7-flash"], "free_models": ["gemini-3.6-flash"], "top_models": ["gemini-3.7-flash"]}
            return {"valid": False, "provider": "gemini", "error": f"HTTP {e.code}: Неверный ключ или ошибка доступа", "models": [], "free_models": [], "top_models": []}
        except Exception as e:
            return {"valid": False, "provider": "gemini", "error": str(e), "models": [], "free_models": [], "top_models": []}
    else:
        target_url = (base_url or "https://api.deepseek.com").rstrip("/")
        models_endpoint = target_url + "/models"
        req = urllib.request.Request(
            models_endpoint,
            headers={"Authorization": f"Bearer {clean_key}", "User-Agent": "Sonivo-Agent"}
        )
        try:
            with urllib.request.urlopen(req, timeout=12) as resp:
                data = json.loads(resp.read().decode())
                raw_models = data.get("data", [])
                model_ids = []
                for m in raw_models:
                    if isinstance(m, dict) and "id" in m:
                        model_ids.append(m["id"])
                    elif isinstance(m, str):
                        model_ids.append(m)
                
                free_m = [m for m in model_ids if ":free" in m or "free" in m.lower()]
                top_m = [m for m in model_ids if any(k in m.lower() for k in ["coder", "deepseek", "claude", "gpt-4", "llama", "qwen", "gemini", "o1", "o3", "sonnet"])]
                
                return {
                    "valid": True,
                    "provider": provider_type,
                    "models": model_ids[:40],
                    "free_models": free_m[:20],
                    "top_models": top_m[:20],
                    "status_msg": f"🟢 Ключ рабочий! На сервере найдено {len(model_ids)} моделей"
                }
        except urllib.error.HTTPError as e:
            if e.code == 401:
                return {"valid": False, "provider": provider_type, "error": "🔴 Ошибка 401: Неверный API-ключ (Unauthorized)", "models": [], "free_models": [], "top_models": []}
            
            # Test with chat completion for endpoints without /models
            try:
                test_url = target_url + "/chat/completions"
                payload = {
                    "model": "deepseek-chat",
                    "messages": [{"role": "user", "content": "hi"}],
                    "max_tokens": 1
                }
                t_req = urllib.request.Request(
                    test_url,
                    data=json.dumps(payload).encode("utf-8"),
                    headers={"Authorization": f"Bearer {clean_key}", "Content-Type": "application/json", "User-Agent": "Sonivo-Agent"}
                )
                with urllib.request.urlopen(t_req, timeout=10) as t_resp:
                    return {
                        "valid": True,
                        "provider": provider_type,
                        "models": ["deepseek-chat"],
                        "free_models": [],
                        "top_models": ["deepseek-chat"],
                        "status_msg": "🟢 Ключ успешно проверен и авторизован!"
                    }
            except urllib.error.HTTPError as te:
                if te.code == 404:
                    return {"valid": True, "provider": provider_type, "models": [], "free_models": [], "top_models": [], "status_msg": "🟢 Авторизация пройдена! Введите имя модели"}
                return {"valid": False, "provider": provider_type, "error": f"HTTP {te.code}: Ошибка авторизации", "models": [], "free_models": [], "top_models": []}
            except Exception as te:
                return {"valid": False, "provider": provider_type, "error": str(te), "models": [], "free_models": [], "top_models": []}
        except Exception as e:
            return {"valid": False, "provider": provider_type, "error": str(e), "models": [], "free_models": [], "top_models": []}

def add_new_key(api_key, name=None, provider=None, base_url=None, model=None, available_models=None):
    config = load_config()
    key_list = config.get("AI_KEYS") or config.get("GEMINI_KEYS", [])
    new_id = max([k.get("id", 0) for k in key_list] + [0]) + 1
    
    clean_key = api_key.strip()
    if not provider:
        if clean_key.startswith("sk-or-"):
            provider = "openrouter"
            base_url = "https://openrouter.ai/api/v1"
            model = model or "deepseek/deepseek-r1:free"
            default_name = f"OpenRouter {new_id}"
        elif clean_key.startswith("gsk_"):
            provider = "groq"
            base_url = "https://api.groq.com/openai/v1"
            model = model or "llama-3.3-70b-versatile"
            default_name = f"Groq {new_id}"
        elif clean_key.startswith("sk-"):
            provider = "deepseek"
            base_url = "https://api.deepseek.com"
            model = model or "deepseek-chat"
            default_name = f"DeepSeek {new_id}"
        else:
            provider = "gemini"
            base_url = "https://generativelanguage.googleapis.com/v1beta"
            model = model or "gemini-3.6-flash"
            default_name = f"Gemini {new_id}"
    else:
        default_name = f"{provider.capitalize()} {new_id}"

    key_name = name or default_name
    models_to_store = available_models or ([model] if model else [])
    if model and model not in models_to_store:
        models_to_store.insert(0, model)

    key_list.append({
        "id": new_id,
        "provider": provider,
        "name": key_name,
        "key": clean_key,
        "base_url": base_url,
        "model": model or (models_to_store[0] if models_to_store else "default"),
        "available_models": models_to_store,
        "status": "active",
        "requests_today": 0,
        "requests_total": 0,
        "last_used": None,
        "cooldown_until": 0
    })
    config["AI_KEYS"] = key_list
    config["GEMINI_KEYS"] = key_list
    save_config(config)
    return key_name, provider

# --- СКИЛЛЫ И КАСТОМНЫЕ АГЕНТЫ ---

def get_installed_skills():
    skills = []
    if SKILLS_DIR.exists():
        for p in SKILLS_DIR.iterdir():
            if p.is_file() and p.suffix.lower() in [".md", ".txt", ".py", ".json"]:
                skills.append(p.name)
    return sorted(skills)

def build_system_prompt():
    config = load_config()
    mode = config.get("BOT_MODE", "dev")
    
    if mode == "chat":
        base = """Ты — Sonivo AI Консультант и Архитектор, персональный AI-эксперт для создателя проекта Sonivo.
Твоя цель — быть личным собеседником и экспертом:
- Отвечать на любые вопросы пользователя (теория, архитектура, идеи фичей, анализ кода, дизайн, маркетинг).
- Ты полностью знаешь кодовую базу Sonivo (можешь читать файлы и искать код через read_file/search_code).
- Ты умеешь детально анализировать присланные скриншоты, фотографии макетов, видео-шоты и аудиозаписи.
- В РЕЖИМЕ ЧАТА НЕ МЕНЯЙ ФАЙЛЫ И НЕ ДЕЛАЙ КОММИТЫ (edit_file / git_commit_and_push), если пользователь прямо не попросит об этом! Твоя задача здесь — давать умные, экспертные ответы, генерировать код в тексте и рассуждать.
"""
    else:
        base = """Ты — Sonivo AI Agent, автономный Senior iOS Swift разработчик и DevOps инженер проекта Sonivo (музыкальный плеер для iOS на SwiftUI).
Твоя цель — выполнять любые задачи пользователя прямо из Telegram:
- Анализировать структуру проекта, искать нужные файлы и код.
- Анализировать присланные скриншоты, макеты, видео-шоты и голосовые сообщения.
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
    },
    {
        "name": "hf_get_status",
        "description": "Получить статус сервера Hugging Face Spaces (RUNNING, PAUSED, ошибки).",
        "parameters": {"type": "OBJECT", "properties": {}}
    },
    {
        "name": "hf_restart_space",
        "description": "Перезагрузить сервер Hugging Face Spaces.",
        "parameters": {"type": "OBJECT", "properties": {}}
    },
    {
        "name": "hf_get_file",
        "description": "Прочитать файл из репозитория Hugging Face Space (например 'app.py').",
        "parameters": {
            "type": "OBJECT",
            "properties": {
                "file_path": {"type": "STRING", "description": "Путь к файлу на Hugging Face (по умолчанию 'app.py')"}
            }
        }
    },
    {
        "name": "hf_update_file",
        "description": "Изменить код файла прямо на сервере Hugging Face Space (например обновить 'app.py').",
        "parameters": {
            "type": "OBJECT",
            "properties": {
                "file_path": {"type": "STRING", "description": "Имя файла на HF (например 'app.py')"},
                "content": {"type": "STRING", "description": "Новый код файла"},
                "commit_message": {"type": "STRING", "description": "Описание коммита"}
            },
            "required": ["file_path", "content"]
        }
    },
    {
        "name": "generate_ai_image",
        "description": "Сгенерировать изображение, обложку альбома, арт, иконку или UI-ассет по текстовому описанию (Google Imagen 3 / FLUX).",
        "parameters": {
            "type": "OBJECT",
            "properties": {
                "prompt": {"type": "STRING", "description": "Детальный запрос для генерации картинки на английском или русском"},
                "aspect_ratio": {"type": "STRING", "description": "Соотношение: '1:1', '3:4', '4:3', '16:9', '9:16'"},
                "file_name": {"type": "STRING", "description": "Опционально: имя файла для сохранения в проект"}
            },
            "required": ["prompt"]
        }
    },
    {
        "name": "antigravity_cli",
        "description": "Выполнить команду через официальный Google Antigravity CLI (agy) для автономного программирования, анализа или управления плагинами.",
        "parameters": {
            "type": "OBJECT",
            "properties": {
                "command": {"type": "STRING", "description": "Аргументы команды agy (например: 'models', 'agents', 'plugin list', '--version')"},
                "prompt": {"type": "STRING", "description": "Промпт для автономного выполнения агентом agy --print"}
            }
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
        except Exception:
            pass

    # Публичный запрос к GitHub REST API (работает без gh CLI)
    try:
        req = urllib.request.Request(
            "https://api.github.com/repos/smosiarhei-hue/aura-player/actions/runs?per_page=3",
            headers={"Accept": "application/vnd.github+json", "User-Agent": "Sonivo-Agent"}
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read().decode())
            runs = []
            for r in data.get("workflow_runs", []):
                runs.append(f"• #{r.get('run_number')} ({r.get('name')}): {r.get('status')} / {r.get('conclusion') or 'in_progress'} ({r.get('html_url')})")
            return {"recent_runs": "\n".join(runs) or "Сборок пока не найдено"}
    except Exception:
        pass

    try:
        res = subprocess.run(["gh", "run", "list", "-L", "3"], cwd=REPO_DIR, capture_output=True, text=True)
        if res.returncode != 0:
            return {"output": "Токен не установлен. Отправьте /set_gh_token <токен_github>", "raw": res.stderr}
        return {"recent_runs": res.stdout.strip()}
    except Exception:
        return {"output": "Для полного доступа к CI добавьте токен командой /set_gh_token <токен>"}

def tool_get_failed_build_logs():
    config = load_config()
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or config.get("GITHUB_TOKEN", "")
    
    if token:
        try:
            req = urllib.request.Request(
                "https://api.github.com/repos/smosiarhei-hue/aura-player/actions/runs?status=failure&per_page=1",
                headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json", "User-Agent": "Sonivo-Agent"}
            )
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = json.loads(resp.read().decode())
                runs = data.get("workflow_runs", [])
                if runs:
                    return {"failed_logs": f"Последняя упавшая сборка #{runs[0].get('run_number')}: {runs[0].get('html_url')}"}
        except Exception:
            pass
            
    try:
        res = subprocess.run(["gh", "run", "view", "--log-failed"], cwd=REPO_DIR, capture_output=True, text=True)
        out = res.stdout.strip() or res.stderr.strip()
        return {"failed_logs": out[-4000:] if len(out) > 4000 else out}
    except Exception:
        return {"failed_logs": "Логи доступны на странице: https://github.com/smosiarhei-hue/aura-player/actions"}

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
        except urllib.error.HTTPError as e:
            return {"success": False, "output": f"GitHub API error {e.code}: {e.read().decode()}"}
        except Exception as e:
            return {"success": False, "output": str(e)}
            
    try:
        res = subprocess.run(["gh", "workflow", "run", "build-ipa.yml"], cwd=REPO_DIR, capture_output=True, text=True)
        return {"success": res.returncode == 0, "output": res.stdout.strip() or res.stderr.strip()}
    except FileNotFoundError:
        return {
            "success": False,
            "output": "Для запуска сборки с сервера нужен GitHub Token. Отправьте боту команду /set_gh_token <токен>"
        }
    except Exception as ex:
        return {"success": False, "output": str(ex)}

def tool_run_shell_command(command):
    res = subprocess.run(command, cwd=REPO_DIR, capture_output=True, text=True, shell=True)
    return {
        "returncode": res.returncode,
        "stdout": res.stdout.strip()[:2000],
        "stderr": res.stderr.strip()[:2000]
    }

# --- HUGGING FACE SPACES API & ADMIN ---

def get_hf_config():
    config = load_config()
    token = os.environ.get("HF_TOKEN") or config.get("HF_TOKEN", "")
    space = os.environ.get("HF_SPACE") or config.get("HF_SPACE", "IsseT/sonivo-bot")
    return token, space

def tool_hf_get_status():
    token, space = get_hf_config()
    headers = {"User-Agent": "Sonivo-Agent"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    url = f"https://huggingface.co/api/spaces/{space}"
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read().decode())
            runtime = data.get("runtime", {})
            stage = runtime.get("stage", "UNKNOWN")
            hardware = runtime.get("hardware", {}).get("current", "cpu-basic")
            return {
                "space": space,
                "stage": stage,
                "hardware": hardware,
                "likes": data.get("likes", 0),
                "private": data.get("private", False)
            }
    except urllib.error.HTTPError as e:
        return {"error": f"HTTP {e.code}: {e.read().decode()}"}
    except Exception as e:
        return {"error": str(e)}

def tool_hf_restart_space():
    token, space = get_hf_config()
    if not token:
        return {"error": "HF_TOKEN не установлен. Отправьте /set_hf_token <токен_с_hf>"}
    url = f"https://huggingface.co/api/spaces/{space}/restart"
    req = urllib.request.Request(url, data=b"", headers={"Authorization": f"Bearer {token}", "User-Agent": "Sonivo-Agent"})
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return {"success": True, "message": f"Space '{space}' перезагружается..."}
    except urllib.error.HTTPError as e:
        return {"error": f"HTTP {e.code}: {e.read().decode()}"}
    except Exception as e:
        return {"error": str(e)}

def tool_hf_get_file(file_path="app.py"):
    token, space = get_hf_config()
    url = f"https://huggingface.co/spaces/{space}/raw/main/{file_path}"
    headers = {"User-Agent": "Sonivo-Agent"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            content = resp.read().decode("utf-8")
            return {"file_path": file_path, "content": content}
    except Exception as e:
        return {"error": f"Не удалось прочитать {file_path}: {e}"}

def tool_hf_update_file(file_path, content, commit_message="Update via Telegram Admin"):
    token, space = get_hf_config()
    if not token:
        return {"error": "HF_TOKEN не установлен. Отправьте /set_hf_token <токен>"}
    
    url = f"https://huggingface.co/api/spaces/{space}/commit/main"
    b64_content = base64.b64encode(content.encode("utf-8")).decode("utf-8")
    payload = {
        "summary": commit_message,
        "operations": [
            {
                "operation": "add",
                "path": file_path,
                "content": b64_content,
                "encoding": "base64"
            }
        ]
    }
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json", "User-Agent": "Sonivo-Agent"}
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return {"success": True, "file_path": file_path, "message": f"Файл '{file_path}' на Hugging Face успешно обновлен!"}
    except urllib.error.HTTPError as e:
        return {"error": f"HTTP {e.code}: {e.read().decode()}"}
    except Exception as e:
        return {"error": str(e)}

def tool_hf_get_logs(log_type="run"):
    token, space = get_hf_config()
    if not token:
        return {"error": "HF_TOKEN не установлен. Отправьте /set_hf_token <токен>"}
    
    url = f"https://huggingface.co/api/spaces/{space}/logs/{log_type}"
    headers = {
        "Authorization": f"Bearer {token}",
        "User-Agent": "Sonivo-Agent",
        "Accept": "text/event-stream"
    }
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=8) as resp:
            lines = []
            start_t = time.time()
            while time.time() - start_t < 4.0:
                raw_line = resp.readline()
                if not raw_line:
                    break
                line_str = raw_line.decode("utf-8", errors="replace").strip()
                if line_str.startswith("data:"):
                    line_str = line_str[5:].strip()
                if line_str:
                    lines.append(line_str)
                if len(lines) >= 40:
                    break
            
            res_logs = "\n".join(lines[-25:])
            return {"success": True, "log_type": log_type, "logs": res_logs or "Логи пусты или сервер только запускается."}
    except urllib.error.HTTPError as e:
        return {"error": f"HTTP {e.code}: {e.read().decode()}"}
    except Exception as e:
        return {"error": str(e)}

def tool_generate_ai_image(prompt, aspect_ratio="1:1", file_name=None):
    keys = get_keys()
    gemini_keys = [k for k in keys if k.get("provider") == "gemini"]
    
    # 1. Try Google Imagen 3 via Gemini API
    for gk in gemini_keys:
        k_val = gk.get("key")
        url = f"https://generativelanguage.googleapis.com/v1beta/models/imagen-3.0-generate-002:predict?key={k_val}"
        payload = {
            "instances": [{"prompt": prompt}],
            "parameters": {
                "sampleCount": 1,
                "aspectRatio": aspect_ratio if aspect_ratio in ["1:1", "3:4", "4:3", "16:9", "9:16"] else "1:1"
            }
        }
        req = urllib.request.Request(
            url,
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"}
        )
        try:
            with urllib.request.urlopen(req, timeout=40) as resp:
                res_data = json.loads(resp.read().decode())
                preds = res_data.get("predictions", [])
                if preds and "bytesBase64Encoded" in preds[0]:
                    b64_img = preds[0]["bytesBase64Encoded"]
                    img_bytes = base64.b64decode(b64_img)
                    
                    if file_name:
                        out_p = REPO_DIR / "Aurora" / "Assets.xcassets" / file_name
                        out_p.parent.mkdir(parents=True, exist_ok=True)
                        out_p.write_bytes(img_bytes)
                    
                    tg_send(f"🎨 *Сгенерировано изображение (Google Imagen 3)*\nЗапрос: _{prompt}_")
                    return {"success": True, "prompt": prompt, "model": "Imagen 3", "saved_file": file_name}
        except Exception as e:
            print(f"[Imagen 3 error]: {e}")
            
    # 2. Universal Free High-Quality Fallback (Pollinations AI FLUX)
    clean_p = urllib.parse.quote(prompt)
    gen_url = f"https://image.pollinations.ai/prompt/{clean_p}?width=1024&height=1024&nologo=true&model=flux"
    tg_send_photo(gen_url, caption=f"🎨 *Сгенерировано изображение (FLUX AI):*\n_{prompt}_")
    return {"success": True, "prompt": prompt, "url": gen_url, "model": "FLUX"}

def tool_antigravity_cli(command="", prompt=""):
    try:
        agy_bin = shutil.which("agy") or shutil.which("agy.exe") or "agy"
        if prompt:
            cmd = [agy_bin, "--print", prompt, "--dangerously-skip-permissions"]
        elif command:
            cmd = [agy_bin] + command.split()
        else:
            cmd = [agy_bin, "--version"]
            
        use_shell = os.name == "nt"
        res = subprocess.run(cmd, cwd=REPO_DIR, capture_output=True, text=True, timeout=60, shell=use_shell)
        out = res.stdout.strip() or res.stderr.strip()
        return {
            "success": res.returncode == 0,
            "output": out or "Команда agy выполнена успешно.",
            "returncode": res.returncode
        }
    except FileNotFoundError:
        return {"success": False, "error": "Antigravity CLI (agy) не найден в PATH сервера."}
    except Exception as ex:
        return {"success": False, "error": str(ex)}

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
    "run_shell_command": tool_run_shell_command,
    "hf_get_status": tool_hf_get_status,
    "hf_restart_space": tool_hf_restart_space,
    "hf_get_file": tool_hf_get_file,
    "hf_update_file": tool_hf_update_file,
    "hf_get_logs": tool_hf_get_logs,
    "generate_ai_image": tool_generate_ai_image,
    "antigravity_cli": tool_antigravity_cli
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

def tg_send_photo(photo_url, caption="", chat_id=ALLOWED_CHAT_ID, reply_to=None, reply_markup=None):
    payload = {"chat_id": chat_id, "photo": photo_url, "caption": caption, "parse_mode": "Markdown"}
    if reply_to:
        payload["reply_to_message_id"] = reply_to
    if reply_markup:
        payload["reply_markup"] = reply_markup
    res = tg_request("sendPhoto", payload)
    if not res or not res.get("ok"):
        payload.pop("parse_mode", None)
        return tg_request("sendPhoto", payload)
    return res

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
    config = load_config()
    mode = config.get("BOT_MODE", "dev")
    mode_btn = "💬 Режим: Чат" if mode == "chat" else "⚡ Режим: Код"
    return {
        "keyboard": [
            [{"text": "🚀 Собрать IPA"}, {"text": "📊 Статус & Билды"}],
            [{"text": mode_btn}, {"text": "🤗 Hugging Face"}],
            [{"text": "🌌 Antigravity CLI"}, {"text": "🔑 Ключи & Квоты"}],
            [{"text": "🧠 Сменить модель"}, {"text": "📦 Мои Скиллы"}]
        ],
        "resize_keyboard": True,
        "persistent": True
    }

def get_antigravity_account_status():
    config = load_config()
    acc_file = Path.home() / ".gemini" / "google_accounts.json"
    creds_file = Path.home() / ".gemini" / "oauth_creds.json"
    
    # 1. Если запущены в облаке (Hugging Face) и есть сохраненные учетные данные в config:
    saved_creds = config.get("ANTIGRAVITY_CREDS")
    if saved_creds and not acc_file.exists():
        try:
            gem_dir = Path.home() / ".gemini"
            gem_dir.mkdir(parents=True, exist_ok=True)
            if saved_creds.get("google_accounts"):
                acc_file.write_text(json.dumps(saved_creds["google_accounts"], indent=2), encoding="utf-8")
            if saved_creds.get("oauth_creds"):
                creds_file.write_text(json.dumps(saved_creds["oauth_creds"], indent=2), encoding="utf-8")
        except Exception:
            pass
            
    account_email = "Не авторизован"
    has_token = False
    expires_in = "Авто-обновление (Active)"
    
    if acc_file.exists():
        try:
            acc_data = json.loads(acc_file.read_text(encoding="utf-8"))
            account_email = acc_data.get("active") or "Не указан"
        except Exception:
            pass
    elif saved_creds and saved_creds.get("email"):
        account_email = saved_creds.get("email")
            
    if creds_file.exists():
        try:
            c_data = json.loads(creds_file.read_text(encoding="utf-8"))
            if c_data.get("access_token") or c_data.get("refresh_token"):
                has_token = True
            exp_ts = c_data.get("expiry_date", 0)
            if exp_ts:
                diff_sec = int((exp_ts / 1000) - time.time())
                if diff_sec > 0:
                    expires_in = f"активен ({diff_sec // 60} мин до refresh)"
                else:
                    expires_in = "авто-обновление токена"
        except Exception:
            pass
    elif saved_creds and saved_creds.get("oauth_creds"):
        has_token = True
        expires_in = "активен в облаке 24/7"
            
    # Check desktop app or cloud mode
    if os.name == "nt":
        app_running = False
        try:
            res = subprocess.run(["tasklist", "/FI", "IMAGENAME eq Antigravity.exe"], capture_output=True, text=True, timeout=5)
            if "Antigravity.exe" in res.stdout:
                app_running = True
        except Exception:
            pass
        app_status_text = "🟢 Запущено на ПК" if app_running else "⚪ Фоновый режим"
    else:
        app_status_text = "🟢 Облачный сервер (24/7)"
        
    return {
        "email": account_email,
        "has_token": has_token,
        "expires_in": expires_in,
        "app_status": app_status_text
    }

def apply_google_oauth_token(raw_input):
    clean_str = raw_input.strip()
    token_val = None
    refresh_token_val = None
    parsed_json = None
    
    if clean_str.startswith("{") and clean_str.endswith("}"):
        try:
            parsed_json = json.loads(clean_str)
            token_val = parsed_json.get("access_token") or parsed_json.get("token")
            refresh_token_val = parsed_json.get("refresh_token")
        except Exception:
            pass
    else:
        token_val = clean_str
        
    if not token_val:
        return {"success": False, "error": "Не удалось распознать токен. Отправьте строку токена или JSON."}
        
    try:
        req = urllib.request.Request(
            "https://www.googleapis.com/oauth2/v3/userinfo",
            headers={"Authorization": f"Bearer {token_val}", "User-Agent": "Sonivo-Agent"}
        )
        with urllib.request.urlopen(req, timeout=12) as resp:
            user_info = json.loads(resp.read().decode())
            email = user_info.get("email") or "siarheismazhankoy@gmail.com"
            name = user_info.get("name") or "Antigravity User"
    except Exception as e:
        if parsed_json and parsed_json.get("refresh_token"):
            email = parsed_json.get("email") or "siarheismazhankoy@gmail.com"
            name = "Antigravity User"
        else:
            return {"success": False, "error": f"Ошибка проверки Google OAuth токена: {e}"}
            
    config = load_config()
    creds_payload = parsed_json.get("oauth_creds") if parsed_json and "oauth_creds" in parsed_json else (parsed_json or {
        "access_token": token_val,
        "refresh_token": refresh_token_val,
        "scope": "openid https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/userinfo.profile https://www.googleapis.com/auth/userinfo.email",
        "token_type": "Bearer",
        "expiry_date": int((time.time() + 3600) * 1000)
    })
    
    acc_payload = {"active": email, "old": []}
    
    config["ANTIGRAVITY_CREDS"] = {
        "email": email,
        "google_accounts": acc_payload,
        "oauth_creds": creds_payload,
        "synced_at": time.strftime("%Y-%m-%d %H:%M:%S")
    }
    save_config(config)
    
    try:
        gem_dir = Path.home() / ".gemini"
        gem_dir.mkdir(parents=True, exist_ok=True)
        (gem_dir / "google_accounts.json").write_text(json.dumps(acc_payload, indent=2), encoding="utf-8")
        (gem_dir / "oauth_creds.json").write_text(json.dumps(creds_payload, indent=2), encoding="utf-8")
    except Exception:
        pass
        
    return {"success": True, "email": email, "name": name}

def sync_local_antigravity_to_config():
    acc_file = Path.home() / ".gemini" / "google_accounts.json"
    creds_file = Path.home() / ".gemini" / "oauth_creds.json"
    
    config = load_config()
    saved = config.get("ANTIGRAVITY_CREDS") or DEFAULT_ANTIGRAVITY_CREDS
    
    if acc_file.exists() and creds_file.exists():
        try:
            acc_data = json.loads(acc_file.read_text(encoding="utf-8"))
            creds_data = json.loads(creds_file.read_text(encoding="utf-8"))
            email = acc_data.get("active") or "siarheismazhankoy@gmail.com"
            config["ANTIGRAVITY_CREDS"] = {
                "email": email,
                "google_accounts": acc_data,
                "oauth_creds": creds_data,
                "synced_at": time.strftime("%Y-%m-%d %H:%M:%S")
            }
            save_config(config)
            return {"success": True, "email": email}
        except Exception:
            pass
            
    # Fallback to bundled credentials if in cloud
    if saved:
        try:
            gem_dir = Path.home() / ".gemini"
            gem_dir.mkdir(parents=True, exist_ok=True)
            if saved.get("google_accounts"):
                (gem_dir / "google_accounts.json").write_text(json.dumps(saved["google_accounts"], indent=2), encoding="utf-8")
            if saved.get("oauth_creds"):
                (gem_dir / "oauth_creds.json").write_text(json.dumps(saved["oauth_creds"], indent=2), encoding="utf-8")
            return {"success": True, "email": saved.get("email", "siarheismazhankoy@gmail.com")}
        except Exception as e:
            return {"success": False, "error": str(e)}
            
    return {"success": False, "error": "Файлы авторизации Antigravity не найдены"}

try:
    import gradio as gr
    HAS_GRADIO = True
except Exception:
    HAS_GRADIO = False

def create_gradio_ui():
    if not HAS_GRADIO:
        return None
    with gr.Blocks(title="Sonivo AI & Antigravity Dashboard") as blk:
        gr.Markdown("# 🌌 Sonivo AI & Antigravity Cloud Dashboard (24/7)")
        
        with gr.Row():
            with gr.Column(scale=1):
                account_box = gr.Textbox(label="👤 Google Аккаунт", value=lambda: get_antigravity_account_status()["email"], interactive=False)
                status_box = gr.Textbox(label="🔑 Статус OAuth", value=lambda: get_antigravity_account_status()["expires_in"], interactive=False)
                server_box = gr.Textbox(label="🖥️ Сервер", value=lambda: get_antigravity_account_status()["app_status"], interactive=False)
                refresh_btn = gr.Button("🔄 Обновить статус", variant="secondary")
                
            with gr.Column(scale=2):
                gr.Markdown("### 🔑 Быстрая авторизация через браузер")
                token_input = gr.Textbox(label="Вставьте Google OAuth токен (ya29...) или JSON oauth_creds.json", placeholder="ya29.a0... или {\"access_token\": ...}", lines=4)
                save_btn = gr.Button("💾 Сохранить и Активировать 24/7", variant="primary")
                result_box = gr.Markdown("")
                
        def on_save(tok):
            if not tok or not tok.strip():
                st = get_antigravity_account_status()
                return "⚠️ Введите токен или JSON", st["email"], st["expires_in"], st["app_status"]
            res = apply_google_oauth_token(tok)
            if res.get("success"):
                config = load_config()
                hf_token = config.get("HF_TOKEN") or os.environ.get("HF_TOKEN")
                hf_space = config.get("HF_SPACE") or os.environ.get("HF_SPACE", "IsseT/sonivo-bot")
                if config.get("ANTIGRAVITY_CREDS") and hf_token:
                    try:
                        url = f'https://huggingface.co/api/spaces/{hf_space}/secrets'
                        secret_payload = {'key': 'ANTIGRAVITY_CREDS_JSON', 'value': json.dumps(config["ANTIGRAVITY_CREDS"])}
                        req = urllib.request.Request(url, data=json.dumps(secret_payload).encode('utf-8'), headers={'Authorization': f'Bearer {hf_token}', 'Content-Type': 'application/json', 'User-Agent': 'Sonivo-Agent'})
                        urllib.request.urlopen(req, timeout=10)
                    except Exception as ex:
                        print(f"[HF Secret Sync Error]: {ex}")

                tg_send(f"🎉 *Google Antigravity авторизован через Веб-дашборд!*\n• Аккаунт: `{res.get('email', 'OK')}`\n• Режим: 🟢 Облачный сервер (24/7)\n\nСессия сохранена в постоянных секретах Hugging Face!")
                st = get_antigravity_account_status()
                return f"✅ **Успешно авторизован:** `{res.get('email')}`! Сессия сохранена в облаке 24/7.", st["email"], st["expires_in"], st["app_status"]
            else:
                st = get_antigravity_account_status()
                return f"❌ **Ошибка:** {res.get('error')}", st["email"], st["expires_in"], st["app_status"]

        def on_refresh():
            st = get_antigravity_account_status()
            return st["email"], st["expires_in"], st["app_status"]

        save_btn.click(on_save, inputs=[token_input], outputs=[result_box, account_box, status_box, server_box])
        refresh_btn.click(on_refresh, outputs=[account_box, status_box, server_box])
        
    return blk

demo = create_gradio_ui()

class AntigravityWebHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass
        
    def do_GET(self):
        st = get_antigravity_account_status()
        auth_color = "#10b981" if st["has_token"] else "#ef4444"
        auth_text = "🟢 Авторизован (24/7)" if st["has_token"] else "🔴 Не авторизован"
        
        html = f"""<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="utf-8">
    <title>Sonivo AI & Google Antigravity Auth</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
        * {{ box-sizing: border-box; }}
        body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; background: #0b0f19; color: #f1f5f9; padding: 2rem 1rem; margin: 0; display: flex; justify-content: center; }}
        .container {{ width: 100%; max-width: 680px; }}
        .card {{ background: #161e2e; border-radius: 16px; padding: 1.75rem; border: 1px solid #27354a; margin-bottom: 1.5rem; }}
        h1 {{ font-size: 1.5rem; margin-top: 0; color: #38bdf8; }}
        h2 {{ font-size: 1.2rem; margin-top: 0; color: #93c5fd; }}
        .status-badge {{ display: inline-block; padding: 0.35rem 0.85rem; border-radius: 9999px; font-weight: 600; font-size: 0.85rem; background: {auth_color}; color: white; }}
        .info-row {{ margin: 0.75rem 0; font-size: 0.95rem; }}
        code {{ background: #0f172a; padding: 0.2rem 0.5rem; border-radius: 6px; font-family: monospace; color: #38bdf8; }}
        textarea {{ width: 100%; height: 130px; background: #0b0f19; border: 1px solid #334155; border-radius: 10px; color: #f8fafc; padding: 0.85rem; font-family: monospace; font-size: 0.85rem; }}
        button {{ background: #2563eb; color: white; border: none; padding: 0.85rem 1.75rem; border-radius: 10px; font-weight: 600; cursor: pointer; margin-top: 0.75rem; width: 100%; }}
    </style>
</head>
<body>
    <div class="container">
        <div class="card">
            <h1>🌌 Sonivo AI & Antigravity Cloud</h1>
            <div class="info-row"><strong>Статус сессии:</strong> <span class="status-badge">{auth_text}</span></div>
            <div class="info-row"><strong>Google Аккаунт:</strong> <code>{st['email']}</code></div>
            <div class="info-row"><strong>Время жизни токена:</strong> <code>{st['expires_in']}</code></div>
            <div class="info-row"><strong>Сервер:</strong> <code>{st['app_status']}</code></div>
        </div>

        <div class="card">
            <h2>🔑 Авторизация в 1 клик</h2>
            <form method="POST" action="/save_token">
                <textarea name="token_data" placeholder="Вставьте токен (ya29...) или JSON сюда..." required></textarea>
                <button type="submit">💾 Сохранить и Активировать 24/7</button>
            </form>
        </div>
    </div>
</body>
</html>"""
        self.send_response(200)
        self.send_header("Content-type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(html.encode("utf-8"))

    def do_POST(self):
        if self.path == "/save_token":
            content_length = int(self.headers.get('Content-Length', 0))
            post_data = self.rfile.read(content_length).decode('utf-8')
            params = urllib.parse.parse_qs(post_data)
            raw_token = params.get("token_data", [""])[0]
            res = apply_google_oauth_token(raw_token)
            
            tg_send(f"🎉 *Google Antigravity авторизован через Браузер!*\n• Аккаунт: `{res.get('email', 'OK')}`\n• Режим: 🟢 Облачный сервер (24/7)")
            
            self.send_response(200)
            self.send_header("Content-type", "text/html; charset=utf-8")
            self.end_headers()
            status_title = "✅ Авторизация успешна!" if res.get("success") else "❌ Ошибка"
            resp_html = f"<!DOCTYPE html><html><body style='background:#0b0f19;color:#fff;text-align:center;padding:3rem;'><h2>{status_title}</h2><p><a href='/' style='color:#38bdf8;'>← Вернуться</a></p></body></html>"
            self.wfile.write(resp_html.encode("utf-8"))

def show_antigravity_menu(chat_id, reply_to=None):
    st = get_antigravity_account_status()
    version_res = tool_antigravity_cli("--version")
    ver_str = version_res.get("output", "1.1.23")
    
    auth_icon = "🟢" if st["has_token"] else "🔴"
    
    text = (
        "🌌 *Google Antigravity Desktop & Cloud 24/7 Dashboard*\n"
        "━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
        f"👤 *Google Аккаунт:* `{st['email']}`\n"
        f"🔑 *OAuth Авторизация:* {auth_icon} *{'Активна (24/7)' if st['has_token'] else 'Не авторизован'}*\n"
        f"⏳ *Статус сессии:* `{st['expires_in']}`\n"
        f"🖥️ *Режим работы:* {st['app_status']}\n"
        f"⚙️ *Версия движка CLI:* `{ver_str}`\n"
        "━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
        "📦 *Доступные модели Antigravity:*\n"
        "• 🧠 `Claude Sonnet 4.6 (Thinking)`\n"
        "• 🧠 `Claude Opus 4.6 (Thinking)`\n"
        "• ⚡ `Gemini 3.7 Flash (High / Med / Low)`\n"
        "• ⚡ `Gemini 3.6 Flash (High / Med / Low)`\n"
        "• 💎 `Gemini 3.1 Pro (High / Low)`\n"
        "• 🌐 `GPT-OSS 120B (Medium)`\n"
        "━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
        "💡 *Работа 24/7:* Нажмите кнопку ниже, чтобы открыть веб-страницу авторизации в браузере или вставить токен прямо в чат!"
    )
    inline_kb = {
        "inline_keyboard": [
            [{"text": "🌐 1. Открыть Веб-вход в браузере", "url": "https://huggingface.co/spaces/IsseT/sonivo-bot"}],
            [{"text": "📝 2. Вставить токен в чат", "callback_data": "agy_browser_login"}, {"text": "🔄 Обновить статус", "callback_data": "agy_refresh"}],
            [{"text": "🧠 Модели Antigravity", "callback_data": "agy_models"}, {"text": "🤖 Субагенты", "callback_data": "agy_agents"}],
            [{"text": "🔌 Плагины Antigravity", "callback_data": "agy_plugins"}, {"text": "🌌 Сделать моделью по умолчанию", "callback_data": "model_antigravity"}]
        ]
    }
    tg_send(text, chat_id=chat_id, reply_to=reply_to, reply_markup=inline_kb)

def show_hf_menu(chat_id, reply_to=None):
    token, space = get_hf_config()
    masked_tok = token[:6] + "..." + token[-4:] if len(token) > 10 else "❌ Не установлен"
    
    text = "🤗 *Админ-панель сервера Hugging Face*\n\n"
    text += f"• **Space**: `{space}`\n"
    text += f"• **HF Token**: `{masked_tok}`\n\n"
    text += "Управляйте облачным сервером бота прямо отсюда: перезагружайте Space, проверяйте статус и редактируйте `app.py` без браузера!"
    
    inline_kb = {
        "inline_keyboard": [
            [{"text": "📊 Проверить статус", "callback_data": "hf_status"}, {"text": "🔄 Перезапустить Space", "callback_data": "hf_restart"}],
            [{"text": "📋 Логи Container (Run)", "callback_data": "hf_logs_run"}, {"text": "🛠️ Логи Build", "callback_data": "hf_logs_build"}],
            [{"text": "📝 Посмотреть app.py", "callback_data": "hf_view_app"}, {"text": "✏️ Изменить app.py", "callback_data": "hf_edit_app"}],
            [{"text": "🔑 Указать HF Token", "callback_data": "hf_set_token"}, {"text": "🏷️ Сменить имя Space", "callback_data": "hf_set_space"}]
        ]
    }
    tg_send(text, chat_id=chat_id, reply_to=reply_to, reply_markup=inline_kb)

def show_mode_menu(chat_id, reply_to=None):
    config = load_config()
    mode = config.get("BOT_MODE", "dev")
    text = "⚙️ *Выбор режима работы AI-агента*\n\n"
    if mode == "chat":
        text += "Текущий режим: 💬 *Личный Чат / Консультант*\n\n"
        text += "• В этом режиме бот отвечает на любые вопросы, генерирует код в чате, обсуждает идеи и архитектуру, но *не меняет файлы в репозитории и не делает коммиты*.\n"
    else:
        text += "Текущий режим: ⚡ *Автономный Разработчик*\n\n"
        text += "• В этом режиме бот активно ищет файлы, редактирует код, делает git commit & push и запускает сборку IPA.\n"
        
    inline_kb = {
        "inline_keyboard": [
            [{"text": f"{'✅ ' if mode=='dev' else ''}⚡ Режим Разработчика (Правки в код)", "callback_data": "mode_dev"}],
            [{"text": f"{'✅ ' if mode=='chat' else ''}💬 Режим Чата (Вопросы & Идеи)", "callback_data": "mode_chat"}]
        ]
    }
    tg_send(text, chat_id=chat_id, reply_to=reply_to, reply_markup=inline_kb)

# --- МУЛЬТИ-ПРОВАЙДЕРНЫЙ AI ДВИЖОК (Gemini, DeepSeek, OpenRouter, Groq, OpenAI) ---

def get_openai_tools():
    openai_tools = []
    for decl in TOOL_DECLARATIONS:
        props = {}
        for k, v in decl.get("parameters", {}).get("properties", {}).items():
            props[k] = {
                "type": v.get("type", "string").lower(),
                "description": v.get("description", "")
            }
        openai_tools.append({
            "type": "function",
            "function": {
                "name": decl["name"],
                "description": decl["description"],
                "parameters": {
                    "type": "object",
                    "properties": props,
                    "required": decl.get("parameters", {}).get("required", [])
                }
            }
        })
    return openai_tools

def gemini_contents_to_openai_messages(contents, system_prompt):
    messages = [{"role": "system", "content": system_prompt}]
    for c in contents:
        role = c.get("role")
        parts = c.get("parts", [])
        
        if role == "user":
            func_resps = [p["functionResponse"] for p in parts if "functionResponse" in p]
            if func_resps:
                for fr in func_resps:
                    content_str = json.dumps(fr.get("response", {}).get("content", {}), ensure_ascii=False)
                    messages.append({
                        "role": "tool",
                        "tool_call_id": fr.get("name", "call_1"),
                        "content": content_str
                    })
            else:
                text_parts = [p.get("text", "") for p in parts if "text" in p]
                if text_parts:
                    messages.append({"role": "user", "content": "\n".join(text_parts)})
        elif role == "model":
            func_calls = [p["functionCall"] for p in parts if "functionCall" in p]
            text_parts = [p.get("text", "") for p in parts if "text" in p]
            msg = {"role": "assistant"}
            if text_parts:
                msg["content"] = "\n".join(text_parts)
            if func_calls:
                t_calls = []
                for idx, fc in enumerate(func_calls):
                    t_calls.append({
                        "id": fc.get("name", f"call_{idx+1}"),
                        "type": "function",
                        "function": {
                            "name": fc.get("name"),
                            "arguments": json.dumps(fc.get("args", {}))
                        }
                    })
                msg["tool_calls"] = t_calls
            messages.append(msg)
    return messages

def call_openai_compatible(base_url, api_key, model, messages):
    url = base_url.rstrip("/") + "/chat/completions"
    payload = {
        "model": model,
        "messages": messages,
        "tools": get_openai_tools(),
        "tool_choice": "auto",
        "temperature": 0.2
    }
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "x-api-key": str(api_key),
            "Content-Type": "application/json",
            "User-Agent": "Sonivo-Agent"
        }
    )
    with urllib.request.urlopen(req, timeout=90) as resp:
        data = json.loads(resp.read().decode())
        choice = data.get("choices", [{}])[0]
        msg = choice.get("message", {})
        
        parts = []
        # If model returned reasoning / think block
        reasoning = msg.get("reasoning_content") or msg.get("reasoning")
        content_text = msg.get("content") or ""
        
        if content_text:
            parts.append({"text": content_text})
        elif reasoning and not msg.get("tool_calls"):
            parts.append({"text": reasoning})
        
        for tc in msg.get("tool_calls", []):
            fn = tc.get("function", {})
            fn_name = fn.get("name")
            try:
                fn_args = json.loads(fn.get("arguments", "{}"))
            except Exception:
                fn_args = {}
            parts.append({
                "functionCall": {
                    "name": fn_name,
                    "args": fn_args
                }
            })
            
        return {
            "candidates": [
                {
                    "content": {
                        "role": "model",
                        "parts": parts
                    }
                }
            ]
        }

def select_best_model_and_key(keys, has_media=False, is_video=False):
    now = time.time()
    
    # 1. Приоритет при анализе Фото / Видео / Скриншотов (Vision & Multimodal)
    if is_video or has_media:
        vision_models = [
            "gemini-3.7-flash",
            "gemini-3.6-flash",
            "gemini-3.5-flash",
            "gemini-3.5-flash-lite",
            "gemini-3.1-flash-lite",
            "gemini-2.5-flash",
            "gemini-3.1-pro-preview",
            "gemini-2.5-pro",
            "claude-vision",
            "gpt-4o"
        ]
        for target_m in vision_models:
            for k in keys:
                if k.get("cooldown_until", 0) > now:
                    continue
                if k.get("provider") == "gemini":
                    return k, target_m if target_m.startswith("gemini") else "gemini-3.7-flash"
                available = k.get("available_models", [])
                if k.get("model") == target_m or target_m in available:
                    return k, target_m

    # 2. Приоритет для глубоких рассуждений, архитектуры и кодинга (Reasoning & Agents)
    reasoning_priorities = [
        "deepseek-reasoner",
        "deepseek/deepseek-r1",
        "deepseek/deepseek-r1:free",
        "claude-3.7-sonnet",
        "claude-3.5-sonnet",
        "claude-expert",
        "gemini-3.7-flash",
        "gemini-3.1-pro-preview",
        "gemini-2.5-pro",
        "deep-research-pro-preview",
        "antigravity",
        "deepseek-coder",
        "qwen/qwen-2.5-coder-32b-instruct",
        "qwen-2.5-coder",
        "deepseek-chat",
        "gpt-4o",
        "gemini-3.6-flash",
        "gemini-3.5-flash",
        "gemini-3.5-flash-lite",
        "gemini-3.1-flash-lite",
        "gemma-4-31b",
        "gemma-4-26b",
        "claude-instant",
        "gemini-3-flash",
        "gemini-2.5-flash",
        "gemini-2.5-flash-lite",
        "gemini-2.0-flash",
        "gemini-2.0-flash-lite",
        "llama-3.3-70b-versatile",
        "meta-llama/llama-3.3-70b-instruct:free"
    ]
    for target_m in reasoning_priorities:
        for k in keys:
            if k.get("cooldown_until", 0) > now:
                continue
            available = k.get("available_models", [])
            if k.get("model") == target_m or target_m in available:
                return k, target_m
            if k.get("provider") == "gemini" and (target_m.startswith("gemini") or target_m.startswith("gemma") or target_m in ["antigravity", "deep-research-pro-preview"]):
                return k, target_m

    for k in keys:
        if k.get("cooldown_until", 0) <= now:
            return k, k.get("model") or "gemini-3.6-flash"
    return keys[0] if keys else None, "gemini-3.6-flash"

def call_ai_with_fallback(contents, chat_id=None, has_media=False, is_video=False):
    keys = get_keys()
    if not keys:
        return {"error": "Нет добавленных ключей API! Нажмите '🔑 Ключи & Квоты' и добавьте ключ Gemini, DeepSeek или OpenRouter."}
        
    system_prompt = build_system_prompt()
    config = load_config()
    active_model = config.get("ACTIVE_MODEL", "auto")
    now = time.time()
    
    # Intelligent Auto-Selection with Media & Cost awareness
    if active_model == "auto" or has_media or is_video:
        best_k, best_m = select_best_model_and_key(keys, has_media=has_media, is_video=is_video)
        sorted_keys = [best_k] + [k for k in keys if k != best_k] if best_k else keys
        auto_target_model = best_m
    else:
        def get_priority(k):
            av = k.get("available_models", [])
            if k.get("model") == active_model or active_model in av:
                return 0
            if k.get("provider") == "gemini" and ("gemini" in active_model or "gemma" in active_model):
                return 1
            return 2
        sorted_keys = sorted(keys, key=get_priority)
        auto_target_model = active_model

    for key_entry in sorted_keys:
        if not key_entry or key_entry.get("cooldown_until", 0) > now:
            continue
            
        key_val = key_entry.get("key")
        key_id = key_entry.get("id")
        key_name = key_entry.get("name")
        provider = key_entry.get("provider", "gemini")
        base_url = key_entry.get("base_url") or "https://api.deepseek.com"
        
        av_models = key_entry.get("available_models", [])
        if active_model == "auto":
            target_model = auto_target_model
        elif active_model in av_models or key_entry.get("model") == active_model:
            target_model = active_model
        elif av_models:
            target_model = av_models[0]
        else:
            target_model = key_entry.get("model") or ("gemini-3.6-flash" if provider == "gemini" else "deepseek-chat")
        
        if provider == "gemini":
            # Полная цепочка каскада по квотам (от топ-логики до безлимитных 14.4k RPD)
            gemini_cascade = [
                target_model,
                "gemini-3.7-flash",
                "gemini-3.6-flash",
                "gemini-3.5-flash",
                "gemini-3.5-flash-lite",
                "gemini-3.1-flash-lite",
                "gemma-4-31b",
                "gemma-4-26b",
                "gemini-2.5-flash",
                "gemini-2.5-flash-lite",
                "gemini-2.0-flash",
                "gemini-3.1-pro-preview",
                "gemini-2.5-pro"
            ]
            seen_m = set()
            models_to_try = []
            for m in gemini_cascade:
                if m and m not in seen_m:
                    seen_m.add(m)
                    models_to_try.append(m)

            for m in models_to_try:
                url = f"https://generativelanguage.googleapis.com/v1beta/models/{m}:generateContent?key={key_val}"
                gen_cfg = {"temperature": 0.2}
                if "3.7" in m or "thinking" in m:
                    gen_cfg["thinkingConfig"] = {"thinkingBudget": 2048}
                    
                payload = {
                    "contents": contents,
                    "systemInstruction": {"parts": [{"text": system_prompt}]},
                    "tools": [{"functionDeclarations": TOOL_DECLARATIONS}],
                    "generationConfig": gen_cfg
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
                        data["_provider_name"] = f"Gemini ({m})"
                        # Extract thoughts from Gemini parts if present
                        for cand in data.get("candidates", []):
                            for p in cand.get("content", {}).get("parts", []):
                                if p.get("thought"):
                                    data["_reasoning"] = p["thought"]
                        return data
                except urllib.error.HTTPError as e:
                    err_body = e.read().decode()
                    print(f"[Gemini HTTP {e.code} on model '{m}' / key '{key_name}']: {err_body}")
                    # В Gemini квоты РАЗДЕЛЬНЫЕ для каждой модели! При 429 продолжаем пробовать следующую модель с более высокой квотой (Lite / Gemma)
                    continue
                except Exception as e:
                    print(f"[Gemini Connection Error on '{m}' / '{key_name}']: {e}")
                    continue

            # Если ВСЕ модели на этом ключе исчерпаны:
            record_key_exhausted(key_id, cooldown_seconds=60)
            continue
        else:
            # OpenAI-compatible API (DeepSeek, OpenRouter, Groq, Custom API, deeperseeker)
            try:
                openai_messages = gemini_contents_to_openai_messages(contents, system_prompt)
                data = call_openai_compatible(base_url, key_val, target_model, openai_messages)
                record_key_success(key_id)
                data["_provider_name"] = f"{provider.capitalize()} ({target_model})"
                return data
            except urllib.error.HTTPError as e:
                err_body = e.read().decode()
                print(f"[{provider.capitalize()} HTTP {e.code} / {key_name}]: {err_body}")
                record_key_exhausted(key_id, cooldown_seconds=60)
                continue
            except Exception as e:
                print(f"[{provider.capitalize()} Error / {key_name}]: {e}")
                continue
                
    # Аварийный прогон: пробуем сверхлимитные Gemma 4 / Flash Lite игнорируя кулдауны
    for k in keys:
        if k.get("provider") == "gemini":
            k_val = k.get("key")
            for em_m in ["gemma-4-31b", "gemma-4-26b", "gemini-3.5-flash-lite", "gemini-3.1-flash-lite", "gemini-2.5-flash"]:
                try:
                    url = f"https://generativelanguage.googleapis.com/v1beta/models/{em_m}:generateContent?key={k_val}"
                    payload = {
                        "contents": contents,
                        "systemInstruction": {"parts": [{"text": system_prompt}]},
                        "tools": [{"functionDeclarations": TOOL_DECLARATIONS}],
                        "generationConfig": {"temperature": 0.2}
                    }
                    req = urllib.request.Request(url, data=json.dumps(payload).encode("utf-8"), headers={"Content-Type": "application/json"})
                    with urllib.request.urlopen(req, timeout=90) as resp:
                        data = json.loads(resp.read().decode())
                        data["_provider_name"] = f"Gemini High-Quota ({em_m})"
                        return data
                except Exception:
                    continue

    return {"error": "Все доступные модели и ключи API исчерпали свои квоты. Добавьте ещё один ключ через '🔑 Ключи & Квоты'."}

def execute_agent_loop(user_input, status_msg_id, chat_id):
    has_media = False
    is_video = False
    if isinstance(user_input, list):
        history = [{"role": "user", "parts": user_input}]
        for p in user_input:
            if "inlineData" in p:
                has_media = True
                if "video" in p["inlineData"].get("mimeType", ""):
                    is_video = True
    else:
        history = [{"role": "user", "parts": [{"text": str(user_input)}]}]
        
    config = load_config()
    mode = config.get("BOT_MODE", "dev")
    role_title = "Sonivo AI Консультант" if mode == "chat" else "Sonivo AI Разработчик"
    
    committed = False
    max_steps = 15
    for step in range(max_steps):
        response = call_ai_with_fallback(history, chat_id=chat_id, has_media=has_media, is_video=is_video)
        if "error" in response:
            return {"text": f"❌ Ошибка API: {response['error']}", "committed": False}
        
        provider_name = response.get("_provider_name", "AI Engine")
        reasoning_text = response.get("_reasoning", "")
        candidates = response.get("candidates", [])
        if not candidates:
            return {"text": "❌ Модель вернула пустой ответ.", "committed": False}
        
        candidate = candidates[0]
        content = candidate.get("content", {})
        parts = content.get("parts", [])
        
        # Check and extract <think> tags from text parts
        for p in parts:
            t = p.get("text", "")
            if "<think>" in t and "</think>" in t:
                s_idx = t.find("<think>") + 7
                e_idx = t.find("</think>")
                if not reasoning_text:
                    reasoning_text = t[s_idx:e_idx].strip()
                p["text"] = (t[:s_idx-7] + t[e_idx+8:]).strip()
                
        history.append(content)
        
        function_calls = [p["functionCall"] for p in parts if "functionCall" in p]
        
        if not function_calls:
            text_parts = [p.get("text", "") for p in parts if "text" in p and p.get("text")]
            final_text = "\n".join(text_parts)
            
            # Если пользователь прислал медиа, а модель была не в авто-режиме, предлагаем переключение
            if has_media and config.get("ACTIVE_MODEL") not in ["auto", "gemini-3.7-flash"]:
                final_text += "\n\n💡 *Совет по экономии & качеству:* Для фото и видео рекомендуется включить `Gemini 3.7 Flash (Vision)` через меню *🧠 Сменить модель*."
                
            return {"text": final_text, "committed": committed}
        
        response_parts = []
        for fc in function_calls:
            name = fc.get("name")
            args = fc.get("args", {})
            
            if mode == "chat" and name in ["edit_file", "create_or_overwrite_file", "git_commit_and_push"]:
                action_desc = f"💡 [Чат] Анализирую структуру `{name}`..."
                result = {"info": "Changes skipped because agent is in Chat/Consultation mode. Provide advice/code in text response instead."}
            else:
                action_desc = f"⚙️ Выполняю `{name}`..."
                if name == "read_file":
                    action_desc = f"📖 Читаю `{args.get('file_path')}`..."
                elif name == "search_code":
                    action_desc = f"🔍 Ищу по коду: `{args.get('query')}`..."
                elif name == "edit_file":
                    action_desc = f"✏️ Редактирую `{args.get('file_path')}`..."
                elif name == "create_or_overwrite_file":
                    action_desc = f"📄 Создаю/перезаписываю `{args.get('file_path')}`..."
                elif name == "git_commit_and_push":
                    action_desc = f"🚀 Отправляю коммит: *{args.get('commit_message')}*..."
                elif name == "check_ci_build":
                    action_desc = "🔍 Проверяю статус сборки IPA в GitHub Actions..."
                elif name == "trigger_ipa_build":
                    action_desc = "🚀 Запускаю компиляцию IPA на macOS runner..."
                elif name == "generate_ai_image":
                    action_desc = f"🎨 Генерирую изображение по запросу: '{args.get('prompt')[:40]}...'..."
                
                # Реальное отображение прогресса и мышления (Reasoning) в Telegram
                if status_msg_id:
                    status_text = f"🤖 *{role_title}* (Шаг {step+1}/{max_steps})\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
                    status_text += f"⚙️ *Модель:* `{provider_name}`\n"
                    if reasoning_text:
                        r_preview = reasoning_text.replace("\n", " ").strip()
                        if len(r_preview) > 300:
                            r_preview = r_preview[:300] + "..."
                        status_text += f"💭 *Мысли модели (Reasoning):*\n_{r_preview}_\n\n"
                    status_text += f"⚡ *Действие:* {action_desc}"
                    tg_edit(status_text, chat_id, status_msg_id)
                
                tool_func = TOOL_MAP.get(name)
                if tool_func:
                    try:
                        result = tool_func(**args)
                        if name == "git_commit_and_push" and result.get("success"):
                            committed = True
                            
                        # Отправляем предпросмотр изменений в реальном времени!
                        if name == "edit_file" and result.get("success"):
                            rep_snip = args.get("replacement_content", "").strip()
                            if len(rep_snip) > 400:
                                rep_snip = rep_snip[:400] + "\n// ... (остальной код обновлен)"
                            diff_msg = f"✏️ *Внесены правки в* `{args.get('file_path')}`:\n```swift\n{rep_snip}\n```"
                            tg_send(diff_msg, chat_id=chat_id)
                        elif name == "create_or_overwrite_file" and result.get("success"):
                            tg_send(f"📄 *Создан/обновлен файл* `{args.get('file_path')}`", chat_id=chat_id)
                            
                    except Exception as ex:
                        result = {"error": str(ex)}
                else:
                    result = {"error": f"Unknown tool: {name}"}
            
            response_parts.append({
                "functionResponse": {
                    "name": name,
                    "response": {
                        "name": name,
                        "content": result
                    }
                }
            })
            
        history.append({
            "role": "user",
            "parts": response_parts
        })
        
    return {"text": "⚠️ Достигнут лимит шагов (15). Завершаю сессию.", "committed": committed}

# --- ОБРАБОТЧИКИ МЕНЮ И КОМАНД ---

def show_keys_menu(chat_id, reply_to=None, show_full_keys=False):
    keys = get_keys()
    now = time.time()
    
    text = "🔑 *Пул ключей и AI-провайдеров*\n\n"
    if not keys:
        text += "_У вас пока нет добавленных ключей!_\n"
    else:
        for k in keys:
            k_id = k.get("id")
            k_name = k.get("name")
            k_val = k.get("key", "")
            provider = k.get("provider", "gemini").capitalize()
            model = k.get("model", "auto")
            available = k.get("available_models", [])
            base_url = k.get("base_url", "")
            
            if show_full_keys:
                key_display = f"`{k_val}`"
            else:
                key_display = f"`{k_val[:6]}...{k_val[-4:]}`" if len(k_val) > 10 else "`***`"
                
            status = k.get("status", "active")
            cooldown = max(0, int(k.get("cooldown_until", 0) - now))
            
            p_icon = "🟢" if provider.lower() == "gemini" else ("🐳" if provider.lower() == "deepseek" else "🌐")
            status_icon = "🟢 Активен"
            if cooldown > 0:
                status_icon = f"⏳ Кулдаун ({cooldown} сек)"
            elif status != "active":
                status_icon = "🔴 Ошибка"
                
            req_today = k.get("requests_today", 0)
            req_total = k.get("requests_total", 0)
            
            text += f"{p_icon} *{k_name}* [{provider}]\n"
            text += f"• Модель: `{model}`"
            if len(available) > 1:
                text += f" (Всего подключено моделей: *{len(available)}*)"
            text += "\n"
            if base_url and "generativelanguage" not in base_url:
                text += f"• Base URL: `{base_url}`\n"
            text += f"• API-ключ: {key_display} | {status_icon}\n"
            text += f"• Запросов сегодня: `{req_today}` (Всего: `{req_total}`)\n\n"
            
    text += "💡 *Авто-подхват моделей и Failover:*\n"
    text += "Вы можете добавить неограниченное число любых провайдеров. Бот автоматически подгружает все их модели (включая бесплатные :free) и переключается между ними!\n\n"
    text += "• `/add_custom <KEY> <BASE_URL> [all|free|top|MODEL] [NAME]`\n"
    text += "• Или выберите действие в меню ниже:"
    
    toggle_btn = {"text": "🙈 Скрыть ключи", "callback_data": "btn_hide_keys"} if show_full_keys else {"text": "👁️ Показать полные ключи", "callback_data": "btn_show_full_keys"}
    
    inline_kb = {
        "inline_keyboard": [
            [{"text": "➕ Добавить DeepSeek", "callback_data": "key_add_deepseek"}, {"text": "➕ Добавить Gemini", "callback_data": "key_add_gemini"}],
            [{"text": "➕ Добавить OpenRouter", "callback_data": "key_add_openrouter"}, {"text": "➕ Добавить Groq", "callback_data": "key_add_groq"}],
            [{"text": "⚡ Подключить deeperseeker (Free)", "callback_data": "key_add_deeperseeker"}, {"text": "📖 Гайд deeperseeker", "callback_data": "cmd_deeperseeker_guide"}],
            [{"text": "⚙️ Добавить Custom Provider (URL + Ключ)", "callback_data": "key_add_custom"}],
            [toggle_btn, {"text": "🔄 Проверить всё (Live Test)", "callback_data": "btn_validate_all_keys"}]
        ]
    }
    tg_send(text, chat_id=chat_id, reply_to=reply_to, reply_markup=inline_kb)

def show_deeperseeker_guide(chat_id, reply_to=None):
    guide = (
        "⚡ *Инструкция: Бесплатный DeepSeek через DeeperSeeker в Sonivo Bot*\n\n"
        "*Что это:* `deeperseeker` — локальный reverse-proxy, который берет веб-версию `chat.deepseek.com` и делает из неё полноценный OpenAI API без лимитов и оплат!\n\n"
        "━━━━━━━━━━━━━━━━━━━━━━\n"
        "🛠 *Шаг 1: Запуск deeperseeker на компьютере*\n"
        "```bash\n"
        "git clone https://github.com/AmanCode22/deeperseeker\n"
        "cd deeperseeker\n"
        "pip install -r requirements.txt\n"
        "playwright install chromium\n"
        "python3 app.py\n"
        "```\n"
        "*(Дашборд откроется на http://localhost:4000)*\n\n"
        "━━━━━━━━━━━━━━━━━━━━━━\n"
        "🔑 *Шаг 2: Получение токена chat.deepseek.com*\n"
        "1. Откройте режим **Инкогнито** в браузере ➔ [chat.deepseek.com](https://chat.deepseek.com) ➔ авторизуйтесь.\n"
        "2. Нажмите **F12** (или Cmd+Option+I) ➔ вкладка **Console** ➔ выполните команду:\n"
        "```javascript\n"
        'JSON.parse(localStorage.getItem("userToken")).value\n'
        "```\n"
        "3. Скопируйте строку токена без кавычек и закройте инкогнито (не нажимайте выход из аккаунта!).\n"
        "4. Откройте `http://localhost:4000/` (логин/пароль: `admin`/`admin`) ➔ нажмите **Add Auth Token** ➔ вставьте токен (статус станет `ACTIVE`).\n\n"
        "━━━━━━━━━━━━━━━━━━━━━━\n"
        "📱 *Шаг 3: Подключение к нашему Telegram-боту*\n"
        "Отправьте команду:\n"
        "```text\n"
        "/add_custom dseeker http://localhost:4000/v1 all DeeperSeeker\n"
        "```\n"
        "Или нажмите кнопку **⚡ Подключить deeperseeker** ниже!"
    )
    inline_kb = {
        "inline_keyboard": [
            [{"text": "⚡ Подключить deeperseeker сейчас", "callback_data": "key_add_deeperseeker"}],
            [{"text": "🔑 Меню ключей и провайдеров", "callback_data": "btn_refresh_keys"}]
        ]
    }
    tg_send(guide, chat_id=chat_id, reply_to=reply_to, reply_markup=inline_kb)

def validate_all_keys(chat_id=None):
    keys = get_keys()
    if not keys:
        if chat_id:
            tg_send("⚠️ В пуле пока нет ключей для проверки.", chat_id=chat_id)
        return
        
    if chat_id:
        tg_send("⏳ *Проверяю подключение ко всем AI-провайдерам и запрашиваю модели...*", chat_id=chat_id)
    report = "🔍 *Отчет о проверке провайдеров и ключей:*\n\n"
    for k in keys:
        k_name = k.get("name")
        k_prov = k.get("provider", "gemini")
        k_key = k.get("key", "")
        k_url = k.get("base_url")
        
        res = test_and_discover_models(k_url, k_key, k_prov)
        if res.get("valid"):
            k["status"] = "active"
            models_found = res.get("models", [])
            free_found = res.get("free_models", [])
            report += f"🟢 *{k_name}* [{k_prov.capitalize()}]: *Рабочий (200 OK)*\n"
            if models_found:
                k["available_models"] = models_found
                report += f"  • Найдено моделей: *{len(models_found)}* (Бесплатных: *{len(free_found)}*)\n"
        else:
            err_msg = res.get("error", "Неизвестная ошибка")
            report += f"🔴 *{k_name}* [{k_prov.capitalize()}]: *Ошибка доступа*\n"
            report += f"  • Причина: {err_msg}\n"
        report += "\n"
        
    config = load_config()
    config["AI_KEYS"] = keys
    config["GEMINI_KEYS"] = keys
    save_config(config)
    
    if chat_id:
        tg_send(report, chat_id=chat_id)

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
        
    text += "💡 *Скиллы* — это специализированные файлы правил, стилей и архитектуры (`.md`, `.txt`).\n\n"
    text += "Чтобы загрузить новый скилл, нажмите кнопку ниже:"
    
    inline_kb = {
        "inline_keyboard": [
            [{"text": "➕ Загрузить файл скилла", "callback_data": "btn_add_skill"}]
        ]
    }
    tg_send(text, chat_id=chat_id, reply_to=reply_to, reply_markup=inline_kb)

def show_model_menu(chat_id, reply_to=None):
    config = load_config()
    current = config.get("ACTIVE_MODEL", "auto")
    keys = get_keys()
    
    gemini_defaults = [
        # 🧠 Рассуждения и Архитектура
        ("gemini-3.7-flash", "Gemini 3.7 Flash [Reasoning]", "reasoning"),
        ("gemini-3.1-pro-preview", "Gemini 3.1 Pro [Heavy Logic]", "reasoning"),
        ("gemini-2.5-pro", "Gemini 2.5 Pro", "reasoning"),
        ("deep-research-pro-preview", "Deep Research Pro Preview", "reasoning"),
        ("antigravity", "Antigravity Agent", "reasoning"),
        
        # ⚡ Высокий суточный лимит (500 - 14,400 RPD) & Экономия
        ("gemini-3.5-flash-lite", "Gemini 3.5 Flash Lite (500 RPD)", "high_limit"),
        ("gemini-3.1-flash-lite", "Gemini 3.1 Flash Lite (500 RPD)", "high_limit"),
        ("gemma-4-31b", "Gemma 4 31B (14.4k RPD)", "high_limit"),
        ("gemma-4-26b", "Gemma 4 26B (14.4k RPD)", "high_limit"),
        ("gemini-3.6-flash", "Gemini 3.6 Flash", "high_limit"),
        ("gemini-3.5-flash", "Gemini 3.5 Flash", "high_limit"),
        ("gemini-3-flash", "Gemini 3 Flash", "high_limit"),
        ("gemini-2.5-flash", "Gemini 2.5 Flash", "high_limit"),
        ("gemini-2.5-flash-lite", "Gemini 2.5 Flash Lite", "high_limit"),
        ("gemini-2.0-flash", "Gemini 2 Flash", "high_limit"),
        
        # 🎨 Генерация изображений & Мультимодал
        ("nano-banana-2", "Nano Banana 2 (3.1 Flash Image)", "media_gen"),
        ("nano-banana-pro", "Nano Banana Pro (3 Pro Image)", "media_gen"),
        ("nano-banana", "Nano Banana (2.5 Flash Image)", "media_gen"),
        ("imagen-3.0-generate-002", "Google Imagen 3 HD", "media_gen"),
        ("gemini-omni-1.1-flash", "Gemini Omni 1.1 Flash", "media_gen"),
        
        # 🎬 Видео & Музыка
        ("veo-3-fast-generate", "Veo 3 Fast Video Gen", "media_gen"),
        ("veo-3-generate", "Veo 3 Video Gen", "media_gen"),
        ("lyria-3-pro", "Lyria 3 Pro Music Gen", "media_gen"),
        ("gemini-3.1-flash-tts", "Gemini 3.1 Flash TTS (Voice)", "media_gen")
    ]
    
    all_models = []
    for m_id, label, cat in gemini_defaults:
        all_models.append((m_id, label, cat))
        
    for k in keys:
        prov = k.get("provider", "custom")
        k_name = k.get("name")
        p_models = k.get("available_models") or ([k.get("model")] if k.get("model") else [])
        for m in p_models:
            if not m:
                continue
            short_m = m.split("/")[-1] if "/" in m else m
            label = f"{short_m} ({k_name})"
            if ":free" in m or "free" in m.lower() or prov == "gemini":
                cat = "high_limit"
            else:
                cat = "reasoning"
            all_models.append((m, label, cat))
            
    seen = set()
    unique_models = []
    for item in all_models:
        if item[0] not in seen:
            seen.add(item[0])
            unique_models.append(item)
            
    reasoning_list = [m for m in unique_models if m[2] == "reasoning"]
    high_limit_list = [m for m in unique_models if m[2] == "high_limit"]
    media_gen_list = [m for m in unique_models if m[2] == "media_gen"]
    
    text = f"🧠 *Каталог AI-моделей Gemini & Провайдеров*\n\n"
    if current == "auto":
        text += "Текущая модель: 🤖 *Авто-выбор (Лучшая модель под задачу)*\n\n"
    else:
        text += f"Текущая модель: *`{current}`*\n\n"
        
    text += "💡 *Категории:*\n"
    text += "• 🧠 *Рассуждения и Код* — максимальный интеллект, DeepSeek-R1, Gemini 3.7 Reasoning, 3.1 Pro\n"
    text += "• ⚡ *Высокий лимит (500 - 14.4k RPD)* — Flash Lite, Gemma 4, безлимитная скорость\n"
    text += "• 🎨 *Генерация медиа* — Nano Banana 2, Imagen 3, Veo 3 Video, Lyria 3\n\n"
    text += "Нажмите на нужную модель для мгновенной смены:"
    
    kb_rows = []
    auto_prefix = "✅ " if current == "auto" else "🤖 "
    kb_rows.append([{"text": f"{auto_prefix}Авто-выбор (Лучшая модель под задачу)", "callback_data": "model_auto"}])
    
    # 1. Reasoning Top Models
    for m_id, label, _ in reasoning_list[:6]:
        prefix = "✅ " if current == m_id else "🧠 "
        kb_rows.append([{"text": f"{prefix}{label}", "callback_data": f"model_{m_id}"}])
        
    # 2. High Limit Economy Models
    for m_id, label, _ in high_limit_list[:6]:
        prefix = "✅ " if current == m_id else "⚡ "
        kb_rows.append([{"text": f"{prefix}{label}", "callback_data": f"model_{m_id}"}])
        
    # 3. Media & Generation Models
    for m_id, label, _ in media_gen_list[:4]:
        prefix = "✅ " if current == m_id else "🎨 "
        kb_rows.append([{"text": f"{prefix}{label}", "callback_data": f"model_{m_id}"}])
        
    tg_send(text, chat_id=chat_id, reply_to=reply_to, reply_markup={"inline_keyboard": kb_rows})

# --- ОСНОВНОЙ ЦИКЛ ОПРОСА TELEGRAM ---

def telegram_polling_loop():
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
                    
                    if cq_data in ["btn_add_key", "key_add_gemini"]:
                        user_states[ALLOWED_CHAT_ID] = "WAITING_FOR_GEMINI_KEY"
                        tg_send("🟢 *Отправьте ваш ключ Gemini API следующим сообщением:*\n(Создается бесплатно на https://aistudio.google.com/app/apikey)")
                    elif cq_data == "key_add_deepseek":
                        user_states[ALLOWED_CHAT_ID] = "WAITING_FOR_DEEPSEEK_KEY"
                        tg_send("🐳 *Отправьте ваш API-ключ DeepSeek (`sk-...`):*\n(Создается на https://platform.deepseek.com/api_keys)")
                    elif cq_data == "key_add_openrouter":
                        user_states[ALLOWED_CHAT_ID] = "WAITING_FOR_OPENROUTER_KEY"
                        tg_send("🌐 *Отправьте ваш OpenRouter API ключ (`sk-or-...`):*\n(Создается на https://openrouter.ai/keys)")
                    elif cq_data == "key_add_groq":
                        user_states[ALLOWED_CHAT_ID] = "WAITING_FOR_GROQ_KEY"
                        tg_send("⚡ *Отправьте ваш Groq или OpenAI API ключ (`gsk_...` или `sk-...`):*")
                    elif cq_data == "cmd_deeperseeker_guide":
                        show_deeperseeker_guide(ALLOWED_CHAT_ID)
                    elif cq_data == "key_add_deeperseeker":
                        user_states[ALLOWED_CHAT_ID] = {"step": "WAITING_FOR_DEEPERSEEKER_KEY"}
                        tg_send(
                            "⚡ *Подключение deeperseeker (Бесплатный DeepSeek)*\n\n"
                            "🔑 Введите API-ключ сервера deeperseeker (по умолчанию `dseeker`)\n"
                            "или напишите `default`, чтобы сразу подключить `http://localhost:4000/v1` с ключом `dseeker`:"
                        )
                    elif cq_data == "key_add_custom":
                        user_states[ALLOWED_CHAT_ID] = {"step": "WAITING_FOR_CUSTOM_KEY"}
                        tg_send("⚙️ *Настройка кастомного AI-провайдера*\n\n🔑 *Шаг 1 из 3:* Отправьте ваш API-ключ (например: `sk-...`):")
                    elif cq_data.startswith("set_url_"):
                        url_preset = cq_data.replace("set_url_", "")
                        st = user_states.get(ALLOWED_CHAT_ID)
                        if isinstance(st, dict) and st.get("step") == "WAITING_FOR_CUSTOM_URL":
                            saved_key = st.get("key")
                            tg_send(f"⏳ *Проверяю подключение к `{url_preset}` и запрашиваю модели...*")
                            res = test_and_discover_models(url_preset, saved_key)
                            if not res.get("valid"):
                                tg_send(f"❌ Ошибка авторизации: {res.get('error', 'Не удалось подключиться')}")
                                user_states.pop(ALLOWED_CHAT_ID, None)
                            else:
                                models = res.get("models", [])
                                free_m = res.get("free_models", [])
                                top_m = res.get("top_models", [])
                                st["step"] = "WAITING_FOR_CUSTOM_MODEL"
                                st["url"] = url_preset
                                st["models"] = models
                                st["free_models"] = free_m
                                st["top_models"] = top_m
                                user_states[ALLOWED_CHAT_ID] = st
                                
                                succ_text = f"✅ *API-ключ проверен и рабочий (HTTP 200 OK)!*\n\n"
                                succ_text += f"🌐 На сервере обнаружено *{len(models)} моделей*.\n\n"
                                succ_text += "Выберите, как добавить модели:\n"
                                
                                kb_rows = []
                                if free_m:
                                    kb_rows.append([{"text": f"🟢 Добавить ВСЕ бесплатные (:free) ({len(free_m)} шт)", "callback_data": "add_bulk_free"}])
                                if top_m:
                                    kb_rows.append([{"text": f"💎 Добавить ВСЕ Топ-кодинг модели ({len(top_m)} шт)", "callback_data": "add_bulk_top"}])
                                if models:
                                    kb_rows.append([{"text": f"📦 Добавить ВСЕ найденные модели ({len(models)} шт)", "callback_data": "add_bulk_all"}])
                                
                                # Show top 4 individual models
                                row = []
                                for m in (top_m or models)[:4]:
                                    row.append({"text": m.split('/')[-1], "callback_data": f"pick_m_{m}"})
                                    if len(row) == 2:
                                        kb_rows.append(row)
                                        row = []
                                if row:
                                    kb_rows.append(row)
                                    
                                tg_send(succ_text, reply_markup={"inline_keyboard": kb_rows})
                    elif cq_data in ["add_bulk_free", "add_bulk_top", "add_bulk_all"]:
                        st = user_states.pop(ALLOWED_CHAT_ID, None)
                        if isinstance(st, dict) and st.get("key") and st.get("url"):
                            if cq_data == "add_bulk_free":
                                chosen_list = st.get("free_models") or st.get("models")
                                grp = "Free Tier"
                            elif cq_data == "add_bulk_top":
                                chosen_list = st.get("top_models") or st.get("models")
                                grp = "Top Coding"
                            else:
                                chosen_list = st.get("models")
                                grp = "All Models"
                                
                            first_m = chosen_list[0] if chosen_list else "deepseek-chat"
                            k_name, prov = add_new_key(
                                api_key=st["key"],
                                base_url=st["url"],
                                model=first_m,
                                available_models=chosen_list,
                                provider="custom",
                                name=f"Custom ({grp})"
                            )
                            config = load_config()
                            config["ACTIVE_MODEL"] = first_m
                            save_config(config)
                            
                            tg_send(
                                f"🎉 *Провайдер успешно добавлен и активирован!*\n"
                                f"• Название: *{k_name}*\n"
                                f"• Активная модель: `{first_m}`\n"
                                f"• Подключено моделей: *{len(chosen_list)} шт*\n\n"
                                f"💡 Все они теперь доступны в меню *🧠 Сменить модель*!",
                                reply_markup=get_main_keyboard()
                            )
                            show_keys_menu(ALLOWED_CHAT_ID)
                    elif cq_data.startswith("pick_m_"):
                        chosen_model = cq_data.replace("pick_m_", "")
                        st = user_states.pop(ALLOWED_CHAT_ID, None)
                        if isinstance(st, dict) and st.get("key") and st.get("url"):
                            all_m = st.get("models", [chosen_model])
                            k_name, prov = add_new_key(
                                api_key=st["key"],
                                base_url=st["url"],
                                model=chosen_model,
                                available_models=all_m,
                                provider="custom",
                                name=f"Custom ({chosen_model.split('/')[-1]})"
                            )
                            config = load_config()
                            config["ACTIVE_MODEL"] = chosen_model
                            save_config(config)
                            
                            tg_send(
                                f"🎉 *Провайдер успешно добавлен!*\n"
                                f"• Модель: `{chosen_model}`\n"
                                f"• Base URL: `{st['url']}`\n"
                                f"• Статус: 🟢 Рабочий\n"
                                f"• Всего сохранено моделей: *{len(all_m)}*",
                                reply_markup=get_main_keyboard()
                            )
                            show_keys_menu(ALLOWED_CHAT_ID)
                    elif cq_data == "btn_show_full_keys":
                        show_keys_menu(ALLOWED_CHAT_ID, show_full_keys=True)
                    elif cq_data == "btn_hide_keys":
                        show_keys_menu(ALLOWED_CHAT_ID, show_full_keys=False)
                    elif cq_data == "btn_validate_all_keys" or cq_data == "btn_refresh_keys":
                        validate_all_keys(ALLOWED_CHAT_ID)
                    elif cq_data == "btn_trigger_build":
                        res = tool_trigger_ipa_build()
                        if res.get("success"):
                            tg_send("🚀 *Сборка IPA запущена в GitHub Actions!*\nКак только компиляция завершится, готовый `.ipa` прилетит сюда в чат.")
                        else:
                            tg_send(f"⚠️ Ошибка запуска сборки: {res.get('output')}")
                    elif cq_data == "btn_dismiss":
                        tg_send("👍 *Принято.* Сборка не запускается. Можете продолжать вносить правки или задавать вопросы.")
                    elif cq_data == "hf_status":
                        res = tool_hf_get_status()
                        if "error" in res:
                            tg_send(f"❌ Ошибка Hugging Face: {res['error']}")
                        else:
                            stage = res.get("stage")
                            hw = res.get("hardware")
                            priv = "🔒 Приватный" if res.get("private") else "🌍 Публичный"
                            tg_send(f"📊 *Статус Hugging Face Space* (`{res.get('space')}`):\n\n• **Состояние**: `🟢 {stage}`\n• **Оборудование**: `{hw}`\n• **Тип**: {priv}\n• **Лайки**: ❤️ {res.get('likes')}")
                    elif cq_data == "hf_restart":
                        res = tool_hf_restart_space()
                        if "error" in res:
                            tg_send(f"❌ Ошибка перезапуска: {res['error']}")
                        else:
                            tg_send(f"🔄 *{res.get('message')}*")
                    elif cq_data == "hf_logs_run":
                        tg_send("⏳ *Запрашиваю логи контейнера (Run) с сервера Hugging Face...*")
                        res = tool_hf_get_logs("run")
                        if "error" in res:
                            tg_send(f"❌ {res['error']}")
                        else:
                            tg_send(f"📋 *Логи работы контейнера (Hugging Face Spaces):*\n```text\n{res.get('logs')}\n```")
                    elif cq_data == "hf_logs_build":
                        tg_send("⏳ *Запрашиваю логи сборки (Build) с сервера Hugging Face...*")
                        res = tool_hf_get_logs("build")
                        if "error" in res:
                            tg_send(f"❌ {res['error']}")
                        else:
                            tg_send(f"🛠️ *Логи сборки контейнера (Build):*\n```text\n{res.get('logs')}\n```")
                    elif cq_data == "hf_view_app":
                        res = tool_hf_get_file("app.py")
                        if "error" in res:
                            tg_send(f"❌ {res['error']}")
                        else:
                            tg_send(f"📝 *Содержимое `app.py` на Hugging Face:*\n```python\n{res.get('content')[:3500]}\n```")
                    elif cq_data == "hf_edit_app":
                        user_states[ALLOWED_CHAT_ID] = "WAITING_FOR_HF_APP_CODE"
                        tg_send("✏️ *Отправьте новый полный код для `app.py` на Hugging Face следующим сообщением:*")
                    elif cq_data == "hf_set_token":
                        user_states[ALLOWED_CHAT_ID] = "WAITING_FOR_HF_TOKEN"
                        tg_send("🔑 *Отправьте ваш Hugging Face User Access Token (с правами Write):*\n(Создается на https://huggingface.co/settings/tokens)")
                    elif cq_data == "hf_set_space":
                        user_states[ALLOWED_CHAT_ID] = "WAITING_FOR_HF_SPACE"
                        tg_send("🏷️ *Отправьте имя вашего Space на Hugging Face (например: `IsseT/sonivo-bot`):*")
                    elif cq_data == "mode_dev":
                        config = load_config()
                        config["BOT_MODE"] = "dev"
                        save_config(config)
                        tg_send("⚡ *Режим переключен на: Редактор проекта (Правки кода)*\nТеперь бот может менять код, но всегда спросит вас перед сборкой IPA.", reply_markup=get_main_keyboard())
                    elif cq_data == "mode_chat":
                        config = load_config()
                        config["BOT_MODE"] = "chat"
                        save_config(config)
                        tg_send("💬 *Режим переключен на: Личный Чат / Консультант*\nВ этом режиме бот отвечает на любые вопросы по Sonivo, обсуждает идеи и анализирует медиа без изменения файлов.", reply_markup=get_main_keyboard())
                    elif cq_data == "btn_add_skill":
                        user_states[ALLOWED_CHAT_ID] = "WAITING_FOR_SKILL"
                        tg_send("📥 *Отправьте файл скилла или инструкций (`.md`, `.txt`, `.json`):*\nБот сохранит его в постоянные навыки `agent_skills/`.", reply_markup=get_main_keyboard())
                    elif cq_data == "agy_browser_login":
                        user_states[ALLOWED_CHAT_ID] = "WAITING_FOR_AGY_TOKEN"
                        login_text = (
                            "🌐 *Авторизация в Google Antigravity*\n\n"
                            "Отправьте ваш Google OAuth токен (`ya29...`) или JSON `oauth_creds.json` следующим сообщением.\n\n"
                            "💡 Либо отправьте команду:\n"
                            "`/login_google <токен_или_json>`\n\n"
                            "Бот проверит токен через Google API и активирует круглосуточную сессию 24/7!"
                        )
                        tg_send(login_text, reply_markup=get_main_keyboard())
                    elif cq_data == "agy_sync_cloud":
                        tg_send("⏳ *Синхронизирую учетные данные Antigravity с облачным сервером...*")
                        res = sync_local_antigravity_to_config()
                        if res.get("success"):
                            tg_send(f"✅ *Токены Google Antigravity (`{res.get('email')}`) успешно синхронизированы!*\nТеперь бот работает в Telegram 24/7 даже при выключенном компьютере.")
                        else:
                            tg_send(f"❌ Ошибка синхронизации: {res.get('error')}")
                        show_antigravity_menu(ALLOWED_CHAT_ID)
                    elif cq_data == "agy_refresh":
                        show_antigravity_menu(ALLOWED_CHAT_ID)
                    elif cq_data == "agy_models":
                        tg_send("⏳ *Запрашиваю модели из Google Antigravity CLI...*")
                        res = tool_antigravity_cli("models")
                        tg_send(f"🧠 *Модели Google Antigravity:*\n```text\n{res.get('output')}\n```")
                    elif cq_data == "agy_agents":
                        tg_send("⏳ *Запрашиваю список субагентов Antigravity...*")
                        res = tool_antigravity_cli("agents")
                        tg_send(f"🤖 *Субагенты Antigravity:*\n```text\n{res.get('output')}\n```")
                    elif cq_data == "agy_plugins":
                        res = tool_antigravity_cli("plugin list")
                        tg_send(f"🔌 *Плагины Antigravity:*\n```text\n{res.get('output')}\n```")
                    elif cq_data == "agy_version":
                        res = tool_antigravity_cli("--version")
                        tg_send(f"ℹ️ *Версия Antigravity CLI:* `{res.get('output')}`")
                    elif cq_data.startswith("model_"):
                        new_model = cq_data.replace("model_", "")
                        config = load_config()
                        config["ACTIVE_MODEL"] = new_model
                        save_config(config)
                        if new_model == "auto":
                            tg_send("🤖 *Включен умный Авто-выбор моделей!*\n\nБот сам анализирует ваши задачи и автоматически выбирает самую мощную модель для рассуждений (DeepSeek R1, Claude 3.5, Gemini 3.7) из подключенных.")
                        elif new_model == "antigravity":
                            tg_send("🌌 *Активирован движок Google Antigravity Agent!*\nТеперь бот решает задачи с планированием и возможностями Antigravity CLI.")
                        else:
                            tg_send(f"✅ Активная модель переключена на: *{new_model}*")
                        show_model_menu(ALLOWED_CHAT_ID)
                    continue
                    
                msg = u.get("message")
                if not msg:
                    continue
                    
                sender_id = msg.get("from", {}).get("id")
                if sender_id != ALLOWED_CHAT_ID:
                    print(f"[Security] Ignored message from unauthorized user: {sender_id}")
                    continue
                    
                msg_id = msg["message_id"]
                
                # Обработка отправки файлов и документов (логи, ошибки, код, скиллы)
                if "document" in msg:
                    doc = msg["document"]
                    doc_name = doc.get("file_name", "log.txt")
                    file_id = doc.get("file_id")
                    
                    file_info = tg_request("getFile", {"file_id": file_id})
                    if file_info and file_info.get("ok"):
                        f_path = file_info["result"]["file_path"]
                        download_url = f"https://api.telegram.org/file/bot{BOT_TOKEN}/{f_path}"
                        try:
                            with urllib.request.urlopen(download_url) as r:
                                content = r.read().decode("utf-8", errors="replace")
                                
                                # Если пользователь явно нажал "Загрузить файл скилла"
                                if user_states.get(ALLOWED_CHAT_ID) == "WAITING_FOR_SKILL":
                                    user_states.pop(ALLOWED_CHAT_ID, None)
                                    target_file = SKILLS_DIR / doc_name
                                    target_file.write_text(content, encoding="utf-8")
                                    tg_send(f"📦 *Скилл `{doc_name}` успешно загружен и активирован!*\nТеперь AI-агент использует эти инструкции в системном промпте.", reply_to=msg_id)
                                    continue
                                else:
                                    # Обычный лог, код или файл для анализа
                                    caption = msg.get("caption", "").strip()
                                    file_prompt = f"📄 Пользователь прикрепил файл `{doc_name}` (лог/ошибка/код):\n\n```text\n{content[:18000]}\n```\n\n"
                                    if caption:
                                        file_prompt += f"Комментарий: {caption}"
                                    else:
                                        file_prompt += "Внимательно изучи этот лог/файл, найди проблему и исправь её в проекте."
                                    
                                    msg["text"] = file_prompt
                        except Exception as ex:
                            tg_send(f"❌ Ошибка чтения файла: {ex}", reply_to=msg_id)
                            continue
                            
                # Обработка мультимодальности (Фото, Видео, Голосовые)
                user_parts = []
                has_media = False
                
                if "photo" in msg:
                    photo = msg["photo"][-1]
                    file_info = tg_request("getFile", {"file_id": photo["file_id"]})
                    if file_info and file_info.get("ok"):
                        f_url = f"https://api.telegram.org/file/bot{BOT_TOKEN}/{file_info['result']['file_path']}"
                        try:
                            with urllib.request.urlopen(f_url, timeout=25) as r:
                                b64 = base64.b64encode(r.read()).decode("utf-8")
                                user_parts.append({"inlineData": {"mimeType": "image/jpeg", "data": b64}})
                                has_media = True
                        except Exception as ex:
                            print(f"[Photo download error]: {ex}")
                            
                elif "video" in msg or "video_note" in msg:
                    vid = msg.get("video") or msg.get("video_note")
                    file_info = tg_request("getFile", {"file_id": vid["file_id"]})
                    if file_info and file_info.get("ok"):
                        f_url = f"https://api.telegram.org/file/bot{BOT_TOKEN}/{file_info['result']['file_path']}"
                        try:
                            with urllib.request.urlopen(f_url, timeout=40) as r:
                                b64 = base64.b64encode(r.read()).decode("utf-8")
                                user_parts.append({"inlineData": {"mimeType": "video/mp4", "data": b64}})
                                has_media = True
                        except Exception as ex:
                            print(f"[Video download error]: {ex}")
                            
                elif "voice" in msg or "audio" in msg:
                    audio = msg.get("voice") or msg.get("audio")
                    file_info = tg_request("getFile", {"file_id": audio["file_id"]})
                    if file_info and file_info.get("ok"):
                        f_url = f"https://api.telegram.org/file/bot{BOT_TOKEN}/{file_info['result']['file_path']}"
                        try:
                            with urllib.request.urlopen(f_url, timeout=25) as r:
                                b64 = base64.b64encode(r.read()).decode("utf-8")
                                user_parts.append({"inlineData": {"mimeType": "audio/ogg", "data": b64}})
                                has_media = True
                        except Exception as ex:
                            print(f"[Voice download error]: {ex}")
                            
                text = msg.get("text", "").strip()
                if not text and "caption" in msg:
                    text = msg["caption"].strip()
                    
                if not text and not has_media:
                    continue
                    
                print(f"\n[User Request]: {text or '(Media attached)'}")
                
                # Пошаговый визард настройки кастомного провайдера
                st = user_states.get(ALLOWED_CHAT_ID)
                if isinstance(st, dict):
                    step = st.get("step")
                    if step == "WAITING_FOR_DEEPERSEEKER_KEY":
                        k_val = text.strip()
                        if k_val.lower() in ["default", "dseeker", ""]:
                            k_val = "dseeker"
                        clean_url = "http://localhost:4000/v1"
                        tg_send(f"⏳ *Проверяю подключение к deeperseeker (`{clean_url}`) с ключом `{k_val}`...*", reply_to=msg_id)
                        res = test_and_discover_models(clean_url, k_val)
                        if not res.get("valid"):
                            tg_send(
                                f"⚠️ *Сервер deeperseeker не отвечает на `{clean_url}`!*\n\n"
                                f"Убедитесь, что сервер deeperseeker запущен на вашем компьютере (`python3 app.py`).\n\n"
                                f"• Ошибка: `{res.get('error')}`\n"
                                f"• Для полной инструкции отправьте команду /deeperseeker",
                                reply_to=msg_id
                            )
                            user_states.pop(ALLOWED_CHAT_ID, None)
                            continue
                        else:
                            models = res.get("models", [])
                            st["step"] = "WAITING_FOR_CUSTOM_MODEL"
                            st["url"] = clean_url
                            st["key"] = k_val
                            st["models"] = models
                            st["free_models"] = res.get("free_models", [])
                            st["top_models"] = res.get("top_models", [])
                            user_states[ALLOWED_CHAT_ID] = st
                            
                            succ_text = f"✅ *deeperseeker успешно подключен! (HTTP 200 OK)*\n\n"
                            succ_text += f"🌐 На сервере обнаружено *{len(models)} моделей*.\n\n"
                            succ_text += "Выберите вариант добавления:\n"
                            
                            kb_rows = [
                                [{"text": f"📦 Подключить ВСЕ модели ({len(models)} шт)", "callback_data": "add_bulk_all"}],
                                [{"text": "🐳 deepseek-chat", "callback_data": "pick_m_deepseek-chat"}, {"text": "🧠 deepseek-reasoner", "callback_data": "pick_m_deepseek-reasoner"}]
                            ]
                            tg_send(succ_text, reply_to=msg_id, reply_markup={"inline_keyboard": kb_rows})
                            continue
                    elif step == "WAITING_FOR_CUSTOM_KEY":
                        clean_k = text.strip()
                        if len(clean_k) >= 4 and not any(ord(c) > 127 or c.isspace() for c in clean_k):
                            user_states[ALLOWED_CHAT_ID] = {"step": "WAITING_FOR_CUSTOM_URL", "key": clean_k}
                            preset_kb = {
                                "inline_keyboard": [
                                    [{"text": "⚡ deeperseeker (http://localhost:4000/v1)", "callback_data": "set_url_http://localhost:4000/v1"}],
                                    [{"text": "🐳 DeepSeek (https://api.deepseek.com/v1)", "callback_data": "set_url_https://api.deepseek.com/v1"}],
                                    [{"text": "🌐 OpenRouter (https://openrouter.ai/api/v1)", "callback_data": "set_url_https://openrouter.ai/api/v1"}],
                                    [{"text": "⚡ Groq (https://api.groq.com/openai/v1)", "callback_data": "set_url_https://api.groq.com/openai/v1"}],
                                    [{"text": "🚀 Together (https://api.together.xyz/v1)", "callback_data": "set_url_https://api.together.xyz/v1"}],
                                    [{"text": "💻 Ollama (http://localhost:11434/v1)", "callback_data": "set_url_http://localhost:11434/v1"}]
                                ]
                            }
                            tg_send(
                                "🌐 *Шаг 2 из 3: Введите Base URL провайдера*\n\n"
                                "Вы можете нажать на готовый пресет ниже или отправить свой URL (например `https://my-api.com/v1`):",
                                reply_to=msg_id,
                                reply_markup=preset_kb
                            )
                            continue
                        else:
                            tg_send("⚠️ Текст не похож на валидный API-ключ. Настройка отменена.", reply_to=msg_id)
                            user_states.pop(ALLOWED_CHAT_ID, None)
                            continue
                    elif step == "WAITING_FOR_CUSTOM_URL":
                        clean_url = text.strip()
                        saved_key = st.get("key")
                        tg_send(f"⏳ *Проверяю авторизацию на `{clean_url}` и запрашиваю список моделей...*", reply_to=msg_id)
                        res = test_and_discover_models(clean_url, saved_key)
                        if not res.get("valid"):
                            tg_send(f"❌ *Ошибка подключения к серверу:*\n`{res.get('error', 'Unknown error')}`\n\nПроверьте Base URL и правильность API-ключа.", reply_to=msg_id)
                            user_states.pop(ALLOWED_CHAT_ID, None)
                            continue
                        else:
                            models = res.get("models", [])
                            free_m = res.get("free_models", [])
                            top_m = res.get("top_models", [])
                            st["step"] = "WAITING_FOR_CUSTOM_MODEL"
                            st["url"] = clean_url
                            st["models"] = models
                            st["free_models"] = free_m
                            st["top_models"] = top_m
                            user_states[ALLOWED_CHAT_ID] = st
                            
                            succ_text = f"✅ *API-ключ проверен и рабочий (HTTP 200 OK)!*\n\n"
                            succ_text += f"🌐 На сервере обнаружено *{len(models)} моделей*.\n\n"
                            succ_text += "Выберите вариант добавления:\n"
                            
                            kb_rows = []
                            if free_m:
                                kb_rows.append([{"text": f"🟢 Добавить ВСЕ бесплатные (:free) ({len(free_m)} шт)", "callback_data": "add_bulk_free"}])
                            if top_m:
                                kb_rows.append([{"text": f"💎 Добавить ВСЕ Топ-кодинг модели ({len(top_m)} шт)", "callback_data": "add_bulk_top"}])
                            if models:
                                kb_rows.append([{"text": f"📦 Добавить ВСЕ найденные модели ({len(models)} шт)", "callback_data": "add_bulk_all"}])
                                
                            row = []
                            for m in (top_m or models)[:4]:
                                row.append({"text": m.split('/')[-1], "callback_data": f"pick_m_{m}"})
                                if len(row) == 2:
                                    kb_rows.append(row)
                                    row = []
                            if row:
                                kb_rows.append(row)
                                
                            tg_send(succ_text, reply_to=msg_id, reply_markup={"inline_keyboard": kb_rows})
                            continue
                    elif step == "WAITING_FOR_CUSTOM_MODEL":
                        chosen_model = text.strip()
                        saved_key = st.get("key")
                        saved_url = st.get("url")
                        all_m = st.get("models", [chosen_model])
                        user_states.pop(ALLOWED_CHAT_ID, None)
                        
                        if chosen_model.lower() == "free" and st.get("free_models"):
                            selected_models = st.get("free_models")
                            act_m = selected_models[0]
                            k_label = "Free Tier"
                        elif chosen_model.lower() == "top" and st.get("top_models"):
                            selected_models = st.get("top_models")
                            act_m = selected_models[0]
                            k_label = "Top Coding"
                        elif chosen_model.lower() == "all" and all_m:
                            selected_models = all_m
                            act_m = all_m[0]
                            k_label = "All Models"
                        else:
                            selected_models = [chosen_model] + [m for m in all_m if m != chosen_model]
                            act_m = chosen_model
                            k_label = chosen_model.split('/')[-1]
                            
                        k_name, prov = add_new_key(
                            api_key=saved_key,
                            base_url=saved_url,
                            model=act_m,
                            available_models=selected_models,
                            provider="custom",
                            name=f"Custom ({k_label})"
                        )
                        config = load_config()
                        config["ACTIVE_MODEL"] = act_m
                        save_config(config)
                        
                        tg_send(
                            f"🎉 *Провайдер успешно добавлен и активирован!*\n"
                            f"• Название: *{k_name}*\n"
                            f"• Активная модель: `{act_m}`\n"
                            f"• Подключено моделей: *{len(selected_models)} шт*\n"
                            f"• Base URL: `{saved_url}`\n"
                            f"• Статус: 🟢 Рабочий",
                            reply_to=msg_id,
                            reply_markup=get_main_keyboard()
                        )
                        show_keys_menu(ALLOWED_CHAT_ID)
                        continue
                
                if user_states.get(ALLOWED_CHAT_ID) in ["WAITING_FOR_API_KEY", "WAITING_FOR_GEMINI_KEY", "WAITING_FOR_DEEPSEEK_KEY", "WAITING_FOR_OPENROUTER_KEY", "WAITING_FOR_GROQ_KEY"]:
                    saved_st = user_states.pop(ALLOWED_CHAT_ID, None)
                    clean_k = text.strip()
                    if len(clean_k) >= 20 and not any(ord(c) > 127 or c.isspace() for c in clean_k):
                        prov = None
                        if saved_st == "WAITING_FOR_DEEPSEEK_KEY":
                            prov = "deepseek"
                        elif saved_st == "WAITING_FOR_OPENROUTER_KEY":
                            prov = "openrouter"
                        elif saved_st == "WAITING_FOR_GROQ_KEY":
                            prov = "groq"
                        elif saved_st == "WAITING_FOR_GEMINI_KEY":
                            prov = "gemini"
                            
                        # Live test key before adding!
                        tg_send("⏳ *Проверяю валидность ключа...*", reply_to=msg_id)
                        t_res = test_and_discover_models("", clean_k, prov)
                        k_name, assigned_prov = add_new_key(clean_k, provider=prov)
                        
                        status_str = f"Статус: {t_res.get('status_msg', '🟢 Добавлен')}"
                        tg_send(f"✅ *Ключ успешно добавлен!*\n• Провайдер: *{assigned_prov.capitalize()}*\n• Название: *{k_name}*\n• {status_str}\n\nБот автоматически переключается между всеми ключами при исчерпании лимитов.", reply_to=msg_id)
                        show_keys_menu(ALLOWED_CHAT_ID)
                        continue
                    else:
                        tg_send("⚠️ Текст не похож на API-ключ. Добавление отменено.", reply_to=msg_id)
                        # don't continue so if it was a button/command, it processes immediately!
                    
                if user_states.get(ALLOWED_CHAT_ID) == "WAITING_FOR_HF_TOKEN":
                    user_states.pop(ALLOWED_CHAT_ID, None)
                    if len(text) > 10:
                        config = load_config()
                        config["HF_TOKEN"] = text.strip()
                        save_config(config)
                        os.environ["HF_TOKEN"] = text.strip()
                        tg_send("✅ *Hugging Face Token сохранен!*\nТеперь вы можете перезагружать сервер и менять код прямо из чата.", reply_to=msg_id)
                        show_hf_menu(ALLOWED_CHAT_ID)
                    else:
                        tg_send("⚠️ Текст не похож на HF Token. Отменено.", reply_to=msg_id)
                    continue

                if user_states.get(ALLOWED_CHAT_ID) == "WAITING_FOR_HF_SPACE":
                    user_states.pop(ALLOWED_CHAT_ID, None)
                    if "/" in text:
                        config = load_config()
                        config["HF_SPACE"] = text.strip()
                        save_config(config)
                        os.environ["HF_SPACE"] = text.strip()
                        tg_send(f"✅ *Имя Space сохранено: `{text.strip()}`*", reply_to=msg_id)
                        show_hf_menu(ALLOWED_CHAT_ID)
                    else:
                        tg_send("⚠️ Имя Space должно быть в формате `Username/Space-Name` (например `IsseT/sonivo-bot`).", reply_to=msg_id)
                    continue

                if user_states.get(ALLOWED_CHAT_ID) == "WAITING_FOR_HF_APP_CODE":
                    user_states.pop(ALLOWED_CHAT_ID, None)
                    res = tool_hf_update_file("app.py", text.strip(), commit_message="Update app.py from Telegram")
                    if "error" in res:
                        tg_send(f"❌ Ошибка обновления `app.py`: {res['error']}", reply_to=msg_id)
                    else:
                        tg_send("✅ *`app.py` на Hugging Face успешно обновлен!*\nСервер автоматически перезапустится с новым кодом.", reply_to=msg_id)
                    continue

                if user_states.get(ALLOWED_CHAT_ID) == "WAITING_FOR_AGY_TOKEN":
                    user_states.pop(ALLOWED_CHAT_ID, None)
                    tg_send("⏳ *Проверяю и применяю Google OAuth токен...*", reply_to=msg_id)
                    res = apply_google_oauth_token(text)
                    if res.get("success"):
                        tg_send(f"🎉 *Google Antigravity успешно авторизован!*\n• Аккаунт: `{res.get('email')}`\n• Режим: 🟢 Облачный сервер (24/7)\n\nСессия сохранена в облаке и работает непрерывно!", reply_to=msg_id, reply_markup=get_main_keyboard())
                        show_antigravity_menu(ALLOWED_CHAT_ID)
                    else:
                        tg_send(f"❌ Ошибка авторизации: {res.get('error')}", reply_to=msg_id)
                    continue

                if text.startswith("/login_google") or text.startswith("/login_antigravity") or text.startswith("/login_agy"):
                    parts = text.split(maxsplit=1)
                    if len(parts) >= 2:
                        tok_arg = parts[1].strip()
                        tg_send("⏳ *Проверяю и применяю Google OAuth токен...*", reply_to=msg_id)
                        res = apply_google_oauth_token(tok_arg)
                        if res.get("success"):
                            tg_send(f"🎉 *Google Antigravity успешно авторизован!*\n• Аккаунт: `{res.get('email')}`\n• Режим: 🟢 Облачный сервер (24/7)\n\nСессия сохранена в облаке и работает непрерывно!", reply_to=msg_id, reply_markup=get_main_keyboard())
                            show_antigravity_menu(ALLOWED_CHAT_ID)
                        else:
                            tg_send(f"❌ Ошибка: {res.get('error')}", reply_to=msg_id)
                    else:
                        user_states[ALLOWED_CHAT_ID] = "WAITING_FOR_AGY_TOKEN"
                        tg_send("Отправьте ваш Google OAuth токен (`ya29...`) или JSON `oauth_creds.json` следующим сообщением:", reply_to=msg_id)
                    continue
                    
                if text in ["/start", "Меню"]:
                    tg_send(
                        "👋 Привет! Я твой персональный AI-разработчик и консультант Sonivo.\n\n"
                        "Отправь мне задачу, ошибку, скриншот, видео или любой вопрос — я помогу!",
                        reply_to=msg_id,
                        reply_markup=get_main_keyboard()
                    )
                    continue
                elif text in ["/deeperseeker", "deeperseeker", "/ds"]:
                    show_deeperseeker_guide(ALLOWED_CHAT_ID, reply_to=msg_id)
                    continue
                elif text in ["/hf", "🤗 Hugging Face"]:
                    show_hf_menu(ALLOWED_CHAT_ID, reply_to=msg_id)
                    continue
                elif text.startswith("/set_hf_token"):
                    parts = text.split(maxsplit=1)
                    if len(parts) >= 2:
                        tok = parts[1].strip()
                        config = load_config()
                        config["HF_TOKEN"] = tok
                        save_config(config)
                        os.environ["HF_TOKEN"] = tok
                        tg_send("✅ *Hugging Face Token сохранен!*", reply_to=msg_id)
                    else:
                        tg_send("Использование: `/set_hf_token <hf_...>`", reply_to=msg_id)
                    continue
                elif text.startswith("/set_hf_space"):
                    parts = text.split(maxsplit=1)
                    if len(parts) >= 2:
                        sp = parts[1].strip()
                        config = load_config()
                        config["HF_SPACE"] = sp
                        save_config(config)
                        os.environ["HF_SPACE"] = sp
                        tg_send(f"✅ *HF Space установлен: `{sp}`*", reply_to=msg_id)
                    else:
                        tg_send("Использование: `/set_hf_space <Username/Space-Name>`", reply_to=msg_id)
                    continue
                elif text in ["/hf_status"]:
                    res = tool_hf_get_status()
                    if "error" in res:
                        tg_send(f"❌ {res['error']}", reply_to=msg_id)
                    else:
                        tg_send(f"📊 Space: `{res.get('space')}` | Статус: `🟢 {res.get('stage')}` | HW: `{res.get('hardware')}`", reply_to=msg_id)
                    continue
                elif text in ["/hf_restart"]:
                    res = tool_hf_restart_space()
                    tg_send(f"🔄 {res.get('message') or res.get('error')}", reply_to=msg_id)
                    continue
                elif text in ["/mode", "💬 Режим: Чат", "⚡ Режим: Код"]:
                    show_mode_menu(ALLOWED_CHAT_ID, reply_to=msg_id)
                    continue
                elif text == "/chat":
                    config = load_config()
                    config["BOT_MODE"] = "chat"
                    save_config(config)
                    tg_send("💬 *Включен режим Чата / Консультанта!*", reply_to=msg_id, reply_markup=get_main_keyboard())
                    continue
                elif text == "/dev":
                    config = load_config()
                    config["BOT_MODE"] = "dev"
                    save_config(config)
                    tg_send("⚡ *Включен режим Разработчика!*", reply_to=msg_id, reply_markup=get_main_keyboard())
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
                elif text in ["/antigravity", "/agy", "🌌 Antigravity CLI"]:
                    show_antigravity_menu(ALLOWED_CHAT_ID, reply_to=msg_id)
                    continue
                elif text.startswith("/agy "):
                    cmd_args = text[5:].strip()
                    tg_send(f"⏳ *Выполняю:* `agy {cmd_args}`...", reply_to=msg_id)
                    if cmd_args.startswith("--print") or cmd_args.startswith("-p"):
                        # Prompt execution via agy print mode
                        prompt_text = cmd_args.replace("--print", "").replace("-p", "").strip().strip('"').strip("'")
                        res = tool_antigravity_cli(prompt=prompt_text)
                    else:
                        res = tool_antigravity_cli(command=cmd_args)
                    out_text = res.get("output", "")
                    if len(out_text) > 3800:
                        out_text = out_text[:3800] + "\n... (вывод обрезан)"
                    tg_send(f"🌌 *Результат Antigravity CLI:*\n```text\n{out_text}\n```", reply_to=msg_id)
                    continue
                elif text in ["/sync_antigravity", "/sync_agy"]:
                    tg_send("⏳ *Синхронизирую учетные данные Antigravity с облачным сервером...*", reply_to=msg_id)
                    res = sync_local_antigravity_to_config()
                    if res.get("success"):
                        tg_send(f"✅ *Токены Google Antigravity (`{res.get('email')}`) успешно синхронизированы!*\nТеперь бот будет работать в Telegram 24/7 даже при выключенном компьютере.", reply_to=msg_id)
                    else:
                        tg_send(f"❌ Ошибка синхронизации: {res.get('error')}", reply_to=msg_id)
                    show_antigravity_menu(ALLOWED_CHAT_ID, reply_to=msg_id)
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
                elif text.startswith("/add_custom"):
                    parts = text.split()
                    if len(parts) >= 3:
                        c_key = parts[1].strip()
                        c_url = parts[2].strip()
                        c_mode = parts[3].strip() if len(parts) >= 4 else "all"
                        c_name = parts[4].strip() if len(parts) >= 5 else None
                        
                        tg_send(f"⏳ *Тестирую подключение к `{c_url}` и запрашиваю модели...*", reply_to=msg_id)
                        res = test_and_discover_models(c_url, c_key)
                        if not res.get("valid"):
                            tg_send(f"❌ *Ошибка проверки провайдера:*\n`{res.get('error')}`", reply_to=msg_id)
                        else:
                            models = res.get("models", [])
                            free_m = res.get("free_models", [])
                            top_m = res.get("top_models", [])
                            
                            if c_mode.lower() == "free" and free_m:
                                selected_models = free_m
                                active_m = free_m[0]
                                p_name = c_name or "Custom (Free)"
                            elif c_mode.lower() == "top" and top_m:
                                selected_models = top_m
                                active_m = top_m[0]
                                p_name = c_name or "Custom (Top)"
                            elif c_mode.lower() == "all" or not c_mode:
                                selected_models = models
                                active_m = models[0] if models else "deepseek-chat"
                                p_name = c_name or f"Custom ({len(models)} моделей)"
                            else:
                                selected_models = [c_mode] + [m for m in models if m != c_mode]
                                active_m = c_mode
                                p_name = c_name or f"Custom ({c_mode})"
                                
                            k_name, prov = add_new_key(
                                api_key=c_key,
                                base_url=c_url,
                                model=active_m,
                                available_models=selected_models,
                                provider="custom",
                                name=p_name
                            )
                            config = load_config()
                            config["ACTIVE_MODEL"] = active_m
                            save_config(config)
                            
                            tg_send(
                                f"✅ *Кастомный провайдер успешно добавлен и проверен!*\n"
                                f"• Название: *{k_name}*\n"
                                f"• Активная модель: `{active_m}`\n"
                                f"• Загружено моделей: *{len(selected_models)} шт*\n"
                                f"• Base URL: `{c_url}`\n"
                                f"• Статус: 🟢 Рабочий (200 OK)\n\n"
                                f"💡 Все {len(selected_models)} моделей теперь доступны в меню *🧠 Сменить модель*!",
                                reply_to=msg_id
                            )
                            show_keys_menu(ALLOWED_CHAT_ID)
                    else:
                        tg_send("Использование: `/add_custom <API_KEY> <BASE_URL> [all|free|top|MODEL] [NAME]`\n\nПример (все бесплатные):\n`/add_custom sk-or-xxx https://openrouter.ai/api/v1 free OpenRouter`\n\nПример (все модели):\n`/add_custom sk-xxx https://api.deepseek.com/v1 all DeepSeek`", reply_to=msg_id)
                    continue
                elif text.startswith("/add_key"):
                    parts = text.split(maxsplit=2)
                    if len(parts) >= 2:
                        k_val = parts[1].strip()
                        k_name = parts[2].strip() if len(parts) > 2 else None
                        tg_send("⏳ *Проверяю API-ключ...*", reply_to=msg_id)
                        t_res = test_and_discover_models("", k_val)
                        added_name, prov = add_new_key(k_val, name=k_name)
                        st_msg = t_res.get("status_msg", "🟢 Добавлен")
                        tg_send(f"✅ *Ключ успешно добавлен!*\n• Провайдер: *{prov.capitalize()}*\n• Название: *{added_name}*\n• {st_msg}", reply_to=msg_id)
                        show_keys_menu(ALLOWED_CHAT_ID)
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
                    
                # Формируем промпт с медиа
                if text:
                    user_parts.append({"text": text})
                elif has_media:
                    user_parts.append({"text": "Посмотри это прикрепленное изображение / видео и проанализируй его для проекта Sonivo."})
                    
                config = load_config()
                mode = config.get("BOT_MODE", "dev")
                wait_text = "💭 *Думаю над ответом...*" if mode == "chat" else "⏳ *Принял задачу!* Начинаю работу..."
                status_res = tg_send(wait_text, reply_to=msg_id)
                status_msg_id = status_res.get("result", {}).get("message_id") if status_res else None
                
                res_obj = execute_agent_loop(user_parts, status_msg_id, ALLOWED_CHAT_ID)
                if isinstance(res_obj, dict):
                    final_answer = res_obj.get("text", "")
                    committed = res_obj.get("committed", False)
                else:
                    final_answer = str(res_obj)
                    committed = False
                    
                reply_markup = None
                if committed:
                    reply_markup = {
                        "inline_keyboard": [
                            [{"text": "🚀 Запустить сборку IPA сейчас?", "callback_data": "btn_trigger_build"}],
                            [{"text": "❌ Нет, продолжить без сборки", "callback_data": "btn_dismiss"}]
                        ]
                    }
                    
                tg_send(f"✅ *Готово!*\n\n{final_answer}", reply_to=msg_id, reply_markup=reply_markup)
                
        except KeyboardInterrupt:
            print("\n[!] Bot stopped by user.")
            break
def start_bot():
    t_thread = threading.Thread(target=telegram_polling_loop, daemon=True)
    t_thread.start()
    
    if HAS_GRADIO and demo:
        demo.launch()
    else:
        try:
            srv = http.server.HTTPServer(("0.0.0.0", 7860), AntigravityWebHandler)
            print("[Web Server] Listening on http://0.0.0.0:7860")
            threading.Thread(target=srv.serve_forever, daemon=True).start()
        except Exception as e:
            print(f"[Web Server Error]: {e}")
        t_thread.join()

if __name__ == "__main__":
    start_bot()
