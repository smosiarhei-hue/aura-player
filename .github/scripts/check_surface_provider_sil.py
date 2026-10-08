"""macOS regression: compile the actual UIKit callback under the app's actor default."""
from pathlib import Path
import re
import subprocess
import tempfile

def verify_surface_provider(root):
    sdk=subprocess.run(['xcrun','--sdk','iphonesimulator','--show-sdk-path'],capture_output=True,text=True,check=True).stdout.strip()
    source=(root/'Sonivo/theme.swift').read_text()
    body=source.split('    private nonisolated static func surface',1)[1].split('    static let bg',1)[0]
    fixed='    private nonisolated static func surface'+body
    baseline=fixed.replace('private nonisolated static func','private static func')
    checks=re.compile(r'swift_task_isCurrentExecutor|swift_task_checkIsolated|swift_task_reportUnexpectedExecutor|hop_to_executor')
    with tempfile.TemporaryDirectory() as d:
        path=Path(d)
        closures={}
        for name,method in [('baseline',baseline),('fixed',fixed)]:
            file=path/(name+'.swift')
            file.write_text('import SwiftUI\nimport UIKit\nenum CrashColorProbe {\n'+method+'\n    static let value=surface(light: .white,dark: .black)\n}\n')
            command=['xcrun','swiftc','-swift-version','6','-default-isolation','MainActor',
                '-strict-concurrency=complete','-target','arm64-apple-ios26.0-simulator','-sdk',sdk,
                '-parse-as-library','-Onone','-emit-sil',str(file)]
            result=subprocess.run(command,capture_output=True,text=True)
            assert result.returncode==0,name+': '+result.stderr[:3000]
            matches=re.findall(r'^// closure #1 in static CrashColorProbe\.surface[^\n]*\n.*?(?=^} // end sil function)',result.stdout,re.M|re.S)
            assert len(matches)==1,name+': expected the actual UIColor dynamic-provider closure'
            closures[name]=matches[0]
        assert checks.search(closures['baseline']), 'Control failed to reproduce inherited executor checks'
        assert not checks.search(closures['fixed']), 'Nonisolated UIColor callback still checks a main executor'
    print('UIKit dynamic surface provider: baseline executor trap guard reproduced; fixed callback has no actor check')
