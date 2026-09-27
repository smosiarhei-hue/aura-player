"""
Audio Analyzer for VideoShot Studio.
Extracts rhythm, BPM, beat timestamps, spectral energy, bass density, key & mode,
and automatically synthesizes an atmospheric cinematic vibe profile based on audio acoustics and artist metadata.
"""

import os
import re
import random
import numpy as np
import librosa

def parse_track_info_from_filename(filename: str):
    """Извлекает артиста и название трека из имени файла."""
    base = os.path.splitext(filename)[0]
    # Убираем системные префиксы вроде UUID в начале (e.g. c3150608_)
    base = re.sub(r"^[a-f0-9]{8}_", "", base)
    base = base.replace("_", " ").replace("-", " - ")
    # Очистка от лишних пробелов
    parts = [p.strip() for p in base.split(" - ") if p.strip()]
    if len(parts) >= 2:
        artist = parts[0]
        title = " - ".join(parts[1:])
    else:
        artist = "Неизвестный артист"
        title = base
    
    # Удаление пометок типа (Remix 2026), [HQ], 77691072 и т.д.
    clean_artist = re.sub(r"\[.*?\]|\(.*?\)", "", artist).strip()
    clean_title = re.sub(r"\[.*?\]|\d{6,}", "", title).strip()
    return clean_artist or artist, clean_title or title

def estimate_key_and_mode(y, sr):
    """Определяет тональность и лад (Major / Minor) через корреляцию профилей Крамхансла-Шмуклера."""
    major_profile = np.array([6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88])
    minor_profile = np.array([6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17])
    major_profile = (major_profile - np.mean(major_profile)) / (np.std(major_profile) + 1e-6)
    minor_profile = (minor_profile - np.mean(minor_profile)) / (np.std(minor_profile) + 1e-6)

    key_names = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B']

    chroma = librosa.feature.chroma_cqt(y=y, sr=sr)
    chroma_mean = np.mean(chroma, axis=1)
    chroma_norm = (chroma_mean - np.mean(chroma_mean)) / (np.std(chroma_mean) + 1e-6)

    best_score = -999
    best_key = 'C'
    best_mode = 'Minor'

    for i in range(12):
        maj_r = np.corrcoef(chroma_norm, np.roll(major_profile, i))[0, 1]
        min_r = np.corrcoef(chroma_norm, np.roll(minor_profile, i))[0, 1]
        if maj_r > best_score:
            best_score = maj_r
            best_key = key_names[i]
            best_mode = 'Major'
        if min_r > best_score:
            best_score = min_r
            best_key = key_names[i]
            best_mode = 'Minor'

    return f"{best_key} {best_mode}", best_key, best_mode

