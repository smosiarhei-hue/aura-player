# Path: scripts/test_token_quality.py
"""Comprehensive diagnostic script using yandex-music[crypto] for verifying Lossless (FLAC) encraw and 320 kbps streaming."""

import sys
import urllib.request
from yandex_music import Client
from yandex_music.utils.decrypt import decrypt_track


def audit_token(token: str, test_tracks=None):
    token = token.strip()
    if not test_tracks:
        test_tracks = ["138786924", "112140178", "108848483", "124982635", "84489623"]

    print("=" * 65)
    print("YANDEX MUSIC API QUALITY & TOKEN VERIFICATION")
    print("=" * 65)
    print(f"Token: {token[:12]}...{token[-6:]} (Length: {len(token)})")

    # 1. Initialize Client & Check Account
    try:
        client = Client(token).init()
        account = client.me.account
        plus = client.me.plus
        print("\n[1] Account Status:")
        print(f"  UID: {account.uid}")
        print(f"  Login: {account.login}")
        print(f"  Full Name: {account.full_name}")
        print(f"  Yandex Plus Active: {plus.has_plus if plus else False}")
        if not plus or not plus.has_plus:
            print("  [!] WARNING: Account lacks active Yandex Plus. Lossless and 320 kbps will be limited.")
    except Exception as e:
        print(f"\n[1] Client init failed: {e}")
        return False

    # 2. Test Lossless tracks_file_info with raw and encraw
    print("\n[2] Testing tracks_file_info (Lossless FLAC & encraw decryption):")
    for tid in test_tracks:
        print(f"\n--- Track ID: {tid} ---")
        try:
            track = client.tracks([tid])[0]
            artist_str = ", ".join(a.name for a in track.artists if a.name)
            print(f"  Title: {track.title} - {artist_str}")
        except Exception:
            print(f"  Track metadata lookup skipped for {tid}")

        # Test A: tracks_file_info with transport='raw'
        try:
            info_raw = client.tracks_file_info(tid, quality="lossless", codecs=["flac", "flac-mp4", "aac-mp4", "mp3"], transport="raw")
            if info_raw and info_raw.download_info:
                dl = info_raw.download_info
                print(f"  [RAW Transport] Codec: {dl.codec}, Bitrate: {dl.bitrate} kbps, URL: {dl.url[:65]}...")
            else:
                print("  [RAW Transport] No downloadInfo returned")
        except Exception as e:
            print(f"  [RAW Transport] Error: {e}")

        # Test B: tracks_file_info with transport='encraw' and AES-128-CTR decryption
        try:
            info_enc = client.tracks_file_info(tid, quality="lossless", codecs=["flac", "flac-mp4", "aac-mp4", "mp3"], transport="encraw")
            if info_enc and info_enc.download_info:
                dl = info_enc.download_info
                print(f"  [ENCRAW Transport] Codec: {dl.codec}, Bitrate: {dl.bitrate} kbps, Key: {dl.key}")
                if dl.url and dl.key:
                    # Fetch first 4KB of encrypted stream
                    req = urllib.request.Request(dl.url, headers={"User-Agent": "YandexMusic/1.0", "Range": "bytes=0-4095"})
                    with urllib.request.urlopen(req) as resp:
                        enc_bytes = resp.read()
                        dec_bytes = decrypt_track(enc_bytes, dl.key)
                        header_magic = dec_bytes[:4]
                        print(f"  [Decryption Test] Encrypted bytes: {len(enc_bytes)}, Decrypted bytes: {len(dec_bytes)}")
                        if header_magic == b"fLaC":
                            print(f"  --> VERIFIED: Decrypted stream contains VALID FLAC header ('fLaC')!")
                        elif header_magic.startswith(b"\xff\xf1") or header_magic.startswith(b"\xff\xf9"):
                            print(f"  --> VERIFIED: Decrypted stream contains VALID AAC ADTS header!")
                        elif b"ftyp" in dec_bytes[:16]:
                            print(f"  --> VERIFIED: Decrypted stream contains VALID MP4 (ALAC/AAC) container!")
                        elif header_magic.startswith(b"ID3") or header_magic.startswith(b"\xff\xfb"):
                            print(f"  --> VERIFIED: Decrypted stream contains VALID MP3 header!")
                        else:
                            print(f"  --> Header magic: {header_magic.hex()} ({header_magic})")
            else:
                print("  [ENCRAW Transport] No downloadInfo returned")
        except Exception as e:
            print(f"  [ENCRAW Transport] Error: {e}")

        # Test C: tracks_download_info (check 320 kbps MP3 entries)
        try:
            dl_list = client.tracks_download_info(tid)
            streams = [f"{d.codec.upper()} {d.bitrate_in_kbps}kbps" for d in dl_list]
            print(f"  [Legacy Download-Info] Available: {', '.join(streams)}")
        except Exception as e:
            print(f"  [Legacy Download-Info] Error: {e}")

    print("\n" + "=" * 65)
    print("TOKEN VERIFICATION FINISHED")
    print("=" * 65)
    return True


if __name__ == "__main__":
    if len(sys.argv) > 1:
        audit_token(sys.argv[1])
    else:
        print("Usage: python scripts/test_token_quality.py <OAUTH_TOKEN>")
