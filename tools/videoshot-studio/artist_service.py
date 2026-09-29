"""
Artist Service for VideoShot Studio.
Finds official artist photo gallery, background videoshots, genres, and metadata
via Yandex Music & iTunes API.
"""

import os
import sys
import re
import urllib.parse
import requests
from PIL import Image

try:
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass

CACHE_DIR = os.path.join(os.path.dirname(__file__), "cache", "artists")
os.makedirs(CACHE_DIR, exist_ok=True)

def download_and_cache_photo(url: str, dest_path: str):
    try:
        res = requests.get(url, timeout=7)
        if res.status_code == 200 and len(res.content) > 3000:
            with open(dest_path, "wb") as f:
                f.write(res.content)
            with Image.open(dest_path) as img:
                img.verify()
            return dest_path
    except Exception as e:
        print(f"[ArtistService] Download failed for {url}: {e}")
    return None

def download_video_file(url: str, dest_path: str):
    try:
        if os.path.exists(dest_path) and os.path.getsize(dest_path) > 100000:
            return dest_path
        headers = {"User-Agent": "YandexMusic/2026.0 (iPhone; iOS 18.0)"}
        res = requests.get(url, headers=headers, timeout=12, stream=True)
        if res.status_code == 200:
            with open(dest_path, "wb") as f:
                for chunk in res.iter_content(chunk_size=65536):
                    f.write(chunk)
            if os.path.getsize(dest_path) > 50000:
                print(f"[ArtistService] Downloaded official background video: {dest_path}")
                return dest_path
    except Exception as e:
        print(f"[ArtistService] Video download error: {e}")
    return None

def search_single_artist_yandex(clean_name: str):
    """Ищет одного артиста в Яндекс Музыке и достаёт все его фото и фоновое видео."""
    headers = {"User-Agent": "YandexMusic/2026.0 (iPhone; iOS 18.0)"}
    safe_name = "".join(c for c in clean_name if c.isalnum() or c in (" ", "_", "-")).strip()
    
    res_info = {
        "name": clean_name,
        "photos": [],
        "bg_video": None,
        "genres": []
    }

    try:
        ym_url = f"https://api.music.yandex.net/search?text={urllib.parse.quote(clean_name)}&type=artist&page=0"
        ym_res = requests.get(ym_url, headers=headers, timeout=4)
        if ym_res.status_code == 200:
            data = ym_res.json()
            artists = data.get("result", {}).get("artists", {}).get("results", [])
            if artists:
                top = artists[0]
                art_id = top.get("id")
                res_info["name"] = top.get("name", clean_name)
                res_info["genres"] = top.get("genres", [])
                
                # Запрос brief-info с полной медиа-галереей
                detail_url = f"https://api.music.yandex.net/artists/{art_id}/brief-info"
                d_res = requests.get(detail_url, headers=headers, timeout=5)
                if d_res.status_code == 200:
                    b_data = d_res.json().get("result", {})
                    
                    # 1. Проверяем официальный видео-шот
                    bg_video_url = b_data.get("backgroundVideoUrl")
                    if bg_video_url:
                        vid_path = os.path.join(CACHE_DIR, f"{safe_name}_bgvideo.mp4")
                        saved_vid = download_video_file(bg_video_url, vid_path)
                        if saved_vid:
                            res_info["bg_video"] = saved_vid

                    # 2. Скачиваем все фотосессии артиста (allCovers)
                    covers = b_data.get("allCovers", [])
                    for i, c in enumerate(covers):
                        uri = c.get("uri")
                        if uri:
                            photo_url = "https://" + uri.replace("%%", "1000x1000")
                            dest_photo = os.path.join(CACHE_DIR, f"{safe_name}_shot_{i+1}.jpg")
                            p_path = download_and_cache_photo(photo_url, dest_photo)
                            if p_path and p_path not in res_info["photos"]:
                                res_info["photos"].append(p_path)

                    # 3. Дополнительные обложки популярных релизов
                    pop_tracks = b_data.get("popularTracks", [])
                    for j, pt in enumerate(pop_tracks[:3]):
                        t_uri = pt.get("coverUri")
                        if t_uri:
                            p_url = "https://" + t_uri.replace("%%", "1000x1000")
                            dest_rel = os.path.join(CACHE_DIR, f"{safe_name}_rel_{j+1}.jpg")
                            r_path = download_and_cache_photo(p_url, dest_rel)
                            if r_path and r_path not in res_info["photos"]:
                                res_info["photos"].append(r_path)
    except Exception as e:
        print(f"[ArtistService] Yandex error for {clean_name}: {e}")

    return res_info

def search_artist_info(artist_name: str):
    """
    Универсальный поиск медиа артиста (поддерживает дуэты и фиты, напр. Platina & Voskresenskii).
    Возвращает:
    - name: имя
    - local_photo: основное фото
    - photos: список всех доступных кадров/фотосессий артистов для мульти-шота
    - background_video: официальный видео-шот (если есть в Яндекс Музыке)
    - genres: жанры
    """
    clean_name = artist_name.strip()
    if not clean_name:
        return {"name": "Unknown", "photo_url": None, "local_photo": None, "photos": [], "genres": []}

    safe_filename = "".join(c for c in clean_name if c.isalnum() or c in (" ", "_", "-")).rstrip()
    
    # Разбиваем артистов если это фит или совместный трек
    tokens = [t.strip() for t in re.split(r"[,&/]|feat\.|ft\.|\s+", clean_name, flags=re.IGNORECASE) if len(t.strip()) > 2]
    if not tokens:
        tokens = [clean_name]

    all_photos = []
    bg_video = None
    all_genres = []
    resolved_name = clean_name

    for t in tokens:
        info = search_single_artist_yandex(t)
        if info["photos"]:
            all_photos.extend(info["photos"])
        if info["bg_video"] and not bg_video:
            bg_video = info["bg_video"]
        if info["genres"]:
            all_genres.extend(info["genres"])

    # Если через Яндекс фото не нашлись, пробуем iTunes
    if not all_photos:
        try:
            url = f"https://itunes.apple.com/search?term={urllib.parse.quote(sub_artists[0])}&entity=song&limit=3"
            t_res = requests.get(url, timeout=4)
            if t_res.status_code == 200:
                t_data = t_res.json()
                for idx, item in enumerate(t_data.get("results", [])):
                    art = item.get("artworkUrl100", "").replace("100x100bb", "1000x1000bb")
                    if art:
                        dest = os.path.join(CACHE_DIR, f"{safe_filename}_itunes_{idx+1}.jpg")
                        p = download_and_cache_photo(art, dest)
                        if p and p not in all_photos:
                            all_photos.append(p)
        except Exception as e:
            print(f"[ArtistService] iTunes fallback error: {e}")

    primary_photo = all_photos[0] if all_photos else None

    # Убираем дубликаты
    unique_photos = []
    for p in all_photos:
        if p not in unique_photos and os.path.exists(p):
            unique_photos.append(p)

    return {
        "name": resolved_name,
        "photo_url": None,
        "local_photo": primary_photo,
        "photos": unique_photos,
        "background_video": bg_video,
        "genres": list(set(all_genres)) or ["Modern"]
    }
