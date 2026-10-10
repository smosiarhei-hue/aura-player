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
        precondition(fontName == "SonivoLaunchDisplay", "Offline brand font did not register")
        precondition(SonivoLaunchTypography.prepare() == fontName, "Font was not cached")
        let font = CTFontCreateWithName(fontName! as CFString, 62, nil)
        var characters = Array("Sonivo".utf16)
        let glyphCount = characters.count
        var glyphs = [CGGlyph](repeating: 0, count: glyphCount)
        precondition(CTFontGetGlyphsForCharacters(font, &characters, &glyphs, glyphCount))
        precondition(glyphs.allSatisfy { $0 != 0 }, "Brand glyph fallback")
        precondition(CTFontCopyPostScriptName(font) as String == fontName!)
        for time in [-100.0, 0, 0.7, 2.2, 4.2, 100, .nan, .infinity] {
            let surface = SonivoLaunchMotion.surfaceTime(at: time)
            let drift = SonivoLaunchMotion.atmosphereDrift(at: time)
            precondition(surface.isFinite && surface >= 0 && surface <= 4.2)
            precondition(drift.isFinite && abs(drift) <= 0.075)
        }
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
        precondition(SonivoLaunchMotion.duration==4.2 && SonivoLaunchMotion.reducedDuration<0.5)
        precondition(SonivoLaunchMotion.hapticOnsets.count==4)
        precondition(SonivoLaunchMotion.hapticOnsets.count==SonivoLaunchMotion.hapticStrengths.count)
        precondition(SonivoLaunchMotion.zoomTickOnsets.count==SonivoLaunchMotion.zoomTickStrengths.count)
        for onset in SonivoLaunchMotion.hapticOnsets + SonivoLaunchMotion.zoomTickOnsets {
            precondition(onset>=0 && onset<SonivoLaunchMotion.fadeStart)
        }
        for strength in SonivoLaunchMotion.hapticStrengths + SonivoLaunchMotion.zoomTickStrengths {
            precondition(strength>0 && strength<=1)
        }
        for frame in 0...540 {
            let time=Double(frame)/120
            let focus=SonivoLaunchMotion.focusWeights(at:time)
            precondition(abs(focus.brand+focus.first+focus.second-1)<1e-12)
            for index in 0..<3 {
                precondition(focus.value(for:index)>=0 && focus.value(for:index)<=1)
                let blur=SonivoLaunchMotion.blur(at:time,index:index)
                precondition(blur.isFinite && blur>=0 && blur<=5)
            }
            let impact=SonivoLaunchMotion.impact(at:time)
            precondition(impact.isFinite && impact>=0 && impact<=1)
        }
        for (time,index) in [(0.70,0),(1.78,1),(2.56,2),(3.36,0)] {
            precondition(SonivoLaunchMotion.blur(at:time,index:index)<1e-6,"Tactile lock cue misses clear text")
        }
        for peak in [1.0,1.4,2.2,8.0] {
            var previous=2.2
            for frame in 0...540 {
                let zoom=SonivoLaunchMotion.zoom(at:Double(frame)/120,peak:peak)
                precondition(zoom>=1 && zoom<=2.2 && zoom<=previous+1e-12)
                previous=zoom
            }
            precondition(previous==1,"Zoom did not settle to standard size")
        }
        precondition(SonivoLaunchMotion.zoom(at:0,peak:1.7)==1.7)
        precondition(SonivoLaunchMotion.zoom(at:SonivoLaunchMotion.reducedPreviewTime,peak:1.7)==1)
        precondition(SonivoLaunchMotion.blur(at:SonivoLaunchMotion.reducedPreviewTime,index:0)==0)
        precondition(SonivoLaunchMotion.opacity(at:0)==1)
        precondition(SonivoLaunchMotion.opacity(at:SonivoLaunchMotion.duration)==0)
        precondition(SonivoLaunchMotion.progress(.nan,from:0,duration:1)==0)
        precondition(SonivoLaunchMotion.focusWeights(at:.nan).brand==1)
        for fps in [30,60,120] {
            let time=Double(fps)*3.62/Double(fps)
            precondition(SonivoLaunchMotion.zoom(at:time,peak:1.7)==1)
        }
        print("Sonivo launch True Focus/zoom, tactile cue timing, lifecycle, playback bypass, skip and reduced-motion checks passed")
    }
}
'''
    with tempfile.TemporaryDirectory() as d:
        p=Path(d);(p/'Checks.swift').write_text(code)
        built=subprocess.run(['swiftc','-swift-version','6',str(root/'Sonivo/SonivoLaunchMotion.swift'),str(root/'Sonivo/SonivoLaunchTypography.swift'),str(p/'Checks.swift'),'-o',str(p/'checks')],capture_output=True,text=True)
        assert built.returncode==0,built.stderr
        result=subprocess.run([str(p/'checks')],capture_output=True,text=True)
        assert result.returncode==0,result.stdout+result.stderr
        print(result.stdout.strip())
