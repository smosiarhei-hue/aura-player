# Onest karaoke font

User selected the proposed font direction: study **03, Onest Bold (700)**.

- Upstream: https://github.com/google/fonts/tree/main/ofl/onest
- Original variable font: `Onest[wght].ttf`, SIL Open Font License 1.1.
- This is a full-glyph static 700-weight instance; outline geometry matches the approved preview. Family/style/PostScript names describe the Bold instance, OS/2 weight 700, bold style bits consistent. No fake system-font substitution or restricted Cyrillic subset.
- Binary is versioned as base64 to match the repository's binary-asset workflow. `scripts/materialize_karaoke_font.py` validates SHA-256 and writes `Sonivo/KaraokeFonts/Onest-Bold.ttf` before Resources are copied.
- SHA-256: `063c1194c24eab5d9b547fedcaefed9a5f2e60ec2bb6c039b85963e4223f75a4`.
- XcodeGen copies KaraokeFonts as a folder resource; UIAppFonts registers `KaraokeFonts/Onest-Bold.ttf` / `Onest-Bold`. OFL-Onest.txt is shipped with the font.
- For a manual build, the app pre-build phase runs materialization automatically. It can also be run explicitly with `python3 scripts/materialize_karaoke_font.py`.
- Only displayed lyric typography changes. Existing font-size/Dynamic Type scaling stays with the caller. Navigation, transport controls and unrelated screens keep system typography.
