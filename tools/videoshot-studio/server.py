"""
Sonivo VideoShot Neural Studio Server
Local Web & REST API server for synthesizing vertical 9:16 video-shots
with audio-reactive beat pulses, artist detection, and RTX 4060 NVENC GPU acceleration.
"""

import os
import sys
import re
import json
import uuid
import time

try:
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    if hasattr(sys.stderr, 'reconfigure'):
        sys.stderr.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass

from flask import Flask, request, jsonify, render_template, send_from_directory, send_file, Response

from audio_analyzer import parse_track_info_from_filename, analyze_audio_file, detect_track_vibe
from artist_service import search_artist_info
from neural_renderer import render_neural_videoshot
from minimax_client import generate_minimax_videoshot
from local_neural_generator import generate_local_videoshot
from google_flow_client import generate_google_flow_videoshot, get_google_flow_config, save_google_flow_config

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CACHE_AUDIO_DIR = os.path.join(BASE_DIR, "cache", "audio")
CACHE_ARTISTS_DIR = os.path.join(BASE_DIR, "cache", "artists")
OUTPUT_DIR = os.path.join(BASE_DIR, "output")
TEMPLATES_DIR = os.path.join(BASE_DIR, "templates")

os.makedirs(CACHE_AUDIO_DIR, exist_ok=True)
os.makedirs(CACHE_ARTISTS_DIR, exist_ok=True)
os.makedirs(OUTPUT_DIR, exist_ok=True)

app = Flask(__name__, template_folder=TEMPLATES_DIR)
app.config["TEMPLATES_AUTO_RELOAD"] = True
app.jinja_env.auto_reload = True

# In-memory storage for track metadata
TRACK_STORE = {}

@app.after_request
def add_cors_headers(response):
    response.headers["Access-Control-Allow-Origin"] = "*"
    response.headers["Access-Control-Allow-Headers"] = "Content-Type, Authorization, Range"
    response.headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
    return response

@app.route("/")
def index():
    return render_template("index.html")

@app.route("/api/health", methods=["GET"])
def health():
    return jsonify({
        "status": "online",
        "engine": "Sonivo VideoShot Neural Studio v2.6",
        "gpu": "NVIDIA GeForce RTX 4060",
        "nvenc_available": True
    })

@app.route("/audio/<path:filename>")
def serve_audio(filename):
    res = send_from_directory(CACHE_AUDIO_DIR, filename)
    res.headers["Content-Disposition"] = "inline"
    res.headers["X-Content-Type-Options"] = "nosniff"
    return res

@app.route("/videos/<path:filename>")
def serve_video(filename):
    direct_path = os.path.join(OUTPUT_DIR, filename)
    if not os.path.exists(direct_path):
        clean_key = os.path.splitext(filename)[0]
        for f in os.listdir(OUTPUT_DIR):
            if clean_key.lower() in f.lower() and f.endswith(".mp4"):
                res = send_from_directory(OUTPUT_DIR, f, mimetype="video/mp4")
                res.headers["Content-Disposition"] = "inline"
                res.headers["X-Content-Type-Options"] = "nosniff"
                return res
    res = send_from_directory(OUTPUT_DIR, filename, mimetype="video/mp4")
    res.headers["Content-Disposition"] = "inline"
    res.headers["X-Content-Type-Options"] = "nosniff"
    return res

@app.route("/api/artist-photo/<audio_id>")
def serve_artist_photo(audio_id):
    track = TRACK_STORE.get(audio_id)
    if track and track.get("artist_info") and track["artist_info"].get("local_photo"):
        photo_path = track["artist_info"]["local_photo"]
        if os.path.exists(photo_path):
            return send_file(photo_path, mimetype="image/jpeg")
            
    # Default placeholder
    from PIL import Image, ImageDraw
    img = Image.new("RGB", (600, 600), (30, 25, 45))
    draw = ImageDraw.Draw(img)
    draw.ellipse([(150, 150), (450, 450)], fill=(70, 60, 110))
    temp_placeholder = os.path.join(CACHE_ARTISTS_DIR, "placeholder.jpg")
    img.save(temp_placeholder, quality=90)
    return send_file(temp_placeholder, mimetype="image/jpeg")

