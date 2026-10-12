"""Execute the real preset store under Swift 6 (macOS CI, no UI/network needed)."""
from pathlib import Path
import subprocess
import tempfile


def verify_eq_user_presets(root):
    main=r'''
import Foundation
@main struct Checks {
    @MainActor static func persisted(defaults: UserDefaults) -> (gains: [Float], enabled: Bool) {
__PERSISTED_EQ_BODY__
    }
    @MainActor static func checkPersisted(defaults: UserDefaults) {
        defaults.removeObject(forKey:"eq.layout.compact10")
        defaults.set(true,forKey:"eq.octaveCurve.v2")
        defaults.set(true,forKey:"eq.bassProfiles.v3")
        let dense = EQGainLimits.denseFrequencies.map { $0 == 120 ? Float(6) : 0 }
        defaults.set(try! JSONEncoder().encode(dense),forKey:"eq.gains")
        let first = persisted(defaults:defaults)
        precondition(first.gains.count == 10 && first.gains[2] == 6)
        precondition(defaults.data(forKey:"eq.gains.compact10.backup") != nil)
        precondition(persisted(defaults:defaults).gains == first.gains)
        let canonical: [Float] = [0,0,0,18,0,0,0,0,0,0]
        defaults.set(try! JSONEncoder().encode(canonical),forKey:"eq.gains")
        precondition(persisted(defaults:defaults).gains == canonical,"New 10-band settings must not be migrated twice")
        defaults.removeObject(forKey:"eq.layout.compact10")
        let old: [Float] = [6,4,2,0,0,0,0,0,0,0]
        defaults.set(try! JSONEncoder().encode(old),forKey:"eq.gains")
        let upgraded = persisted(defaults:defaults).gains
        precondition(upgraded == EQGainLimits.normalized(EQGainLimits.resample(old,from:EQGainLimits.legacyFrequencies,to:EQGainLimits.frequencies)))
        precondition(persisted(defaults:defaults).gains == upgraded)
    }

    @MainActor static func main() throws {
        let suite="sonivo-eq-tests-\(UUID().uuidString)"
        let defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let store=EQUserPresetStore(defaults:defaults)
        let gains = EQGainLimits.normalized([12,6,3,0,-1,-2,0,2,4,-12])
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
        bad[0] = 18.5
        rejects { _ = try reloaded.save(name:"range",gains:bad) }
        precondition(reloaded.presets==[saved],"Rejection changed saved preset")
        let strong = EQGainLimits.frequencies.map { $0 <= 250 ? Float(18) : Float(12) }
        let strongPreset = try reloaded.save(name:"Сильный",gains:strong)
        precondition(EQUserPresetStore(defaults:defaults).presets.contains(strongPreset))
        var high = strong; high[4] = 12.5
        rejects { _ = try reloaded.save(name:"High invalid",gains:high) }
        try reloaded.delete(id:strongPreset.id)
        try reloaded.delete(id:saved.id)
        precondition(EQUserPresetStore(defaults:defaults).presets.isEmpty)
        let legacy = SavedEQPreset(id:UUID(),name:"Старый",gains:[6,4,2,0,0,0,0,0,0,0])
        defaults.set(try JSONEncoder().encode([legacy]),forKey:"eq.userPresets.v1")
        let migrated = EQUserPresetStore(defaults:defaults)
        precondition(migrated.presets[0].id == legacy.id && migrated.presets[0].gains.count == 10)
        precondition(migrated.presets[0].gains[0] == 6 && migrated.presets[0].gains[3] == 0)
        let secondLoad = EQUserPresetStore(defaults:defaults)
        precondition(secondLoad.presets == migrated.presets)
        precondition(defaults.data(forKey:"eq.userPresets.compact10.backup") != nil)
        precondition(EQGainLimits.frequencies == [30,60,120,250,500,1000,2000,4000,8000,15000])
        precondition(EQGainLimits.bandwidth(at:1) == 1)
        // Metadata distinguishes a new 10-value curve from the historical 10-value layout.
        let canonical = try secondLoad.save(name:"250 Гц", gains:[0,0,0,18,0,0,0,0,0,0])
        precondition(canonical.frequencies == EQGainLimits.frequencies)
        precondition(EQUserPresetStore(defaults:defaults).presets.last == canonical)
        let dense = SavedEQPreset(id:UUID(),name:"Плотная сетка",gains:EQGainLimits.denseFrequencies.map { $0 == 120 ? Float(6) : 0 })
        defaults.set(try JSONEncoder().encode([dense]),forKey:"eq.userPresets.v1")
        let denseStore = EQUserPresetStore(defaults:defaults)
        precondition(denseStore.presets[0].id == dense.id && denseStore.presets[0].gains[2] == 6)
        precondition(denseStore.presets[0].gains.count == 10)
        precondition(EQUserPresetStore(defaults:defaults).presets == denseStore.presets)
        let unknown = SavedEQPreset(id:UUID(),name:"Unknown",gains:gains,frequencies:[1,2,3])
        let unknownData = try JSONEncoder().encode([unknown])
        defaults.set(unknownData,forKey:"eq.userPresets.v1")
        rejects { _ = try EQUserPresetStore(defaults:defaults).save(name:"not overwrite unknown",gains:gains) }
        precondition(defaults.data(forKey:"eq.userPresets.v1") == unknownData)
        checkPersisted(defaults:defaults)
        for width in [216.0, 256, 303, 350, 568] {
            let xs = EQGainLimits.frequencies.indices.map { EQGainLimits.graphX(at:$0,width:width) }
            precondition(xs.first == 14 && abs(xs.last! - (width - 14)) < 0.00001)
            precondition(zip(xs,xs.dropFirst()).allSatisfy { $0 < $1 })
        }
        for index in EQGainLimits.frequencies.indices {
            for gain in stride(from:Float(-12),through:EQGainLimits.range(at:index).upperBound,by:0.5) {
                let y = EQGainLimits.graphY(gain:gain,height:240)
                precondition(y >= 14 && y <= 226)
                precondition(EQGainLimits.graphGain(y:y,height:240,at:index) == gain)
            }
            precondition(EQGainLimits.graphGain(y:-100,height:240,at:index) == EQGainLimits.range(at:index).upperBound)
            precondition(EQGainLimits.graphGain(y:999,height:240,at:index) == -12)
        }
        let broken=Data("broken archive".utf8)
        defaults.set(broken,forKey:"eq.userPresets.v1")
        let corrupt=EQUserPresetStore(defaults:defaults)
        rejects { _ = try corrupt.save(name:"not overwrite",gains:gains) }
        precondition(defaults.data(forKey:"eq.userPresets.v1")==broken)
        print("Named EQ preset save/relaunch/delete/invalid-input/archive checks passed")
    }
}
'''
    # Run the actual app migration body, with only UserDefaults injected for the isolated suite.
    body=(root/'Sonivo/playercore.swift').read_text().split('nonisolated static func persistedEQ() -> (gains: [Float], enabled: Bool) {',1)[1].split('\n    }',1)[0]
    body=body.replace('let defaults = UserDefaults.standard','let eqGainsKey = "eq.gains", eqEnabledKey = "eq.enabled"').replace('return (normalized(gains), enabled)','return (EQGainLimits.normalized(gains), enabled)')
    main=main.replace('__PERSISTED_EQ_BODY__',body)
    with tempfile.TemporaryDirectory() as d:
        p=Path(d);(p/'Checks.swift').write_text(main)
        built=subprocess.run(['swiftc','-swift-version','6',str(root/'Sonivo/EQGainLimits.swift'),str(root/'Sonivo/EQUserPresetStore.swift'),str(p/'Checks.swift'),'-o',str(p/'checks')],capture_output=True,text=True)
        assert built.returncode==0,built.stderr
        result=subprocess.run([str(p/'checks')],capture_output=True,text=True)
        assert result.returncode==0,result.stdout+result.stderr
        print(result.stdout.strip())
