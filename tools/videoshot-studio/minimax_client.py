"""
MiniMax H3 (Hailuo AI) Video-Shot Generation Client.
Implemented strictly according to the anonymous trial protocol:
- Zero API key required
- Dynamic client_id (mmtrial_{uuid}) matching X-MiniMax-Trial-Client
- Dynamic X-Forwarded-For random IP header
- Supports 6, 10, 15 seconds duration (ideal for Yandex Music videoshots)
- 9:16 vertical ratio
- Polling status every 7 seconds (queued -> dispatching -> succeeded)
- Downloads final video from /content endpoint
- Merges original audio with generated music video clip via FFmpeg
"""

import os
import sys
import time
import uuid
import random
import subprocess
import requests

try:
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass

def generate_random_ip():
    """Генерирует случайный публичный IPv4 адрес."""
    # Избегаем зарезервированных диапазонов
    first = random.choice([37, 46, 78, 85, 91, 95, 109, 176, 178, 185, 188, 194, 212])
    return f"{first}.{random.randint(10, 240)}.{random.randint(1, 250)}.{random.randint(1, 250)}"

def build_director_prompt(track_title: str, artist_name: str, bpm: float, vibe_data, lyrics: str = ""):
    """Формирует профессиональный кинематографичный промпт музыкального клипа без поцелуев."""
    clean_artist = artist_name.strip() or "The lead music artist"
    tempo_bpm = int(bpm) if bpm else 120

    # Если передан готовый AI vibe profile из анализатора
    if isinstance(vibe_data, dict):
        if vibe_data.get("director_prompt"):
            return vibe_data["director_prompt"]
        scene_desc = vibe_data.get("scene", "dark stage")
        lighting_desc = vibe_data.get("lighting", "neon spotlights")
        camera_desc = vibe_data.get("camera", "cinematic smooth tracking")
        action = f"Cinematic 9:16 vertical music video clip. The musical artist {clean_artist} performing solo '{track_title}', surrounded by {scene_desc}, with {lighting_desc} synchronized to {tempo_bpm} BPM rhythm."
        camera = camera_desc
    elif isinstance(vibe_data, str) and len(vibe_data) > 60:
        # Прямой кастомный промпт
        return vibe_data
    else:
        vibe_str = str(vibe_data or "")
        if "Trap" in vibe_str or "808" in vibe_str:
            action = f"Cinematic 9:16 vertical music video clip. The musical artist {clean_artist} giving an intense solo performance singing into a stage microphone on an underground dark urban stage with cold blue strobes, volumetric smoke, and pulsing lights synchronized to {tempo_bpm} BPM heavy 808 beat."
            camera = "Dynamic low-angle 24mm camera movements gliding smoothly."
        elif "Rave" in vibe_str or "Laser" in vibe_str:
            action = f"Cinematic 9:16 vertical music video clip. The musical artist {clean_artist} in an electrifying solo performance on a massive festival stage with multi-beam laser shows and pulsing strobes at {tempo_bpm} BPM."
            camera = "Dolly zoom camera push-ins and sweeping angles."
        elif "Rain" in vibe_str or "Nocturnal" in vibe_str:
            action = f"Atmospheric 9:16 vertical music video clip. The musical artist {clean_artist} in a deeply emotive solo performance walking through a rain-washed nocturnal metropolis under glowing blue and purple neon lights, capturing the mood of {track_title}."
            camera = "Smooth cinematic tracking camera glide through misty city reflections."
        elif "Sunset" in vibe_str or "Gold" in vibe_str:
            action = f"Warm golden-hour 9:16 vertical music video clip. The musical artist {clean_artist} performing an upbeat groove session in a sun-drenched loft surrounded by vintage audio gear and warm sun rays."
            camera = "Fluid cinematic push-in and low-angle camera movements."
        elif "Rock" in vibe_str:
            action = f"Raw concert 9:16 vertical music video clip. The musical artist {clean_artist} delivering a powerful vocal performance under sharp white stage spotlights, vintage amps, and haze."
            camera = "Dynamic live handheld camera movement."
        else:
            action = f"Cinematic 9:16 vertical music video clip. The musical artist {clean_artist} performing solo under pulsing neon light refractions and atmospheric fog at {tempo_bpm} BPM."
            camera = "Smooth orbiting camera with sharp anamorphic lens flare and cinematic depth of field."

    director_rules = "Solo musical singer performance only, charismatic presence, absolutely no kissing, no romantic couple, no romance, photorealistic 8K cinematic music video quality, sharp focus."
    
    if lyrics:
        lyrics_hint = f" Story elements inspired by: {lyrics[:100]}."
        return f"{action} {camera} {lyrics_hint} {director_rules}"

    return f"{action} {camera} {director_rules}"

def merge_audio_with_video(video_path: str, audio_path: str, output_path: str, duration: float = 10.0):
    """Сводит сгенерированный видеоряд со звуковой дорожкой трека через FFmpeg."""
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