@app.route("/api/upload-audio", methods=["POST"])
def upload_audio():
    if "audio" not in request.files:
        return jsonify({"error": "Аудиофайл не найден в запросе"}), 400
        
    audio_file = request.files["audio"]
    if not audio_file or audio_file.filename == "":
        return jsonify({"error": "Файл не выбран"}), 400

    audio_id = str(uuid.uuid4())[:8]
    raw_name = os.path.basename(audio_file.filename)
    clean_original_name = re.sub(r"[^\w\-_\. ]", "", raw_name).strip()
    if not clean_original_name:
        clean_original_name = "audio.mp3"
    elif not clean_original_name.lower().endswith(('.mp3', '.wav', '.m4a', '.flac', '.ogg')):
        clean_original_name += ".mp3"

    saved_filename = f"{audio_id}_{clean_original_name}"
    audio_path = os.path.join(CACHE_AUDIO_DIR, saved_filename)
    audio_file.save(audio_path)

    print(f"[Server] Saved uploaded audio to {audio_path}")

    # 1. Извлекаем имя артиста и название трека
    artist_name, track_title = parse_track_info_from_filename(audio_file.filename)
    print(f"[Server] Extracted metadata: Artist='{artist_name}', Title='{track_title}'")

    # 2. Ищем профиль артиста и скачиваем HD фото для точного определения жанра
    try:
        artist_info = search_artist_info(artist_name)
    except Exception as e:
        print(f"[Server] Artist search error: {e}")
        artist_info = {
            "name": artist_name,
            "photo_url": None,
            "local_photo": None,
            "genres": ["Pop"]
        }

    # 3. Анализируем аудио и автоматически синтезируем вайб и атмосферу
    try:
        analysis_data = analyze_audio_file(
            audio_path,
            artist_name=artist_name,
            track_title=track_title,
            genres=artist_info.get("genres", [])
        )
    except Exception as e:
        print(f"[Server] Audio analysis error: {e}")
        return jsonify({"error": f"Ошибка анализа аудио: {str(e)}"}), 500

    # Сохраняем в реестре
    TRACK_STORE[audio_id] = {
        "audio_id": audio_id,
        "filename": saved_filename,
        "audio_path": audio_path,
        "artist_name": artist_name,
        "track_title": track_title,
        "analysis": analysis_data,
        "artist_info": artist_info
    }

    return jsonify({
        "success": True,
        "audio_id": audio_id,
        "audio_url": f"/audio/{saved_filename}",
        "title": track_title,
        "artist": artist_name,
        "analysis": analysis_data,
        "artist_info": artist_info
    })

GEN_TASKS = {}
CACHE_PREVIEWS_DIR = os.path.join(BASE_DIR, "cache", "previews")
os.makedirs(CACHE_PREVIEWS_DIR, exist_ok=True)

import threading
from PIL import Image

