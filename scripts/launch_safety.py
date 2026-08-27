from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AURORA = ROOT / "Aurora"

# 1. Cold start must not touch AVAudioSession / AVAudioEngine taps.
app = AURORA / "auroraapp.swift"
text = app.read_text()
old_appear = '''        .onAppear {
            PlaybackAudioSessionCoordinator.shared.install()
            PlayerCore.shared.installSpectrumTap()
        }
'''
if old_appear in text:
    text = text.replace(old_appear, "")
else:
    print("auroraapp.swift: onAppear audio block already removed")
app.write_text(text)

player = AURORA / "playercore.swift"
text = player.read_text()

# 2. Do not activate the audio session at launch; only set the category.
old_configure = '''    private func configureSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
            try session.setActive(true)
        } catch {
            print("AVAudioSession error: \\(error)")
        }
    }'''
new_configure = '''    private func configureSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
        } catch {
            print("AVAudioSession error: \\(error)")
        }
    }'''
if old_configure in text:
    text = text.replace(old_configure, new_configure)
else:
    print("playercore.swift: configureSession already launch-safe")

# 3. Do not start AVAudioEngine in init; start it lazily on playback.
old_engine_start = '''        engine.mainMixerNode.outputVolume = volume
        try? engine.start()
    }'''
new_engine_start = '''        engine.mainMixerNode.outputVolume = volume
        // Engine starts lazily when playback begins.
    }'''
if old_engine_start in text:
    text = text.replace(old_engine_start, new_engine_start)
else:
    print("playercore.swift: engine lazy start already applied")

# 4. Initialize audio session observers and spectrum tap on first playback.
old_toggle = '''    func togglePlay() {
        if currentTrack == nil {'''
new_toggle = '''    func togglePlay() {
        PlaybackAudioSessionCoordinator.shared.install()
        installSpectrumTap()
        if currentTrack == nil {'''
if new_toggle not in text:
    if old_toggle not in text:
        raise RuntimeError("togglePlay anchor was not found")
    text = text.replace(old_toggle, new_toggle, 1)

old_play = '''    func play(_ track: Track, newQueue: [Track]? = nil) {
        if let q = newQueue, q != queue { queue = q }'''
new_play = '''    func play(_ track: Track, newQueue: [Track]? = nil) {
        PlaybackAudioSessionCoordinator.shared.install()
        installSpectrumTap()
        if let q = newQueue, q != queue { queue = q }'''
if new_play not in text:
    if old_play not in text:
        raise RuntimeError("play anchor was not found")
    text = text.replace(old_play, new_play, 1)

old_resume = '''    func resume() {
        guard !isPlaying, currentTrack != nil else { return }'''
new_resume = '''    func resume() {
        guard !isPlaying, currentTrack != nil else { return }
        PlaybackAudioSessionCoordinator.shared.install()
        installSpectrumTap()'''
if new_resume not in text:
    if old_resume not in text:
        raise RuntimeError("resume anchor was not found")
    text = text.replace(old_resume, new_resume, 1)

player.write_text(text)
print("Launch safety applied: audio initializes on first playback.")