def detect_track_vibe(
    bpm: float,
    energy: float,
    brightness: float,
    bass_ratio: float,
    key_str: str,
    key_mode: str,
    artist_name: str = "",
    track_title: str = "",
    genres: list = None,
    variation_index: int = 0
):
    """
    Автоматически распознает атмосферу и вайб трека по совокупности аудио-характеристик и жанра,
    генерируя профессиональный режиссерский видео-пакет (свет, сцена, камера, промпт).
    """
    genres_lower = [str(g).lower() for g in (genres or [])]
    genres_text = " ".join(genres_lower)
    name_text = f"{artist_name} {track_title}".lower()

    is_hiphop = any(w in genres_text or w in name_text for w in [
        "rap", "hip-hop", "hip hop", "trap", "drill", "phonk", "bass",
        "platina", "платина", "voskresenskii", "воскресенский", "og buda", "буда",
        "kizaru", "кизару", "scally milano", "mayot", "мает", "yanix", "яникс",
        "saluki", "салуки", "macan", "макан", "tape", "трэп", "рэп"
    ]) or (bass_ratio >= 2.5)

    is_dance = any(w in genres_text or w in name_text for w in ["dance", "edm", "club", "house", "techno", "rave", "дискотека авария", "руки вверх", "avariya"])
    is_rock = any(w in genres_text or w in name_text for w in ["rock", "metal", "punk", "alternative", "grunge", "рок", "рок-н-ролл"])
    is_rb = any(w in genres_text or w in name_text for w in ["r&b", "soul", "lo-fi", "chill", "jony", "hammali", "navai"])

    # 1. Трэп / Дрилл / Тяжелый 808
    if is_hiphop or (bass_ratio > 2.5 and energy >= 0.5):
        vibe_id = "heavy_trap"
        clean_track = re.sub(r"\d{6,}", "", track_title).strip()
        
        # Специальный точный кинематографичный промпт для Платины и трэп-артистов
        if "platina" in name_text or "платина" in name_text or "voskresenskii" in name_text or "воскресенский" in name_text:
            scenes = [
                ("Тёмный андеграундный клуб в лучах синих неоновых стробоскопов и дыма",
                 "Холодный синий неон, импульсные стробоскопы, сценический дым и серебряные блики цепей",
                 "Динамичный низкий ракурс с наездом на лицо артиста в тёмных очках в такт 808-басу",
                 "dark underground concert stage with dense stage smoke, cold blue neon backlights, and pulse strobes",
                 "Cinematic 9:16 vertical music video shot of Russian trap artist Platina performing his track 'Bassok' with intense charisma. "
                 "Wearing dark designer sunglasses, black streetwear, and silver chains. Energetic performance moving to the heavy 808 sub-bass beat, "
                 "singing into a stage microphone with confident gestures. Volumetric concert smoke, cold blue and violet spotlights, sharp strobes. "
                 "Dynamic camera pushing in smoothly, photorealistic 8K, live music video performance, natural human movement, sharp facial details, absolutely no romance, no kissing.")
            ]
        else:
            scenes = [
                ("Тёмная урбан-сцена в лучах контровых синих стробоскопов и дыма",
                 "Холодный синий неон, импульсные стробы, густой сценический туман и резкие белые вспышки",
                 "Низкие ракурсы снизу вверх, динамичный широкоугольный объектив 24mm, толчки в ритм бочки 808",
                 "dark underground concert stage with dense stage smoke and haze",
                 f"Cinematic 9:16 vertical music video clip. The musical artist {artist_name} giving an intense solo performance singing into a stage microphone on an underground dark urban stage with cold blue strobes, volumetric smoke, and pulsing lights synchronized to {int(bpm)} BPM heavy 808 trap beat. Dynamic low-angle camera movements. Photorealistic 8K, sharp focus, no romance, no kissing.")
            ]
        scene_ru, light_ru, cam_ru, scene_en, director_prompt_text = scenes[0]
        
        return {
            "vibe_id": vibe_id,
            "title": f"🔥 808 Трэп: {artist_name} — {clean_track}",
            "mood": "Дерзкий, качающий, тёмный underground трэп-вайб",
            "tags": ["#808Bass", "#TrapUnderground", "#LaserBeams", "#StreetVibe", f"#{int(bpm)}BPM", f"#{key_str}"],
            "lighting": light_ru,
            "scene": scene_ru,
            "camera": cam_ru,
            "color_palette": ["#0b0d19", "#00d2ff", "#ff007f", "#ffffff"],
            "director_prompt": director_prompt_text
        }

    # 2. Высоковольтный Рейв / EDM / Фестиваль
    if is_dance or (bpm >= 125 and energy >= 0.70):
        vibe_id = "stadium_rave"
        scenes = [
            ("Главная арена стадионного фестиваля со стенами светодиодных экранов",
             "Многолучевые неоновые лазеры (маджента и ультрамарин), холодные искры и стробоскопы",
             "Энергичные наплывы камеры (dolly zoom), динамичные пролёты в ритм синтезатора",
             "massive stadium festival main stage packed with giant LED screen walls",
             "multi-beam ultraviolet lasers, cold pyro spark fountains, and synchronized strobe lights",
             "energetic dolly zoom push-ins and sweeping camera angles matching the synth drop"),
            ("Футуристический клубный подиум с зеркальным полом",
             "Пульсирующие лазерные сетки, неоновые геометрические арки и стробоскопические вспышки",
             "Вращающаяся на 360 градусов камера вокруг артиста с кинематографичным размытием движения",
             "futuristic mirrored club runway framed by illuminated geometric neon portals",
             "pulsing laser grid, hyper-bright strobes, and vibrant cyan-magenta floodlights",
             "dynamic rotating 360 camera moves with cinematic motion blur on the beat")
        ]
        scene_ru, light_ru, cam_ru, scene_en, light_en, cam_en = scenes[variation_index % len(scenes)]

        return {
            "vibe_id": vibe_id,
            "title": "⚡ Фестивальный Рейв & Стадионный Лазер",
            "mood": "Взрывной, высоковольтный, клубный адреналин",
            "tags": ["#EDMBanger", "#LaserShow", "#FestivalStage", "#HighEnergy", f"#{int(bpm)}BPM"],
            "lighting": light_ru,
            "scene": scene_ru,
            "camera": cam_ru,
            "color_palette": ["#12002b", "#ff0055", "#00f0ff", "#ffe600"],
            "director_prompt": (
                f"Cinematic 9:16 vertical music video clip. The musical artist {artist_name or 'the lead artist'} performing an explosive solo club session, "
                f"performing in {scene_en}, with {light_en} pulsing in sync with {int(bpm)} BPM dance beat. {cam_en}. "
                f"Solo musical singer performance only, high adrenaline, singing into mic, absolutely no kissing, no romantic couple, no romance, photorealistic 8K cinematic music video."
            )
        }

    # 3. Живой Рок / Альтернатива
    if is_rock or (energy > 0.75 and brightness > 0.55):
        vibe_id = "raw_rock"
        scenes = [
            ("Атмосферный рок-клуб со сценическими лампами и винтажными усилителями",
             "Резкие белые лучи прожекторов, сценический туман и тёплый контровой свет ламп накаливания",
             "Живая ручная камера, лёгкая вибрация в такт барабанам, резкие крупные планы эмоций",
             "atmospheric underground rock club with vintage guitar tube amplifiers and floor cables",
             "sharp white stage spotlights, thick haze, and warm incandescent tungsten rim glow",
             "dynamic handheld camera operator movement with rhythmic micro-shakes on drum impacts"),
            ("Заброшенный индустриальный ангар с лучами света сквозь пыль",
             "Драматичный контрастный свет chiaroscuro, лучи солнца сквозь разбитые окна, монохромный дым",
             "Быстрые кинематографичные проводки и акцент на экспрессию вокала",
             "monumental derelict industrial hall with volumetric light shafts cutting through dust",
             "harsh high-contrast chiaroscuro spotlight beams and dense monochromatic smoke",
             "rapid cinematic tracking shots zooming into the singer's passionate facial expression")
        ]
        scene_ru, light_ru, cam_ru, scene_en, light_en, cam_en = scenes[variation_index % len(scenes)]

        return {
            "vibe_id": vibe_id,
            "title": "🎸 Сырой Рок & Концертный Драйв",
            "mood": "Бунтарский, живой, бескомпромиссный драйв",
            "tags": ["#LiveRock", "#Spotlight", "#RawEnergy", "#StageHaze", f"#{int(bpm)}BPM"],
            "lighting": light_ru,
            "scene": scene_ru,
            "camera": cam_ru,
            "color_palette": ["#0a0a0c", "#ff9900", "#ffffff", "#880000"],
            "director_prompt": (
                f"Cinematic 9:16 vertical music video clip. The musical artist {artist_name or 'the singer'} delivering a powerful raw rock vocal performance, "
                f"set inside {scene_en}, with {light_en} pulsating at {int(bpm)} BPM. {cam_en}. "
                f"Solo musical singer performance only, singing into a stage mic with raw passion, absolutely no kissing, no romance, photorealistic 8K cinematic music video."
            )
        }

    # 4. Ночной R&B / Меланхолия / Нуар
    if is_rb or (energy < 0.50 and key_mode == "Minor") or (bpm < 100 and energy < 0.55):
        vibe_id = "nocturnal_rain"
        scenes = [
            ("Залитая дождём ночная улица мегаполиса с мерцающими вывесками",
             "Глубокий сапфировый и аметистовый рассеянный свет, отражения фар на мокром асфальте",
             "Плавный парящий стедикам, выразительные эмоциональные крупные планы поющего артиста",
             "nocturnal rain-slicked city boulevard with softly blurred neon signs and reflections",
             "deep sapphire blue and amethyst purple diffused illumination with wet tarmac glimmers",
             "smooth floating steadicam glide with intimate close-ups capturing the singer's raw emotion"),
            ("Уединённая студия с панорамным окном на ночной дождливый город",
             "Мягкий монохромный свет, игра глубоких теней, неоновые отсветы сквозь капли на стекле",
             "Медленное наплывающее движение камеры, кинематографичная глубина резкости f/1.2",
             "intimate penthouse recording studio with panoramic windows overlooking a rainy metropolis",
             "soft moody monochrome tones, deep shadows, and subtle warm amber accents",
             "slow cinematic creeping push-in camera with ultra-shallow f/1.2 depth of field")
        ]
        scene_ru, light_ru, cam_ru, scene_en, light_en, cam_en = scenes[variation_index % len(scenes)]

        return {
            "vibe_id": vibe_id,
            "title": "🌧️ Ночной Дождь & Меланхоличный R&B",
            "mood": "Глубокий, интимный, чувственный нуарный вайб",
            "tags": ["#MoodyRain", "#MidnightVibe", "#DeepEmotion", "#NeonReflections", f"#{int(bpm)}BPM"],
            "lighting": light_ru,
            "scene": scene_ru,
            "camera": cam_ru,
            "color_palette": ["#050814", "#2c3e50", "#00d2ff", "#795290"],
            "director_prompt": (
                f"Cinematic 9:16 vertical music video clip. The musical artist {artist_name or 'the singer'} in a deeply emotional solo performance, "
                f"standing in {scene_en}, surrounded by {light_en} matching the soulful tempo of {int(bpm)} BPM. {cam_en}. "
                f"Solo musical singer performance only, melancholic aesthetic, singing into vintage microphone, absolutely no kissing, no romantic couple, no romance, photorealistic 8K."
            )
        }

    # 5. Золотой Закат / Тёплый Акустик
    if key_mode == "Major" and energy < 0.65 and brightness > 0.40:
        vibe_id = "golden_hour"
        scenes = [
            ("Открытая крыша на фоне золотого заката над горизонтом",
             "Тёплый контровой свет 3200K, золотистые блики солнца в объективе и мягкий вечерний воздух",
             "Плавные кинематографичные пролёты на закате, мягкий плёночный фокус и красивое боке",
             "open rooftop during a majestic golden sunset over the cityscape horizon",
             "warm 3200K golden backlighting, organic lens flares, and floating sunset dust motes",
             "smooth cinematic jib sweep with creamy f/1.4 vintage lens bokeh"),
            ("Уютный деревянный лофт с винтажным аналоговым студийным оборудованием",
             "Тёплый свет лампочек Эдисона, мягкие закатные тени сквозь жалюзи, ламповый уют",
             "Мягкая ручная камера с кинематографичной стабилизацией и естественной экспозицией",
             "sun-drenched rustic loft with exposed brick walls and warm wood acoustic panels",
             "golden hour sunlight streaming through venetian blinds with warm Edison bulb glow",
             "delicate organic handheld camera drift with natural cinema color grading")
        ]
        scene_ru, light_ru, cam_ru, scene_en, light_en, cam_en = scenes[variation_index % len(scenes)]

        return {
            "vibe_id": vibe_id,
            "title": "🌅 Золотой Закат & Тёплый Соул",
            "mood": "Тёплый, ламповый, искренний, ностальгический",
            "tags": ["#GoldenHour", "#WarmAcoustic", "#VintageVibe", "#SunlightFlares", f"#{int(bpm)}BPM"],
            "lighting": light_ru,
            "scene": scene_ru,
            "camera": cam_ru,
            "color_palette": ["#1c1005", "#ffaa33", "#ff6600", "#fff3e0"],
            "director_prompt": (
                f"Cinematic 9:16 vertical music video clip. The musical artist {artist_name or 'the singer'} in a warm soulful solo performance, "
                f"situated in {scene_en}, with {light_en} pacing along {int(bpm)} BPM rhythm. {cam_en}. "
                f"Solo musical singer performance only, authentic emotional delivery into microphone, absolutely no kissing, no romantic couple, no romance, photorealistic 8K."
            )
        }

    # 6. Ретро Синтвейв / Ночной Неоновый Драйв (Дефолт для мелодичного поп-звучания)
    vibe_id = "midnight_synthwave"
    scenes = [
        ("Неоновый хайвей и стеклянная сцена ночного кибер-мегаполиса",
         "Глубокий пурпурно-циановый дуальный свет, анаморфотные горизонтальные блики и неоновые полосы",
         "Орбитальное кинематографичное движение 360 вокруг артиста, винтажная эстетика плёнки",
         "sleek futuristic glass stage set above a nocturnal neon metropolis highway",
         "dual magenta and cyber-cyan neon edge lighting with razor-sharp horizontal anamorphic lens flares",
         "cinematic orbital 360 camera motion slowly rotating around the performer with retro film grain"),
        ("Стеклянный подиум на крыше небоскрёба с панорамой сияющего города",
         "Футуристические световые колонны, холодный бирюзовый и маджента контурный свет",
         "Плавный cinematic glide с нижних ракурсов к лицу артиста под музыку",
         "high-altitude glass podium surrounded by neon light pillars and skyscraper skyline",
         "cold turquoise and pulsing violet rim light with volumetric smoke plumes",
         "smooth cinematic low-angle glide smoothly rising towards the singing artist on the beat")
    ]
    scene_ru, light_ru, cam_ru, scene_en, light_en, cam_en = scenes[variation_index % len(scenes)]

    return {
        "vibe_id": vibe_id,
        "title": "🌃 Кибер-Неон & Ночной Драйв",
        "mood": "Стильный, пульсирующий, кинематографичный ритм",
        "tags": ["#Synthwave", "#NeonDrive", "#CyberAesthetic", "#AnamorphicFlares", f"#{int(bpm)}BPM"],
        "lighting": light_ru,
        "scene": scene_ru,
        "camera": cam_ru,
        "color_palette": ["#080417", "#ff0077", "#00f0ff", "#7a00ff"],
        "director_prompt": (
            f"Cinematic 9:16 vertical music video clip. The musical artist {artist_name or 'the singer'} performing a solo vocal session, "
            f"situated in {scene_en}, illuminated by {light_en} synced to {int(bpm)} BPM tempo. {cam_en}. "
            f"Solo musical singer performance only, singing into microphone, charismatic presence, absolutely no kissing, no romantic couple, no romance, photorealistic 8K cinematic music video."
        )
    }