def _run_generation_thread(task_id, track, vibe_preset, engine_to_use, engine_label, lyrics, duration=10):
    if isinstance(vibe_preset, dict):
        vibe_data = vibe_preset
        safe_vibe = vibe_data.get("vibe_id", "videoshot")
    else:
        vibe_data = track.get("analysis", {}).get("vibe", vibe_preset)
        safe_vibe = re.sub(r"[^\w]", "_", str(vibe_preset))[:20].lower()

    video_filename = f"videoshot_{track['audio_id']}_{safe_vibe}_{int(time.time())}.mp4"
    output_video_path = os.path.join(OUTPUT_DIR, video_filename)
    preview_img_path = os.path.join(CACHE_PREVIEWS_DIR, f"{task_id}.jpg")

    def progress_cb(stage_msg, pct, f_idx=0, total_frames=300):
        GEN_TASKS[task_id]["progress"] = pct
        GEN_TASKS[task_id]["frame"] = f_idx + 1
        GEN_TASKS[task_id]["total_frames"] = total_frames
        GEN_TASKS[task_id]["stage"] = str(stage_msg)
        
        # Обновляем превью-кадр в реальном времени
        latest_prev = os.path.join(CACHE_PREVIEWS_DIR, "latest_preview.jpg")
        if os.path.exists(latest_prev):
            import shutil
            try:
                shutil.copy2(latest_prev, preview_img_path)
                GEN_TASKS[task_id]["has_preview"] = True
            except Exception:
                pass

    try:
        GEN_TASKS[task_id]["stage"] = "Инициализация конвейера..."
        cover_image_path = track["artist_info"].get("local_photo")

        if engine_to_use == "local_ai":
            GEN_TASKS[task_id]["stage"] = f"Запуск локальной видео-нейросети LTX-Video на вашей RTX 4060..."
            if not cover_image_path or not os.path.exists(cover_image_path):
                cover_image_path = os.path.join(CACHE_ARTISTS_DIR, f"{track['audio_id']}_cover.jpg")
                img = Image.new("RGB", (1000, 1000), (20, 20, 35))
                img.save(cover_image_path)

            def local_progress(stage, pct):
                GEN_TASKS[task_id]["stage"] = stage
                GEN_TASKS[task_id]["progress"] = pct

            prompt_text = vibe_data.get("director_prompt") if isinstance(vibe_data, dict) else str(vibe_data)
            try:
                generate_local_videoshot(
                    image_path=cover_image_path,
                    prompt=prompt_text,
                    audio_path=track["audio_path"],
                    output_path=output_video_path,
                    duration=duration,
                    progress_callback=local_progress
                )
            except Exception as loc_err:
                print(f"[Server] Local AI error: {loc_err}. Falling back to NVENC Canvas...")
                GEN_TASKS[task_id]["stage"] = f"Локальная нейросеть: {loc_err}. Фоллбек на NVENC Canvas..."
                render_neural_videoshot(
                    audio_path=track["audio_path"],
                    track_title=track["track_title"],
                    artist_name=track["artist_name"],
                    audio_features=track["analysis"],
                    artist_info=track["artist_info"],
                    cover_image_path=cover_image_path,
                    output_video_path=output_video_path,
                    duration=float(duration),
                    progress_callback=progress_cb
                )
        elif engine_to_use == "minimax":
            GEN_TASKS[task_id]["stage"] = f"Отправка задачи в MiniMax H3 ({duration}s)..."
            if not cover_image_path or not os.path.exists(cover_image_path):
                cover_image_path = os.path.join(CACHE_ARTISTS_DIR, f"{track['audio_id']}_cover.jpg")
                img = Image.new("RGB", (1000, 1000), (20, 20, 35))
                img.save(cover_image_path)

            def mm_progress(stage, pct):
                GEN_TASKS[task_id]["stage"] = stage
                GEN_TASKS[task_id]["progress"] = pct

            try:
                generate_minimax_videoshot(
                    image_path=cover_image_path,
                    audio_path=track["audio_path"],
                    track_title=track["track_title"],
                    artist_name=track["artist_name"],
                    bpm=track["analysis"].get("bpm", 120),
                    vibe_preset=vibe_data,
                    lyrics=lyrics,
                    output_path=output_video_path,
                    duration=duration,
                    progress_callback=mm_progress
                )
            except Exception as mm_err:
                print(f"[Server] MiniMax error: {mm_err}. Falling back to RTX 4060 Canvas...")
                GEN_TASKS[task_id]["stage"] = f"MiniMax: {mm_err}. Фоллбек на локальный RTX 4060 NVENC..."
                render_neural_videoshot(
                    audio_path=track["audio_path"],
                    track_title=track["track_title"],
                    artist_name=track["artist_name"],
                    audio_features=track["analysis"],
                    artist_info=track["artist_info"],
                    cover_image_path=cover_image_path,
                    output_video_path=output_video_path,
                    duration=float(duration),
                    progress_callback=progress_cb
                )
        elif engine_to_use == "google_flow":
            GEN_TASKS[task_id]["stage"] = f"Отправка задачи в Google Flow (Veo 3.1, {duration}s)..."
            if not cover_image_path or not os.path.exists(cover_image_path):
                cover_image_path = os.path.join(CACHE_ARTISTS_DIR, f"{track['audio_id']}_cover.jpg")
                img = Image.new("RGB", (1000, 1000), (20, 20, 35))
                img.save(cover_image_path)

            def gf_progress(stage, pct):
                GEN_TASKS[task_id]["stage"] = stage
                GEN_TASKS[task_id]["progress"] = pct

            try:
                generate_google_flow_videoshot(
                    image_path=cover_image_path,
                    audio_path=track["audio_path"],
                    track_title=track["track_title"],
                    artist_name=track["artist_name"],
                    bpm=track["analysis"].get("bpm", 120),
                    vibe_preset=vibe_data,
                    lyrics=lyrics,
                    output_path=output_video_path,
                    duration=duration,
                    progress_callback=gf_progress
                )
            except Exception as gf_err:
                print(f"[Server] Google Flow error: {gf_err}. Falling back to RTX 4060 Multi-Shot...")
                GEN_TASKS[task_id]["stage"] = f"Google Flow: {gf_err}. Фоллбек на локальный RTX 4060 NVENC..."
                render_neural_videoshot(
                    audio_path=track["audio_path"],
                    track_title=track["track_title"],
                    artist_name=track["artist_name"],
                    audio_features=track["analysis"],
                    artist_info=track["artist_info"],
                    cover_image_path=cover_image_path,
                    output_video_path=output_video_path,
                    duration=float(duration),
                    progress_callback=progress_cb
                )
        else:
            render_neural_videoshot(
                audio_path=track["audio_path"],
                track_title=track["track_title"],
                artist_name=track["artist_name"],
                audio_features=track["analysis"],
                artist_info=track["artist_info"],
                cover_image_path=cover_image_path,
                output_video_path=output_video_path,
                duration=12.0,
                progress_callback=progress_cb
            )

        if os.path.exists(output_video_path):
            GEN_TASKS[task_id]["status"] = "completed"
            GEN_TASKS[task_id]["progress"] = 100
            GEN_TASKS[task_id]["stage"] = "Готово! Видео-шот успешно синтезирован."
            GEN_TASKS[task_id]["video_url"] = f"/videos/{video_filename}"
        else:
            GEN_TASKS[task_id]["status"] = "error"
            GEN_TASKS[task_id]["error"] = "Не удалось скомпилировать видеофайл на диске."

    except Exception as e:
        import traceback
        traceback.print_exc()
        GEN_TASKS[task_id]["status"] = "error"
        GEN_TASKS[task_id]["error"] = str(e)