def generate_minimax_videoshot(
    image_path: str,
    audio_path: str,
    track_title: str,
    artist_name: str,
    bpm: float,
    vibe_preset: str,
    lyrics: str,
    output_path: str,
    duration: int = 10,
    progress_callback = None
):
    """
    Генерация музыкального видео-шота через MiniMax H3:
    1. Отправка multipart задачи на siftq.com с привязкой UUID и подменой IP
    2. Опрос статуса каждые 7 секунд
    3. Скачивание готового MP4 из /content
    4. Синхронизация звука через FFmpeg
    """
    # Валидация длительности: строго 6, 10 или 15
    if str(duration) not in ("6", "10", "15"):
        duration = 10

    client_id = f"mmtrial_{uuid.uuid4().hex}"
    fake_ip = generate_random_ip()
    prompt = build_director_prompt(track_title, artist_name, bpm, vibe_preset, lyrics)

    print("=" * 60)
    print(f"[MiniMax H3] Submitting task...")
    print(f"  Client ID: {client_id}")
    print(f"  IP: {fake_ip}")
    print(f"  Duration: {duration}s (9:16)")
    print(f"  Prompt: {prompt[:90]}...")
    print("=" * 60)

    if progress_callback:
        progress_callback("Отправка задачи в нейросеть MiniMax H3...", 8)

    submit_url = "https://siftq.com/api/minimax-trial/video-generation"
    headers = {
        "X-MiniMax-Trial-Client": client_id,
        "X-Forwarded-For": fake_ip,
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    }

    if not image_path or not os.path.exists(image_path):
        raise FileNotFoundError(f"Artist image not found at {image_path}")

    with open(image_path, "rb") as img_file:
        files = {"image": ("artist.jpg", img_file, "image/jpeg")}
        data = {
            "client_id": client_id,
            "ratio": "9:16",
            "duration": str(duration),
            "prompt": prompt
        }
        res = requests.post(submit_url, headers=headers, data=data, files=files, timeout=25)

    if res.status_code != 200:
        raise Exception(f"MiniMax Submit HTTP {res.status_code}: {res.text}")

    resp_data = res.json()
    task_id = resp_data.get("task_id")
    access_token = resp_data.get("access_token")
    init_status = resp_data.get("status", "queued")
    queue_pos = resp_data.get("queue_position", 0)

    if not task_id or not access_token:
        raise Exception(f"MiniMax did not return task_id/access_token: {resp_data}")

    print(f"[MiniMax H3] Task accepted! Task ID: {task_id}, Token: {access_token}, Initial Queue: {queue_pos}")

    if progress_callback:
        progress_callback(f"Задача в очереди MiniMax (позиция: {queue_pos})...", 15)

    # 2. Опрос статуса задачи (строго каждые 7 секунд по протоколу)
    poll_url = f"https://siftq.com/api/minimax-trial/video-generation/{task_id}"
    temp_raw_video = output_path.replace(".mp4", "_h3_raw.mp4")

    # Максимум 60 попыток по 7 сек = до 7 минут ожидания
    for attempt in range(1, 61):
        time.sleep(7.0)
        try:
            p_res = requests.get(
                f"{poll_url}?access_token={access_token}",
                headers={"X-Forwarded-For": fake_ip},
                timeout=15
            )
        except Exception as e:
            print(f"[MiniMax H3] Poll error attempt {attempt}: {e}")
            continue

        if p_res.status_code == 200:
            p_data = p_res.json()
            status = p_data.get("status", "").lower()
            q_pos = p_data.get("queue_position")
            active_cnt = p_data.get("active_count", 0)

            print(f"[MiniMax H3] Poll #{attempt}: status='{status}', queue_position={q_pos}, active={active_cnt}")

            # Расчет динамического прогресса
            if status == "queued":
                pos_str = f", позиция #{q_pos}" if q_pos is not None else ""
                pct = min(40, 15 + attempt)
                if progress_callback:
                    progress_callback(f"В очереди генерации MiniMax H3{pos_str}...", pct)

            elif status in ("dispatching", "processing", "running"):
                pct = min(88, 45 + attempt * 2)
                if progress_callback:
                    progress_callback(f"Нейросеть MiniMax H3 синтезирует видеоклип...", pct)

            elif status == "succeeded":
                print(f"[MiniMax H3] Generation succeeded! Downloading content...")
                if progress_callback:
                    progress_callback("Видеоклип сгенерирован! Скачивание MP4...", 90)

                # 3. Скачивание готового файла из /content эндпоинта
                dl_url = f"https://siftq.com/api/minimax-trial/video-generation/{task_id}/content?client_id={client_id}&access_token={access_token}"
                dl_res = requests.get(dl_url, headers=headers, timeout=45)

                if dl_res.status_code == 200 and len(dl_res.content) > 10000:
                    with open(temp_raw_video, "wb") as f_out:
                        f_out.write(dl_res.content)
                    print(f"[MiniMax H3] Downloaded raw video ({len(dl_res.content)} bytes). Merging audio...")

                    if progress_callback:
                        progress_callback("Сведение видеоклипа с оригинальным аудио трека...", 96)

                    # 4. Сведение с аудио трека через FFmpeg
                    merge_audio_with_video(temp_raw_video, audio_path, output_path, duration=float(duration))
                    if os.path.exists(temp_raw_video):
                        os.remove(temp_raw_video)

                    if progress_callback:
                        progress_callback("Готово! Музыкальный видео-шот готов.", 100)

                    print(f"[MiniMax H3] Final video ready: {output_path}")
                    return output_path
                else:
                    raise Exception(f"Download failed from /content: HTTP {dl_res.status_code}, len={len(dl_res.content)}")

            elif status in ("failed", "error"):
                raise Exception(f"MiniMax reported task failure: {p_data}")

    raise Exception("MiniMax task polling timed out after 7 minutes")
