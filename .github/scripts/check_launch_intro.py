"""Run the real native launch timing/lifetime model, without CoreHaptics hardware."""
from pathlib import Path
import subprocess
import tempfile

def verify_launch_intro(root):
    code='''
import Foundation
import CoreText
@main struct Checks {
    @MainActor static func main() {
        let fontName = SonivoLaunchTypography.prepare()
        precondition(fontName == "SonivoResonanceSerif", "Offline brand font did not register")
        precondition(SonivoLaunchTypography.prepare() == fontName, "Font was not cached")
        let font = CTFontCreateWithName(fontName! as CFString, 68, nil)
        var characters = Array("SONIVO".utf16)
        let glyphCount = characters.count
        var glyphs = [CGGlyph](repeating: 0, count: glyphCount)
        precondition(CTFontGetGlyphsForCharacters(font, &characters, &glyphs, glyphCount))
        precondition(glyphs.allSatisfy { $0 != 0 }, "Brand glyph fallback")
        precondition(CTFontCopyPostScriptName(font) as String == fontName!)
        var startup = SonivoStartupGate()
        precondition(startup.claim())
        precondition(!startup.claim(), "Recreated host/resume replayed startup")
        // A new process has a fresh in-memory gate. Cache/account/network state
        // cannot suppress the intro because it is not an input to this gate.
        var nextProcess = SonivoStartupGate()
        precondition(nextProcess.claim(), "New cold launch did not show intro")
        precondition(!nextProcess.claim(), "Same-process resume replayed intro")
        precondition(SonivoBrandLaunchMotion.duration == 4.2)
        precondition(SonivoBrandLaunchMotion.hapticOnsets.count == 3)
        for strength in SonivoBrandLaunchMotion.hapticStrengths { precondition(strength > 0 && strength <= 0.70) }
        for t in stride(from: 0.0, through: 4.2, by: 1.0 / 120.0) {
            let values = [SonivoBrandLaunchMotion.signature(t), SonivoBrandLaunchMotion.contour(t),
                          SonivoBrandLaunchMotion.name(t), SonivoBrandLaunchMotion.tagline(t),
                          SonivoBrandLaunchMotion.opacity(t)]
            for value in values { precondition(value.isFinite && value >= 0 && value <= 1) }
            for index in 0..<5 {
                let amount = SonivoBrandLaunchMotion.bar(t, index: index)
                precondition(amount.isFinite && amount >= 0 && amount <= 1)
            }
            precondition(SonivoBrandLaunchMotion.pulse(t).isFinite)
        }
        precondition(SonivoBrandLaunchMotion.contour(1.46) > 0.999)
        precondition(SonivoBrandLaunchMotion.opacity(4.2) == 0)
        var session=SonivoLaunchSession()
        precondition(!session.begin(isActive:false,isPlaying:false))
        precondition(!session.hasStarted && !session.isFinished)
        precondition(session.begin(isActive:true,isPlaying:false))
        precondition(!session.begin(isActive:true,isPlaying:false))
        session.finish()
        precondition(!session.begin(isActive:true,isPlaying:false),"Background resume replayed intro")
        var playback=SonivoLaunchSession()
        precondition(!playback.begin(isActive:true,isPlaying:true) && playback.isFinished)
        var skipped=SonivoLaunchSession(); skipped.finish()
        precondition(!skipped.begin(isActive:true,isPlaying:false),"External playback/skip ignored")
        precondition(SonivoLaunchMotion.duration == 3.0 && SonivoLaunchMotion.reducedDuration < 0.5)
        precondition(abs(SonivoLaunchMotion.exitTransitionDuration - 0.45) < 1e-12)
        precondition(SonivoLaunchMotion.hapticOnsets.count == 3)
        precondition(SonivoLaunchMotion.hapticOnsets.count == SonivoLaunchMotion.hapticStrengths.count)
        for onset in SonivoLaunchMotion.hapticOnsets {
            precondition(onset >= 0 && onset <= SonivoLaunchMotion.fadeStart)
        }
        for strength in SonivoLaunchMotion.hapticStrengths { precondition(strength > 0 && strength <= 1) }
        for time in [-100.0, 0, 0.7, 2.2, 4.8, 100, .nan, .infinity] {
            let surface = SonivoLaunchMotion.surfaceTime(at: time)
            precondition(surface.isFinite && surface >= 0 && surface <= 3.0)
            let values = [SonivoLaunchMotion.ringOpacity(at: time), SonivoLaunchMotion.wordOpacity(at: time),
                          SonivoLaunchMotion.taglineOpacity(at: time), SonivoLaunchMotion.lightProgress(at: time),
                          SonivoLaunchMotion.lightOpacity(at: time), SonivoLaunchMotion.exitProgress(at: time)]
            for value in values { precondition(value.isFinite && value >= 0 && value <= 1) }
        }
        for fps in [30, 60, 120] {
            var priorRing = 0.0, priorWord = 0.0, priorTagline = 0.0, priorExit = 0.0
            for frame in 0...(fps * 6) {
                let t = Double(frame) / Double(fps)
                let ring = SonivoLaunchMotion.ringOpacity(at: t), word = SonivoLaunchMotion.wordOpacity(at: t)
                let tagline = SonivoLaunchMotion.taglineOpacity(at: t), exit = SonivoLaunchMotion.exitProgress(at: t)
                precondition(ring >= priorRing && word >= priorWord && tagline >= priorTagline && exit >= priorExit)
                let scale = SonivoLaunchMotion.ringScale(at: t), blur = SonivoLaunchMotion.ringBlur(at: t)
                precondition(scale >= 0.98 && scale <= 4.7 && blur == 0)
                priorRing=ring; priorWord=word; priorTagline=tagline; priorExit=exit
            }
        }
        precondition(SonivoLaunchMotion.wordOpacity(at: 0.8) == 0)
        precondition(SonivoLaunchMotion.taglineOpacity(at: 1.4) == 0)
        precondition(SonivoLaunchMotion.lightOpacity(at: 2.5) == 0)
        precondition(SonivoLaunchMotion.hapticSharpnesses.count == 3)
        precondition(SonivoLaunchMotion.hapticStrengths[0] == 1)
        precondition(SonivoLaunchMotion.hapticTravelOnset >= 0)
        precondition(SonivoLaunchMotion.hapticTravelDuration > 0.5)
        precondition(SonivoLaunchMotion.hapticTravelOnset + SonivoLaunchMotion.hapticTravelDuration + 0.004 < SonivoLaunchMotion.hapticOnsets[0])
        precondition(SonivoLaunchMotion.hapticOnsets[0] == 1.12)
        precondition(SonivoLaunchMotion.hapticOnsets[1] == 1.53)
        for t in stride(from: 0.0, through: 3.0, by: 1.0 / 120.0) {
            precondition(SonivoLaunchMotion.wordScale(at: t).isFinite)
            precondition(SonivoLaunchMotion.wordScale(at: t) >= 0.98 && SonivoLaunchMotion.wordScale(at: t) <= 1.7)
            precondition(SonivoLaunchMotion.waveOpacity(at: t) >= 0 && SonivoLaunchMotion.waveOpacity(at: t) <= 0.78)
            precondition(SonivoLaunchMotion.fixationFlash(at: t) >= 0 && SonivoLaunchMotion.fixationFlash(at: t) <= 0.27)
        }
        precondition(SonivoLaunchMotion.ringScale(at: SonivoLaunchMotion.reducedPreviewTime) == 1)
        precondition(SonivoLaunchMotion.wordOpacity(at: SonivoLaunchMotion.reducedPreviewTime) == 1)
        precondition(SonivoLaunchMotion.opacity(at: 0) == 1)
        precondition(SonivoLaunchMotion.opacity(at: SonivoLaunchMotion.duration) == 0)
        for p in [-1.0, 0, 0.25, 0.5, 0.75, 1, 2, .nan, .infinity] {
            let blur = SonivoLaunchMotion.homeRevealBlur(progress: p, reduceMotion: false)
            precondition(blur.isFinite && blur >= 0 && blur <= 6)
            precondition(SonivoLaunchMotion.homeRevealBlur(progress: p, reduceMotion: true) == 0)
        }
        precondition(SonivoLaunchMotion.homeRevealBlur(progress: 0, reduceMotion: false) == 0)
        precondition(SonivoLaunchMotion.homeRevealBlur(progress: 1, reduceMotion: false) == 0)
        print("Resonance font, finite choreography, haptics, lifecycle, bypass, skip and reduced-motion checks passed")
    }
}
'''
    with tempfile.TemporaryDirectory() as d:
        p=Path(d);(p/'Checks.swift').write_text(code)
        built=subprocess.run(['swiftc','-swift-version','6',str(root/'Sonivo/SonivoLaunchMotion.swift'),str(root/'Sonivo/SonivoBrandLaunchMotion.swift'),str(root/'Sonivo/SonivoLaunchTypography.swift'),str(p/'Checks.swift'),'-o',str(p/'checks')],capture_output=True,text=True)
        assert built.returncode==0,built.stderr
        result=subprocess.run([str(p/'checks')],capture_output=True,text=True)
        assert result.returncode==0,result.stdout+result.stderr
        print(result.stdout.strip())