@app.route("/api/generate", methods=["POST"])
def generate_videoshot():
    data = request.get_json(force=True)
    if not data or "audio_id" not in data:
        return jsonify({"error": "Требуется audio_id"}), 400

    audio_id = data["audio_id"]
    track = TRACK_STORE.get(audio_id)
    if not track:
        return jsonify({"error": f"Трек с audio_id {audio_id} не найден. Загрузите файл заново."}), 404

    vibe_data = data.get("vibe") or data.get("vibe_preset") or track["analysis"].get("vibe") or track["analysis"].get("vibe_preset", "videoshot")
    requested_engine = data.get("engine", "minimax")
    lyrics = data.get("lyrics", "")
    try:
        duration = int(data.get("duration", 10))
    except Exception:
        duration = 10
    if duration not in (6, 10, 15):
        duration = 10

    if requested_engine in ("rtx_gpu", "local_ai"):
        engine_to_use = "rtx_gpu"
        engine_label = f"RTX 4060 Multi-Shot Cinema ({duration}s)"
        init_stage = "Сборка мульти-шот видеоряда на RTX 4060..."
    elif requested_engine == "minimax":
        engine_to_use = "minimax"
        engine_label = f"MiniMax H3 ({duration}s Клип)"
        init_stage = f"Подготовка задачи MiniMax H3 ({duration}s)..."
    elif requested_engine == "google_flow":
        engine_to_use = "google_flow"
        engine_label = f"Google Flow (Veo 3.1, {duration}s)"
        init_stage = f"Подготовка задачи Google Flow Veo 3.1 ({duration}s)..."
    else:
        engine_to_use = "rtx_gpu"
        engine_label = f"RTX 4060 Multi-Shot Cinema ({duration}s)"
        init_stage = "Сборка мульти-шот видеоряда на RTX 4060..."

    task_id = str(uuid.uuid4())[:8]
    GEN_TASKS[task_id] = {
        "task_id": task_id,
        "status": "rendering",
        "progress": 0,
        "frame": 0,
        "total_frames": int(duration * 30),
        "stage": init_stage,
        "has_preview": False,
        "video_url": None,
        "engine_used": engine_label,
        "error": None
    }

    t = threading.Thread(
        target=_run_generation_thread,
        args=(task_id, track, vibe_data, engine_to_use, engine_label, lyrics, duration),
        daemon=True
    )
    t.start()

    return jsonify({
        "success": True,
        "task_id": task_id,
        "engine_used": engine_label
    })


