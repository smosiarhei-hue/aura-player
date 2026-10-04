# My Wave motion and accessibility plan

## Goal

Preserve the premium, music-reactive character of My Wave while making interaction immediate, interruptible, accessible, and energy-conscious.

## Scope

Files:

- `Sonivo/MyWaveHeroView.swift`
- `Sonivo/MyWaveBackgroundVideoView.swift`
- `Sonivo/WaveShakeOverlayView.swift`
- `Sonivo/AntigravityTransitionManager.swift`
- `Sonivo/theme.swift`
- `Tests/UnitTests` and a new UI-test target

Do not redesign unrelated tabs or change audio-engine behavior in this work item.

## Findings

### High — interactive controls are below the minimum hit size

`MyWaveHeroView` renders the two header buttons at 40×40.

Implementation:

1. Keep the visible circle at 40×40 if that is the desired optical size.
2. Wrap it in a 44×44 or larger content shape.
3. Verify that adjacent hit regions do not overlap.
4. Preserve the existing accessibility labels.

### High — motion behavior lacks an automated accessibility gate

Reduce Motion is read in the hero/background, but the complete My Wave transition is not covered by tests.

Implementation:

1. Extract a small motion-policy value that converts environment state plus scene/playback state into:
   - ambient animation enabled;
   - reactive video updates enabled;
   - card movement enabled;
   - transition style.
2. Unit-test that policy.
3. Add UI smoke tests for Reduce Motion on/off.
4. Under Reduce Motion, replace spatial travel/flip with a short opacity transition; preserve state feedback.

### Medium — motion constants are duplicated

The feature uses several one-off spring responses, damping values, and durations.

Implementation:

1. Define My Wave motion tokens next to the existing `SN` animation tokens.
2. Use a non-bouncy spring for direct controls.
3. Use a restrained spring for the shake gesture.
4. Keep ambient pulse timing separate from interaction timing.
5. Do not use one ambient animation token for buttons or sheets.

### Medium — long ambient work needs lifecycle verification

The artwork aura and video reaction use continuous/repeating updates.

Implementation:

1. Pause all ambient/reactive work when the scene is inactive.
2. Pause it under Reduce Motion.
3. Stop or retarget the artwork loop when playback stops.
4. Confirm no duplicate video player or timeline survives view dismissal.
5. Profile on a physical device with Energy Log for at least five minutes of playback.

### Medium — gesture transitions must remain interruptible

Implementation:

1. Keep live drag values tied 1:1 to the gesture.
2. On release, spring from the presentation value and preserve velocity.
3. Never disable input merely because a transition is running.
4. Allow a reversed gesture to retarget the current transition without jumping.
5. Keep haptic, visual, and audio feedback on the same interaction event.

## Verification

- Header controls have at least 44×44 hit regions.
- VoiceOver announces title, playback state, settings, and wave action in a sensible order.
- Every gesture-only action has a discoverable VoiceOver action or button.
- Reduce Motion removes spatial travel, flip, and continuous reactive scaling.
- Playback stopping also stops or settles ambient animation.
- Backgrounding the app pauses timeline/video work.
- Rapidly reversing gestures does not jump or lock input.
- No frequent control animation exceeds 300 ms without a documented reason.
- No dropped frames during My Wave interaction on a physical 120 Hz device.