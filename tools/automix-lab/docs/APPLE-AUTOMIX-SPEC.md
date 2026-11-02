# Apple Music AutoMix → Sonivo Automix Lab

Public sources (WWDC 2025 / iOS **26** Music — user said “iOS 27”; product name is AutoMix on iOS 26+).

## Official / support

- [Transition songs in Music on iPhone](https://support.apple.com/guide/iphone/transition-songs-iphadf2fe1f4/ios)
- [Turn AutoMix or Crossfade on or off](https://support.apple.com/en-us/105067)
- [Apple Newsroom — AutoMix](https://www.apple.com/newsroom/2025/06/apple-services-deliver-powerful-features-and-intelligent-updates-to-users-this-fall/)

## Public product rules

| Rule | Apple |
|------|--------|
| Modes | **AutoMix** \| **Crossfade** (1–12s) \| **Off** |
| Default | AutoMix on |
| Analysis | AI on audio features — tempo/key; transition at “perfect moment” |
| DSP | Time stretch + beat match; may trim silence; may fall back to simple crossfade |
| Skip transitions | Albums in order; some genres; incompatible tempo; uploaded / iTunes purchased |
| Hi-Res | AutoMix/Crossfade **off** while Hi-Res Lossless on |
| UX | Up Next toggle (overlapping turntables); **“Mixing”** under scrubber; covers morph A→B |
| Scope | Apple Music catalog; not Apple Intelligence–gated |

## Known user feedback (avoid)

- Cutting 20–60s of outro/intro too aggressively
- Occasional level slam / stutter
- Not reliable on every pair → need **Crossfade fallback**, never hard error

## Sonivo mapping

| Apple | Lab |
|-------|-----|
| AutoMix | `TransitionMode.automix` → **12–16 bar** beatmatched phrase (LOCK→bass→LAND); Acapella Drop when A outro is a bed; Safe Exit stays phrase-length (never a 1s blink) |
| Crossfade | `TransitionMode.crossfade` → equal-power only, fixed seconds |
| Off | Gapless end → next |
| Mixing | Island / quality chip while `state === "mixing"` |
| Turntables | Queue sheet mode control |
| Mashup supersets | Keep as Premium path inside AutoMix (acapellaDrop / Vocal Safe) |

## Ideal acceptance

1. Three modes wired end-to-end on live WaveRadio  
2. AutoMix never throws if plan is late → Crossfade  
3. Continuity: section RMS within ~6 dB; no LAND slam  
4. “Mixing” + cover morph during overlap  
5. Offline ideal MP3 still acapellaDrop-capable  
