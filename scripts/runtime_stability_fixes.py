from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AURORA = ROOT / "Aurora"

player = AURORA / "playercore.swift"
text = player.read_text()

old_state = "    private var progressTimer: Timer?\n"
new_state = "    private var progressTimer: Timer?\n    private var spectrumTapInstalled = false\n"
if new_state not in text:
    if old_state not in text:
        raise RuntimeError("Player timer state anchor was not found")
    text = text.replace(old_state, new_state, 1)

old_tap = '''    func installSpectrumTap() {
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, _ in
            SpectrumAnalyzer.ingest(buffer: buffer, sampleRate: buffer.format.sampleRate)
        }
    }'''
new_tap = '''    func installSpectrumTap() {
        guard !spectrumTapInstalled else { return }
        let mixer = engine.mainMixerNode
        let format = mixer.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }

        mixer.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            SpectrumAnalyzer.ingest(buffer: buffer, sampleRate: buffer.format.sampleRate)
        }
        spectrumTapInstalled = true
    }'''
if old_tap not in text and new_tap not in text:
    raise RuntimeError("Spectrum tap implementation was not found")
text = text.replace(old_tap, new_tap)
player.write_text(text)

app = AURORA / "auroraapp.swift"
text = app.read_text()
old_order = '''        .onAppear {
            PlayerCore.shared.installSpectrumTap()
            PlaybackAudioSessionCoordinator.shared.install()
        }'''
new_order = '''        .onAppear {
            PlaybackAudioSessionCoordinator.shared.install()
            PlayerCore.shared.installSpectrumTap()
        }'''
if old_order not in text and new_order not in text:
    raise RuntimeError("RootView audio setup block was not found")
text = text.replace(old_order, new_order)
app.write_text(text)
