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
        precondition(PlayerDismissPolicy.shouldClose(x: 0, y: 111, predictedY: 111))
        precondition(PlayerDismissPolicy.shouldClose(x: 0, y: 25, predictedY: 241))
        precondition(!PlayerDismissPolicy.shouldClose(x: 0, y: 25, predictedY: 40))
        precondition(!PlayerDismissPolicy.shouldClose(x: 150, y: 120, predictedY: 300))
        precondition(!PlayerDismissPolicy.shouldClose(x: 0, y: -10, predictedY: 300))
        precondition(!PlayerDismissPolicy.shouldClose(x: .nan, y: 120, predictedY: 300))
        print("Player swipe dismissal direction, scroll boundary, short/fast/reversed drag checks passed")
    }
}
'''
    with tempfile.TemporaryDirectory() as d:
        p=Path(d);(p/'Checks.swift').write_text(code)
        built=subprocess.run(['swiftc','-swift-version','6',str(root/'Sonivo/PlayerDismissPolicy.swift'),str(p/'Checks.swift'),'-o',str(p/'checks')],capture_output=True,text=True)
        assert built.returncode==0,built.stderr
        result=subprocess.run([str(p/'checks')],capture_output=True,text=True)
        assert result.returncode==0,result.stdout+result.stderr
        print(result.stdout.strip())