def analyze_audio_file(file_path: str, artist_name: str = "", track_title: str = "", genres: list = None, max_duration: float = 90.0):
    """
    Глубокий анализ аудиофайла и синтез вайба:
    - Детекция BPM (темпа)
    - Временные метки ударов (beat timestamps)
    - Огибающая энергии (RMS)
    - Баланс саб-баса (808 / Kick density)
    - Спектральный центроид (яркость)
    - Определение тональности и лада (Key & Major/Minor Mode)
    - Автоматический синтез атмосферы и вайба клипа
    """
    print(f"[AudioAnalyzer] Loading audio: {file_path}")
    y, sr = librosa.load(file_path, sr=22050, duration=max_duration)
    duration = float(librosa.get_duration(y=y, sr=sr))

    # 1. Темп и сетка долей (BPM & Beats)
    onset_env = librosa.onset.onset_strength(y=y, sr=sr)
    tempo, beats = librosa.beat.beat_track(y=y, sr=sr, onset_envelope=onset_env)
    
    if isinstance(tempo, (np.ndarray, list)):
        bpm = float(tempo[0]) if len(tempo) > 0 else 120.0
    else:
        bpm = float(tempo)
    bpm = round(bpm, 1)

    beat_times = librosa.frames_to_time(beats, sr=sr).tolist()

    # 2. Энергетика трека (RMS Energy)
    rms = librosa.feature.rms(y=y)[0]
    avg_energy = float(np.mean(rms))
    normalized_energy = min(1.0, max(0.1, avg_energy * 5.0))

    # 3. Баланс саб-баса (STFT 20-250 Hz)
    S = np.abs(librosa.stft(y))
    freqs = librosa.fft_frequencies(sr=sr)
    bass_mask = (freqs >= 20) & (freqs <= 250)
    bass_energy = float(np.mean(S[bass_mask, :])) if np.any(bass_mask) else 0.0
    total_energy = float(np.mean(S)) + 1e-6
    bass_ratio = round(bass_energy / total_energy, 2)

    # 4. Спектральная яркость (Spectral Centroid)
    centroid = librosa.feature.spectral_centroid(y=y, sr=sr)[0]
    avg_centroid = float(np.mean(centroid))
    spectral_brightness = min(1.0, max(0.1, avg_centroid / 4500.0))

    # 5. Тональность и лад (Key & Mode)
    full_key, key_root, key_mode = estimate_key_and_mode(y, sr)

    # 6. Автоматический вайб трека (AI Vibe Detection)
    vibe_profile = detect_track_vibe(
        bpm=bpm,
        energy=normalized_energy,
        brightness=spectral_brightness,
        bass_ratio=bass_ratio,
        key_str=full_key,
        key_mode=key_mode,
        artist_name=artist_name,
        track_title=track_title,
        genres=genres or [],
        variation_index=0
    )

    # 7. Сэмплы формы волны для визуализатора в браузере (100 точек)
    waveform_samples = []
    hop = max(1, len(y) // 100)
    for i in range(0, len(y), hop):
        waveform_samples.append(float(abs(y[i])))
    waveform_samples = waveform_samples[:100]

    return {
        "duration": duration,
        "bpm": bpm,
        "beat_count": len(beat_times),
        "beat_times": beat_times[:120],
        "energy": round(normalized_energy, 2),
        "bass_ratio": bass_ratio,
        "brightness": round(spectral_brightness, 2),
        "key": full_key,
        "key_mode": key_mode,
        "vibe": vibe_profile,
        "vibe_preset": vibe_profile["title"], # для обратной совместимости
        "vibe_description": vibe_profile["mood"],
        "waveform": waveform_samples
    }
