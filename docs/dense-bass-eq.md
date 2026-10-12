# Dense low-frequency equalizer and compact controls

## Current layout
- 23 actual controls: 30,40,50,60,70,80,90,100,110,120,130,140,150,160,170,180,190,200,210,220,230,240,250 Hz.
- Six existing upper controls: 500,1000,2000,4000,8000,20000 Hz. Total: **29 DSP bands**, not relabeled ten-band UI.
- Bass controls allow -12…+18 dB through 250 Hz; upper controls retain -12…+12 dB. Gain limits are per control, not a guarantee of the total acoustic response of overlapping filters.
- Narrower octave bandwidths in the dense bass region follow neighboring 10Hz centers, including the 250Hz boundary (virtual next center 260Hz rather than 500Hz). Upper peaking bands retain one-octave widths. First/last remain low/high shelves. Native AVAudioUnitEQ, streaming C PCM DSP and alternative master-bus EQ use the same frequency table and widths.
- Vertical columns are 44pt wide (previously 68), gaps 4pt (previously 12), slider travel 230pt (previously 260). Native 44pt touch/adjustable controls, horizontal scroll, 0dB reset and large-text vertical-row fallback remain. All endpoints/frequency labels are generated from the actual table; reset accessibility labels identify the exact frequency.
- UI reads canonical gains directly with index guards; it does not resample/copy 29 values for every binding getter or generate every frequency label per column redraw.

## Migration
- An exact 10-value curve is interpreted as the previous 30/62.5/125/250/500/1k/2k/4k/8k/20k layout and interpolated in log frequency. A 29-value curve is already current and is not remapped again.
- Old pre-octave persisted 20/40/60/90/160/400/1k/2.5k/6k/16k data is first migrated through the prior layout only when its existing v2 flag is absent. Historical exact factory remaps remain guarded; unrelated custom curves are not replaced with a factory curve.
- Personal preset IDs/names/order survive 10→29 migration. Validated archives get a one-time `eq.userPresets.dense29.backup`; main curve gets `eq.gains.dense29.backup`. Corrupt/invalid archives are not overwritten. Modern arrays are validated per-band and saved with all 29 values.
- Factory prototypes are still defined using their familiar 10-value control curve; the EQPreset initializer expands them once to the current table. Consumers receive all 29 values.
- This preserves the nominal control-curve shape/identity, **not an exact acoustic equivalence**: different filter density/bandwidth changes combined response. Fine-tune and save a new preset if needed. There is no automatic factory/maximum-bass activation or headphone calibration claim.

## Verification / limitations
- Actual C filters are compiled and exercised at multiple sample rates, mono/stereo/8-channel layouts, flat/off bypass, finite-output/toggle tests and 100,000 concurrent atomic-mailbox updates covering all 29 bands.
- Independent single-band +6dB measurements exercise 40,70,100,150,200,240,250Hz centers and neighboring-frequency attenuation; they test real coefficients, not a visualization.
- Native Swift fixture validates exact dense centers, migration, backup, IDs, reload idempotence, invalid range/count/NaN/archive rejection.
- Full Xcode/IPA build checks module/array sizes and native UI compilation. No hardware listening, frame-rate, power-consumption or physical bass-feel claim. Strong boosts can distort; system volume/limits are unchanged. Playback continuation logic is untouched in this change.
