"""
Local Neural VideoShot Generator for RTX 4060 (8GB VRAM).
Uses Lightricks LTX-Video / DiT (Diffusion Transformer) Image-to-Video pipeline:
- 100% Free, Runs completely offline on local GPU
- 0 queue, instant VIP GPU execution
- Takes Artist photo + Auto-synthesized Director Prompt
- Generates cinematic 9:16 vertical motion
- Synchronizes with original audio via FFmpeg
"""

import os
import sys
import time
import subprocess
import torch
from PIL import Image

try:
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass

MODEL_ID = "Lightricks/LTX-Video"
_GLOBAL_PIPE = None

def get_or_load_pipeline(progress_callback=None):
    """Ленивая загрузка локальной модели LTX-Video на GPU RTX 4060 с CPU offload."""
    global _GLOBAL_PIPE
    if _GLOBAL_PIPE is not None:
        return _GLOBAL_PIPE

    if progress_callback:
        progress_callback("Инициализация локальной нейросети LTX-Video на RTX 4060...", 10)

    print(f"[LocalNeural] Loading {MODEL_ID} on RTX 4060...")
    from diffusers import LTXImageToVideoPipeline

    dtype = torch.bfloat16 if torch.cuda.is_bf16_supported() else torch.float16
    
    pipe = LTXImageToVideoPipeline.from_pretrained(
        MODEL_ID,
        torch_dtype=dtype,
        low_cpu_mem_usage=True
    )
    
    # Включаем CPU offload для гарантированного умещения в 8 ГБ VRAM
    pipe.enable_model_cpu_offload()
    
    # Оптимизация VAE памяти для 9:16 видео
    if hasattr(pipe, "enable_vae_slicing"):
        pipe.enable_vae_slicing()
    if hasattr(pipe, "enable_vae_tiling"):
        pipe.enable_vae_tiling()

    _GLOBAL_PIPE = pipe
    print(f"[LocalNeural] Pipeline loaded successfully on GPU!")
    return _GLOBAL_PIPE

def generate_local_videoshot(
    image_path: str,
    prompt: str,
    audio_path: str,
    output_path: str,
    duration: int = 6,
    preview_callback = None,
    progress_callback = None
):
    """
    Генерирует 9:16 видео-шот локально на RTX 4060:
    1. Загрузка фото артиста и ресайз под 9:16 (512x768 / 576x1024)
    2. Диффузионный шаг за шагом синтез с live-колбэком прогресса
    3. Экспорт в MP4 и синхронизация аудио через FFmpeg
    """
    start_time = time.time()
    pipe = get_or_load_pipeline(progress_callback)

    if progress_callback:
        progress_callback("Подготовка входного кадра артиста (9:16)...", 20)

    # 1. Загрузка и подготовка 9:16 фото
    input_img = Image.open(image_path).convert("RGB")
    target_w, target_h = 512, 768  # Оптимально для RTX 4060 8GB
    input_img = input_img.resize((target_w, target_h), Image.Resampling.LANCZOS)

    # Кол-во кадров: 24 fps * duration (например 49 кадров = ~2 сек loop или 81 кадр = ~3.5 сек)
    num_frames = 49 if duration <= 6 else 81
    num_steps = 25

    negative_prompt = "worst quality, distorted face, deformed eyes, blurry, low resolution, multiple heads, extra limbs, cartoon, romantic, kissing, watermark, text"

    print(f"[LocalNeural] Starting generation: {target_w}x{target_h}, {num_frames} frames, {num_steps} steps")

    def step_callback(pipe_ref, step_index, timestep, callback_kwargs):
        pct = 25 + int((step_index / num_steps) * 65)
        if progress_callback:
            progress_callback(f"Нейросеть RTX 4060 синтезирует видео: шаг {step_index + 1}/{num_steps}...", pct)
        return callback_kwargs

    if progress_callback:
        progress_callback(f"Старт диффузии на RTX 4060: 0/{num_steps} шагов...", 25)

    with torch.inference_mode():
        output = pipe(
            image=input_img,
            prompt=prompt,
            negative_prompt=negative_prompt,
            width=target_w,
            height=target_h,
            num_frames=num_frames,
            num_inference_steps=num_steps,
            guidance_scale=3.5,
            callback_on_step_end=step_callback
        )

    frames = output.frames[0]
    print(f"[LocalNeural] Generated {len(frames)} frames in {time.time() - start_time:.1f}s")

    if progress_callback:
        progress_callback("Кодирование 9:16 MP4 и сведение с аудио трека...", 92)

    # 2. Экспорт через diffusers / imageio / FFmpeg
    from diffusers.utils import export_to_video
    temp_raw_mp4 = output_path.replace(".mp4", "_local_raw.mp4")
    export_to_video(frames, temp_raw_mp4, fps=24)

    # 3. Сведение с аудио трека через FFmpeg
    cmd = [
        "ffmpeg", "-y",
        "-stream_loop", "-1",
        "-i", temp_raw_mp4,
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
    if os.path.exists(temp_raw_mp4):
        os.remove(temp_raw_mp4)

    if progress_callback:
        progress_callback(f"Готово! Локальный видео-шот сгенерирован за {int(time.time() - start_time)}с.", 100)

    print(f"[LocalNeural] Completed in {time.time() - start_time:.1f}s: {output_path}")
    return output_path
