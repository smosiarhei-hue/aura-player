"""Compile and execute the actual Swift dismissal policy on macOS CI."""
from pathlib import Path
import subprocess
import tempfile

def verify_player_dismiss(root):
    code='''
@main struct Checks {
    static func main() {
        precondition(PlayerDismissPolicy.canBegin(x: 0, y: 20, requiresScrollTop: true, isAtTop: true))
        precondition(!PlayerDismissPolicy.canBegin(x: 0, y: 20, requiresScrollTop: true, isAtTop: false))
        precondition(PlayerDismissPolicy.canBegin(x: 0, y: 20, requiresScrollTop: false, isAtTop: false))
        precondition(!PlayerDismissPolicy.canBegin(x: 60, y: 20, requiresScrollTop: false, isAtTop: true))
        precondition(!PlayerDismissPolicy.canBegin(x: 0, y: -20, requiresScrollTop: false, isAtTop: true))
        precondition(PlayerDismissPolicy.shouldClose(x: 0, y: 120, predictedY: 120))
        precondition(!PlayerDismissPolicy.shouldClose(x: 0, y: 25, predictedY: 9999))
        precondition(!PlayerDismissPolicy.shouldClose(x: 0, y: 25, predictedY: 40))
        precondition(!PlayerDismissPolicy.shouldClose(x: 150, y: 120, predictedY: 300))
        precondition(!PlayerDismissPolicy.shouldClose(x: 0, y: -10, predictedY: 300))
        precondition(!PlayerDismissPolicy.shouldClose(x: .nan, y: 120, predictedY: 300))
        precondition(!PlayerInteractionPolicy.horizontalIntent(x: 3, y: 0))
        precondition(!PlayerInteractionPolicy.horizontalIntent(x: 30, y: 50))
        precondition(PlayerInteractionPolicy.horizontalIntent(x: 30, y: 2))
        precondition(PlayerInteractionPolicy.trackDirection(x: -30, y: 0, width: 390) == nil)
        precondition(PlayerInteractionPolicy.trackDirection(x: -100, y: 15, width: 390) == 1)
        precondition(PlayerInteractionPolicy.trackDirection(x: 100, y: 15, width: 390) == -1)
        precondition(PlayerInteractionPolicy.trackDirection(x: -100, y: 90, width: 390) == nil)
        precondition(PlayerInteractionPolicy.trackDirection(x: .nan, y: 0, width: 390) == nil)
        precondition(PlayerInteractionPolicy.draggedFraction(start: 0.5, translation: 20, width: 200) == 0.6)
        precondition(PlayerInteractionPolicy.draggedFraction(start: 0.5, translation: 0, width: 200) == 0.5)
        precondition(PlayerInteractionPolicy.draggedFraction(start: 0.5, translation: 1000, width: 200) == 1)
        precondition(PlayerInteractionPolicy.draggedFraction(start: 0.5, translation: -1000, width: 200) == 0)
        precondition(PlayerInteractionPolicy.draggedFraction(start: .nan, translation: 0, width: 200) == 0)
        func pixels(_ rgba: [UInt8], count: Int) -> [UInt8] { (0..<count).flatMap { _ in rgba } }
        let mostlyGray = pixels([90,90,90,255], count: 80) + pixels([255,0,0,255], count: 20)
        let gray = PlayerArtworkToneMath.dominantRGB(rgba: mostlyGray)!
        precondition(abs(gray.x - gray.y) < 0.0001 && abs(gray.y - gray.z) < 0.0001)
        let mostlyBlue = pixels([20,40,140,255], count: 75) + pixels([255,20,0,255], count: 25)
        precondition(PlayerArtworkToneMath.dominantRGB(rgba: mostlyBlue)!.z > 0.5)
        precondition(PlayerArtworkToneMath.dominantRGB(rgba: [1]) == nil)
        precondition(PlayerArtworkToneMath.dominantRGB(rgba: pixels([0,0,0,0], count: 20)) == nil)
        let black = PlayerArtworkToneMath.dominantRGB(rgba: pixels([0,0,0,255], count: 20))!
        precondition(black == SIMD3<Float>(repeating: 0), "Neutral artwork must not acquire a made-up hue")
        print("Player swipe dismissal direction, scroll boundary, short/fast/reversed drag checks passed")
    }
}
'''
    with tempfile.TemporaryDirectory() as d:
        p=Path(d);(p/'Checks.swift').write_text(code)
        built=subprocess.run(['swiftc','-swift-version','6',str(root/'Sonivo/PlayerDismissPolicy.swift'),str(root/'Sonivo/PlayerInteractionPolicy.swift'),str(p/'Checks.swift'),'-o',str(p/'checks')],capture_output=True,text=True)
        assert built.returncode==0,built.stderr
        result=subprocess.run([str(p/'checks')],capture_output=True,text=True)
        assert result.returncode==0,result.stdout+result.stderr
        print(result.stdout.strip())