@app.route("/api/task-status/<task_id>", methods=["GET"])
def task_status(task_id):
    task = GEN_TASKS.get(task_id)
    if not task:
        return jsonify({"error": "Задача не найдена"}), 404

    resp = {
        "task_id": task_id,
        "status": task["status"],
        "progress": task["progress"],
        "frame": task["frame"],
        "total_frames": task["total_frames"],
        "stage": task["stage"],
        "has_preview": task["has_preview"],
        "preview_url": f"/api/task-preview/{task_id}?t={time.time()}" if task["has_preview"] else None,
        "video_url": task.get("video_url"),
        "engine_used": task.get("engine_used"),
        "error": task.get("error")
    }
    return jsonify(resp)


@app.route("/api/task-preview/<task_id>", methods=["GET"])
def task_preview(task_id):
    preview_img_path = os.path.join(CACHE_PREVIEWS_DIR, f"{task_id}.jpg")
    if os.path.exists(preview_img_path):
        res = send_file(preview_img_path, mimetype="image/jpeg")
        res.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
        return res
    return jsonify({"error": "No preview yet"}), 404


@app.route("/api/load-sample", methods=["POST"])
def load_sample():
    data = request.get_json(force=True) or {}
    sample_key = data.get("sample", "barskih")
    
    samples_map = {
        "barskih": {
            "path": r"C:\Users\Smoze\aura-player\Sonivo\incoming\dist\MAX_BARSKIH.mp3",
            "artist": "Макс Барских",
            "title": "Берега"
        },
        "avariya": {
            "path": r"C:\Users\Smoze\aura-player\Sonivo\incoming\dist\Diskoteka_Avariya_-_KUKLA_Remix_2026.mp3",
            "artist": "Дискотека Авария",
            "title": "Кукла (Remix)"
        }
    }
    
    chosen = samples_map.get(sample_key, samples_map["barskih"])
    if not os.path.exists(chosen["path"]):
        return jsonify({"error": f"Семпл не найден на диске: {chosen['path']}"}), 404

    import shutil
    audio_id = str(uuid.uuid4())[:8]
    filename = f"{audio_id}_{os.path.basename(chosen['path'])}"
    dest_path = os.path.join(CACHE_AUDIO_DIR, filename)
    shutil.copy2(chosen["path"], dest_path)

    artist_info = search_artist_info(chosen["artist"])
    analysis_data = analyze_audio_file(
        dest_path,
        artist_name=chosen["artist"],
        track_title=chosen["title"],
        genres=artist_info.get("genres", [])
    )

    TRACK_STORE[audio_id] = {
        "audio_id": audio_id,
        "filename": filename,
        "audio_path": dest_path,
        "artist_name": chosen["artist"],
        "track_title": chosen["title"],
        "analysis": analysis_data,
        "artist_info": artist_info
    }

    return jsonify({
        "success": True,
        "audio_id": audio_id,
        "audio_url": f"/audio/{filename}",
        "title": chosen["title"],
        "artist": chosen["artist"],
        "analysis": analysis_data,
        "artist_info": artist_info
    })


