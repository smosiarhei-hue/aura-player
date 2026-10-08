"""Execute the real preset store under Swift 6 (macOS CI, no UI/network needed)."""
from pathlib import Path
import subprocess
import tempfile


def verify_eq_user_presets(root):
    main=r'''
import Foundation
@main struct Checks {
    @MainActor static func main() throws {
        let suite="sonivo-eq-tests-\(UUID().uuidString)"
        let defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let store=EQUserPresetStore(defaults:defaults)
        let gains: [Float]=[12,6,3,0,-1,-2,0,2,4,-12]
        let saved=try store.save(name:"  Мой бас  ",gains:gains)
        precondition(saved.name=="Мой бас" && saved.gains==gains)
        let reloaded=EQUserPresetStore(defaults:defaults)
        precondition(reloaded.presets==[saved],"Preset did not survive relaunch")
        func rejects(_ action: () throws -> Void) {
            do { try action(); fatalError("Invalid input accepted") } catch { }
        }
        rejects { _ = try reloaded.save(name:"мой бас",gains:gains) }
        rejects { _ = try reloaded.save(name:" ",gains:gains) }
        rejects { _ = try reloaded.save(name:String(repeating:"x",count:65),gains:gains) }
        rejects { _ = try reloaded.save(name:"bad count",gains:[0]) }
        var bad=gains; bad[0] = .nan
        rejects { _ = try reloaded.save(name:"nan",gains:bad) }
        bad[0] = .infinity
        rejects { _ = try reloaded.save(name:"inf",gains:bad) }
        bad[0] = 12.5
        rejects { _ = try reloaded.save(name:"range",gains:bad) }
        precondition(reloaded.presets==[saved],"Rejection changed saved preset")
        try reloaded.delete(id:saved.id)
        precondition(EQUserPresetStore(defaults:defaults).presets.isEmpty)
        let broken=Data("broken archive".utf8)
        defaults.set(broken,forKey:"eq.userPresets.v1")
        let corrupt=EQUserPresetStore(defaults:defaults)
        rejects { _ = try corrupt.save(name:"not overwrite",gains:gains) }
        precondition(defaults.data(forKey:"eq.userPresets.v1")==broken)
        print("Named EQ preset save/relaunch/delete/invalid-input/archive checks passed")
    }
}
'''
    with tempfile.TemporaryDirectory() as d:
        p=Path(d);(p/'Checks.swift').write_text(main)
        built=subprocess.run(['swiftc','-swift-version','6',str(root/'Sonivo/EQUserPresetStore.swift'),str(p/'Checks.swift'),'-o',str(p/'checks')],capture_output=True,text=True)
        assert built.returncode==0,built.stderr
        result=subprocess.run([str(p/'checks')],capture_output=True,text=True)
        assert result.returncode==0,result.stdout+result.stderr
        print(result.stdout.strip())
