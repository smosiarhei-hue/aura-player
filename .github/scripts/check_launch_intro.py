"""Run the real native launch timing/lifetime model, without CoreHaptics hardware."""
from pathlib import Path
import subprocess
import tempfile

def verify_launch_intro(root):
    code='''
import Foundation
@main struct Checks {
    static func main() {
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
        precondition(SonivoLaunchMotion.duration<2 && SonivoLaunchMotion.reducedDuration<0.5)
        precondition(SonivoLaunchMotion.hapticOnsets.count==SonivoLaunchMotion.hapticStrengths.count)
        for onset in SonivoLaunchMotion.hapticOnsets {
            precondition(onset>=0 && onset<SonivoLaunchMotion.fadeStart)
        }
        for index in 0..<6 {
            var previous=0.0
            for frame in 0...240 {
                let time=Double(frame)/120
                let current=SonivoLaunchMotion.letterProgress(at:time,index:index)
                precondition(current>=previous && current<=1 && current.isFinite)
                previous=current
            }
            precondition(previous==1)
        }
        precondition(SonivoLaunchMotion.opacity(at:0)==1)
        precondition(SonivoLaunchMotion.opacity(at:SonivoLaunchMotion.duration)==0)
        precondition(SonivoLaunchMotion.progress(.nan,from:0,duration:1)==0)
        for fps in [30,60,120] {
            let t=Double(fps)*1.3/Double(fps)
            precondition(SonivoLaunchMotion.letterProgress(at:t,index:5)==1)
        }
        print("Sonivo launch timing, lifecycle, playback bypass, skip and reduced-motion checks passed")
    }
}
'''
    with tempfile.TemporaryDirectory() as d:
        p=Path(d);(p/'Checks.swift').write_text(code)
        built=subprocess.run(['swiftc','-swift-version','6',str(root/'Sonivo/SonivoLaunchMotion.swift'),str(p/'Checks.swift'),'-o',str(p/'checks')],capture_output=True,text=True)
        assert built.returncode==0,built.stderr
        result=subprocess.run([str(p/'checks')],capture_output=True,text=True)
        assert result.returncode==0,result.stdout+result.stderr
        print(result.stdout.strip())