@app.route("/api/regenerate-vibe", methods=["POST"])
def regenerate_vibe():
    data = request.get_json(force=True) or {}
    audio_id = data.get("audio_id")
    variation_index = int(data.get("variation_index", 1))
    track = TRACK_STORE.get(audio_id)
    if not track:
        return jsonify({"error": "Трек не найден"}), 404

    analysis = track["analysis"]
    new_vibe = detect_track_vibe(
        bpm=analysis.get("bpm", 120),
        energy=analysis.get("energy", 0.6),
        brightness=analysis.get("brightness", 0.5),
        bass_ratio=analysis.get("bass_ratio", 1.0),
        key_str=analysis.get("key", "C Minor"),
        key_mode=analysis.get("key_mode", "Minor"),
        artist_name=track["artist_name"],
        track_title=track["track_title"],
        genres=track["artist_info"].get("genres", []),
        variation_index=variation_index
    )
    track["analysis"]["vibe"] = new_vibe
    track["analysis"]["vibe_preset"] = new_vibe["title"]
    track["analysis"]["vibe_description"] = new_vibe["mood"]

    return jsonify({
        "success": True,
        "vibe": new_vibe
    })


@app.route("/api/config", methods=["GET", "POST"])
def manage_config():
    from minimax_client import get_saved_minimax_key, save_minimax_key
    if request.method == "POST":
        data = request.get_json(force=True) or {}
        if "minimax_api_key" in data:
            save_minimax_key(data["minimax_api_key"])
        return jsonify({"success": True})
    else:
        return jsonify({"minimax_api_key": get_saved_minimax_key()})


@app.route("/api/google-flow/config", methods=["GET", "POST"])
def manage_google_flow_config():
    if request.method == "POST":
        data = request.get_json(force=True) or {}
        save_google_flow_config(data)
        return jsonify({"success": True, "config": get_google_flow_config()})
    else:
        return jsonify(get_google_flow_config())


# Endpoint специально для мобильного приложения Sonivo iOS
@app.route("/api/mobile/render-videoshot", methods=["POST"])
def mobile_render():
    """
    Прямой REST API для iOS приложения:
    Принимает multipart аудио и параметры, сразу рендерит 9:16 видео-шот и возвращает URL.
    """
    if "audio" not in request.files:
        return jsonify({"error": "No audio file provided"}), 400
        
    audio_file = request.files["audio"]
    audio_id = str(uuid.uuid4())[:8]
    audio_path = os.path.join(CACHE_AUDIO_DIR, f"mobile_{audio_id}.mp3")
    audio_file.save(audio_path)

    artist_name = request.form.get("artist", "Featured Artist")
    track_title = request.form.get("title", "Sonivo Sound")
    vibe = request.form.get("vibe", "Neon Drive")

    analysis_data = analyze_audio_file(audio_path)
    artist_info = search_artist_info(artist_name)
    cover_image_path = artist_info.get("local_photo")

    video_filename = f"mobile_videoshot_{audio_id}.mp4"
    output_video_path = os.path.join(OUTPUT_DIR, video_filename)

    render_neural_videoshot(
        audio_path=audio_path,
        track_title=track_title,
        artist_name=artist_name,
        audio_features=analysis_data,
        artist_info=artist_info,
        cover_image_path=cover_image_path,
        output_video_path=output_video_path,
        duration=12.0
    )

    host = request.host_url.rstrip("/")
    return jsonify({
        "success": True,
        "video_url": f"{host}/videos/{video_filename}",
        "duration": 12.0,
        "bpm": analysis_data.get("bpm")
    })

if __name__ == "__main__":
    print("=" * 65)
    print("🚀 SONIVO VIDEOSHOT NEURAL STUDIO SERVER")
    print("   Running on: http://localhost:5055")
    print("   GPU Accelerator: NVIDIA GeForce RTX 4060 (NVENC 30fps 1080x1920)")
    print("=" * 65)
    app.run(host="0.0.0.0", port=5055, debug=False)
