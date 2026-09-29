"""
Google Flow (Veo 3.1 / Gemini Omni) Video-Shot Generation Client.
Connects VideoShot Studio with Google Flow (https://flow.google.com):
- Generates cinematic vertical 9:16 music videoshots using Google's flagship Veo 3.1 model.
- Supports both useapi/google-flow-api and direct browser session / cookie integration.
- Post-processes and merges audio with FFmpeg.
"""

import os
import sys
import json
import time
import subprocess
import requests

try:
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass

BASE_DIR = os.path.dirname(__file__)
CONFIG_PATH = os.path.join(BASE_DIR, "cache", "google_flow_config.json")
GOOGLE_FLOW_API_DIR = os.path.join(BASE_DIR, "google-flow-api", "veo-video")

def get_google_flow_config():
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            pass
    return {
        "api_token": "",
        "email": "",
        "model": "veo-3.1-fast",
        "aspect_ratio": "9:16",
        "mode": "api" # 'api' or 'browser'
    }

def save_google_flow_config(config_data):
    os.makedirs(os.path.dirname(CONFIG_PATH), exist_ok=True)
    with open(CONFIG_PATH, "w", encoding="utf-8") as f:
        json.dump(config_data, f, indent=2, ensure_ascii=False)

def merge_audio_with_video(video_path: str, audio_path: str, output_path: str, duration: float = 10.0):
    """Сводит сгенерированный Google Flow (Veo 3.1) видеоряд с оригинальным звуком."""
    cmd = [
        "ffmpeg", "-y",
        "-i", video_path,
        "-ss", "0",
        "-t", str(duration),
        "-i", audio_path,
        "-c:v", "copy",
        "-c:a", "aac",
        "-b:a", "256k",
        "-shortest",
        output_path
    ]
    subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def generate_google_flow_videoshot(
    image_path: str,
    audio_path: str,
    track_title: str,
    artist_name: str,
    bpm: float,
    vibe_preset,
    lyrics: str,
    output_path: str,
    duration: int = 8,
    progress_callback = None
):
    """
    Основная точка входа генерации видео-шота через Google Flow (Veo 3.1):
    1. Формирует высокоточный кинематографичный промпт.
    2. Вызывает Google Flow CLI раннер (useapi / Veo 3.1) или сессию.
    3. Скачивает готовый 9:16 MP4.
    4. Синхронизирует аудио с 808-битом через FFmpeg.
    """
    config = get_google_flow_config()
    api_token = config.get("api_token") or os.environ.get("GOOGLE_FLOW_API_TOKEN", "")
    email = config.get("email") or os.environ.get("GOOGLE_FLOW_EMAIL", "")
    model = config.get("model", "veo-3.1-fast")

    # Формируем режиссерский промпт
    if isinstance(vibe_preset, dict) and vibe_preset.get("director_prompt"):
        prompt = vibe_preset["director_prompt"]
    else:
        prompt = f"Cinematic 9:16 vertical music video clip of {artist_name} performing '{track_title}'. Stage lighting, volumetric smoke, high detail, photorealistic."

    print("=" * 65)
    print(f"[Google Flow] Launching generation via {model} (Google Veo)...")
    print(f"  Artist: {artist_name}")
    print(f"  Title: {track_title}")
    print(f"  Prompt: {prompt[:80]}...")
    print("=" * 65)

    if progress_callback:
        progress_callback("Подготовка задачи для Google Flow (Veo 3.1)...", 10)

    # Проверяем, настроен ли API токен useapi.net
    if api_token and email:
        temp_prompts_file = os.path.join(BASE_DIR, "cache", f"flow_prompt_{int(time.time())}.json")
        prompt_item = [{
            "prompt": prompt,
            "startImage": os.path.abspath(image_path),
            "aspectRatio": "9:16",
            "model": model,
            "duration": duration
        }]
        with open(temp_prompts_file, "w", encoding="utf-8") as f:
            json.dump(prompt_item, f, indent=2, ensure_ascii=False)

        if progress_callback:
            progress_callback("Отправка в Google Flow API (Veo 3.1 Fast)...", 25)

        cli_script = os.path.join(GOOGLE_FLOW_API_DIR, "google-flow.py")
        cmd = [sys.executable, cli_script, api_token, email, temp_prompts_file]

        proc = subprocess.Popen(
            cmd,
            cwd=GOOGLE_FLOW_API_DIR,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace"
        )

        raw_downloaded_video = None
        for line in proc.stdout:
            line_str = line.strip()
            print(f"[Google Flow CLI] {line_str}")
            if "jobId" in line_str or "uploading" in line_str:
                if progress_callback:
                    progress_callback(line_str[:60], 45)
            elif "Completed" in line_str or "Downloaded" in line_str:
                if progress_callback:
                    progress_callback("Видео сгенерировано Google Veo! Загрузка...", 85)

        proc.wait()

        # Ищем скачанный mp4 файл
        for f in os.listdir(GOOGLE_FLOW_API_DIR):
            if f.endswith(".mp4") and os.path.getmtime(os.path.join(GOOGLE_FLOW_API_DIR, f)) > time.time() - 300:
                raw_downloaded_video = os.path.join(GOOGLE_FLOW_API_DIR, f)
                break

        if raw_downloaded_video and os.path.exists(raw_downloaded_video):
            if progress_callback:
                progress_callback("Сведение аудио с видеорядом Google Veo...", 95)
            merge_audio_with_video(raw_downloaded_video, audio_path, output_path, duration=float(duration))
            if progress_callback:
                progress_callback("Готово! Видео-шот Google Flow скомпилирован.", 100)
            return output_path
        else:
            raise Exception("Google Flow CLI не вернул скачанный MP4 файл. Проверьте квоту аккаунта.")
    else:
        # Режим прямой браузерной авторизации Google Flow
        raise NotImplementedError(
            "Для Google Flow требуется указать API токен / Email в настройках Studio (или войти в аккаунт Google)."
        )
