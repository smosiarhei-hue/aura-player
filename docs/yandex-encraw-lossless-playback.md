# Authorized lossless delivery and native playback

Source: https://ym.marshal.dev/api/ and pinned yandex-music 3.2.2 implementation at 9ca132e5c18a72aab779c1fc68c169380a9357d0.

- The signed request includes quality, codecs and transport. Base64 `+` is percent-encoded.
- Raw lossless is used immediately when supplied. If lossless/automatic raw falls back to lossy, a second signed request asks for `encraw` with FLAC codecs.
- Actual `codec` determines lossless; returned `quality` is logged separately. Requested lossless never relabels AAC/MP3.
- Only `flac`/`flac-mp4` encrypted media with a valid 128-bit API-provided key is materialized. AES-128-CTR uses a zero initial counter and big-endian increment, matching upstream decrypt_track.
- Ciphertext is downloaded to a disposable file using native async URLSession cancellation; not progressively streamed. It is decrypted off the UI actor in 65,537-byte chunks. Maximum accepted file 128 MiB; two concurrent downloads; decoded cache 512 MiB. Network resource timeout 180 seconds. Size is checked after download (not a streaming network byte cap).
- A real native FLAC decoder validates plain FLAC; MP4 FLAC requires a playable native AVAsset with FLAC audio format description. Only then is the decoded local URL returned to the native player. Plain FLAC uses AVAudioFile/AVAudioEngine, including the prepared AutoMix lane; playable FLAC-in-MP4 uses AVPlayer. A complete encrypted file must be available before playback, so initial buffering may be longer.
- Cache namespaces include the account generation, protect active/prepared deck files during eviction, and remove stale UUID-namespaced temporary folders at the next app session. OAuth credentials and decryption keys are not written to media/cache metadata or diagnostics. A cancelled/stale account result cannot install playback.
- Offline save preserves FLAC/M4A rather than renaming every download to MP3. Local decoded assets are copied, not downloaded using a file:// URL, including the AutoMix download adapter.
- Lossless wins over lossy sources; higher received bitrate wins among lossy; AAC wins over MP3 on equal bitrate. Direct legacy media/HLS URLs are not parsed as XML.

## Verification
A generated sine FLAC fixture is AES-CTR encrypted independently with Python cryptography. macOS CI verifies CommonCrypto decryption, an independent OpenSSL cross-chunk vector, native FLAC decode and offline AVAudioEngine rendering, missing/invalid key, wrong-key audio rejection, file-size limits, source ordering, account cache isolation and cancellation.

Live tests with the authorized user token previously returned nq/AAC 192 in upstream itself. This feature supports lossless when returned by the authorized API; it does not guarantee the service supplies FLAC or unlock rights. Real API-issued encrypted FLAC still needs an on-device check once available. No API keys, account tokens or catalog audio are included in fixtures.

## Playback recovery (physical report: 1.0.880 could not start songs)

A source-ranking regression preferred signed AAC over the previously used legacy
MP3 at equal bitrate, although response metadata is not evidence of native
playability. Equal-rate comparisons now retain legacy; actual FLAC and genuinely
higher bitrates still take priority. The physical failure cause is not established
without a fresh device report, so this is a conservative recovery patch.

The native player now observes AVPlayerItem.status failures and detects no initial
media advancement after 12 seconds. One recovery per playback generation uses
legacy MP3 only, without repeating signed/encraw requests or changing the saved
quality preference. Concurrent failure callbacks cannot cancel an in-flight retry.
Generation, track, account and item identity guard all asynchronous commits.
If recovery also fails, stop buffering and show an error instead of a silent loop.

Optional signed raw/encraw API probes have 12/6-second request timeouts; legacy
metadata/XML have 15-second timeouts. Complete encraw FLAC materialization remains
bounded by its separate download configuration. Real received quality stays visible.
Swift fixtures execute the actual recovery method with an injected resolver and
cover duplicate failures, one retry, stale item, changed track/generation/account,
pause and offline failure. Device/account testing is still required.
