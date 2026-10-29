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
    @MainActor static func main() throws {
        let suite="sonivo-eq-bassshake10-tests-\(UUID().uuidString)"
        let defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        func rejects(_ action: () throws -> Void) {
            do { try action(); fatalError("Invalid input accepted") } catch { }
        }
        precondition(EQGainLimits.frequencies == [60,120,250,500,1000,2000,4000,8000,12000,16000])
        precondition(EQGainLimits.bandwidth(at:0) == 0.90)
        precondition(EQGainLimits.bandwidth(at:1) == 0.65)
        precondition(EQGainLimits.bandwidth(at:2) == 0.80)
        precondition(EQGainLimits.bandwidth(at:5) == 1.0)
        precondition(EQGainLimits.bandwidth(at:9) == 0.70)
        for band in EQGainLimits.frequencies.indices {
            precondition(EQGainLimits.range(at:band) == (-15...15))
        }
        let store=EQUserPresetStore(defaults:defaults)
        let gains: [Float] = [12,6,-2,0,2,4,3,1,0,-15]
        let saved=try store.save(name:"  Мой бас  ",gains:gains)
        precondition(saved.name=="Мой бас" && saved.gains==gains)
        let reloaded=EQUserPresetStore(defaults:defaults)
        precondition(reloaded.presets==[saved],"Preset did not survive relaunch")
        let fractional: [Float] = [1.234567,-4.001,0.00013,-0.731,3.147,-9.201,2.5,0.25,-1.5,4.75]
        let fractionalPreset=try reloaded.save(name:"Fractional",gains:fractional)
        precondition(EQUserPresetStore(defaults:defaults).presets.last==fractionalPreset,"Canonical curve changed on load")
        try reloaded.delete(id:fractionalPreset.id)

        rejects { _ = try reloaded.save(name:"мой бас",gains:gains) }
        rejects { _ = try reloaded.save(name:" ",gains:gains) }
        rejects { _ = try reloaded.save(name:String(repeating:"x",count:65),gains:gains) }
        rejects { _ = try reloaded.save(name:"bad count",gains:[0]) }
        var bad=gains;bad[0] = .nan
        rejects { _ = try reloaded.save(name:"nan",gains:bad) }
        bad[0] = .infinity
        rejects { _ = try reloaded.save(name:"inf",gains:bad) }
        for value in [Float(-15.5),Float(15.5)] {
            bad=gains;bad[9]=value
            rejects { _ = try reloaded.save(name:"range",gains:bad) }
        }
        precondition(reloaded.presets==[saved])
        let strong = [Float](repeating:15,count:10)
        let strongPreset=try reloaded.save(name:"Сильный",gains:strong)
        precondition(EQUserPresetStore(defaults:defaults).presets.contains(strongPreset))
        try reloaded.delete(id:strongPreset.id);try reloaded.delete(id:saved.id)
        precondition(EQUserPresetStore(defaults:defaults).presets.isEmpty)
        let old: [Float] = [6,4,2,0,0,0,0,0,0,0]
        for source in [EQGainLimits.legacyFrequencies,EQGainLimits.previousCompactFrequencies,EQGainLimits.compact10Frequencies,EQGainLimits.denseFrequencies,EQGainLimits.previousBassTightFrequencies,EQGainLimits.previousReferenceFrequencies,EQGainLimits.previousStandard10Frequencies] {
            let values: [Float]
            if source.count==29 {
                values=source.map { $0 == 120 ? Float(6) : 0 }
            } else if source.count==6 {
                values=[6,4,0,0,2,-3]
            } else {
                values=old
            }
            let legacy=SavedEQPreset(id:UUID(),name:"Старый",gains:values,frequencies:source==EQGainLimits.legacyFrequencies || source.count==29 ? nil : source)
            let data=try JSONEncoder().encode([legacy]);defaults.set(data,forKey:"eq.userPresets.v1")
            defaults.removeObject(forKey:"eq.userPresets.reference6.backup")
            defaults.removeObject(forKey:"eq.userPresets.standard10.backup")
            defaults.removeObject(forKey:"eq.userPresets.bassShake10.backup")
            let migrated=EQUserPresetStore(defaults:defaults)
            precondition(migrated.presets.count==1)
            precondition(migrated.presets[0].id==legacy.id && migrated.presets[0].name==legacy.name)
            precondition(migrated.presets[0].gains==EQGainLimits.normalized(EQGainLimits.resample(values,from:source,to:EQGainLimits.frequencies)))
            precondition(migrated.presets[0].frequencies==EQGainLimits.frequencies)
            precondition(EQUserPresetStore(defaults:defaults).presets==migrated.presets)
            precondition(defaults.data(forKey:"eq.userPresets.bassShake10.backup")==data)
        }
        precondition(defaults.data(forKey:"eq.userPresets.compact10.backup") != nil)
        let unknown=SavedEQPreset(id:UUID(),name:"Unknown",gains:gains,frequencies:[1,2,3])
        let unknownData=try JSONEncoder().encode([unknown]);defaults.set(unknownData,forKey:"eq.userPresets.v1")
        rejects { _ = try EQUserPresetStore(defaults:defaults).save(name:"not overwrite unknown",gains:gains) }
        precondition(defaults.data(forKey:"eq.userPresets.v1")==unknownData)
        // ISO standard10 → bassShake10 once.
        defaults.set(true,forKey:"eq.layout.compact10")
        defaults.set(true,forKey:"eq.layout.standard10")
        defaults.removeObject(forKey:EQGainLimits.layoutMarkerKey)
        let iso=EQGainLimits.previousStandard10Frequencies.map { $0 <= 125 ? Float(6) : 0 }
        let isoData=try JSONEncoder().encode(iso)
        defaults.set(isoData,forKey:"eq.gains")
        let runtime=persisted(defaults:defaults)
        precondition(runtime.gains==EQGainLimits.normalized(EQGainLimits.resample(iso,from:EQGainLimits.previousStandard10Frequencies,to:EQGainLimits.frequencies)))
        precondition(defaults.data(forKey:"eq.gains.bassShake10.backup")==isoData)
        precondition(persisted(defaults:defaults).gains==runtime.gains)
        // Six-band bassTight → bassShake10 once.
        defaults.set(true,forKey:"eq.layout.compact10")
        defaults.set(true,forKey:"eq.layout.reference6")
        defaults.set(true,forKey:"eq.layout.bassTight6")
        defaults.removeObject(forKey:"eq.layout.standard10")
        defaults.removeObject(forKey:EQGainLimits.layoutMarkerKey)
        let six:[Float]=[8,5,1,0,2,-4]
        defaults.set(try JSONEncoder().encode(six),forKey:"eq.gains")
        let fromSix=persisted(defaults:defaults)
        precondition(fromSix.gains==EQGainLimits.normalized(EQGainLimits.resample(six,from:EQGainLimits.previousBassTightFrequencies,to:EQGainLimits.frequencies)))
        precondition(defaults.data(forKey:"eq.gains.bassTight6.backup") != nil)
        precondition(persisted(defaults:defaults).gains==fromSix.gains,"Ten-value curve was migrated twice")
        defaults.set(try JSONEncoder().encode(gains),forKey:"eq.gains")
        precondition(persisted(defaults:defaults).gains==gains,"Ten-value curve was migrated twice")
        for width in [216.0,256,303,350,568] {
            let xs=EQGainLimits.frequencies.indices.map { EQGainLimits.graphX(at:$0,width:width) }
            precondition(xs.first==14 && abs(xs.last!-(width-14))<0.00001)
            precondition(zip(xs,xs.dropFirst()).allSatisfy { $0 < $1 })
            for band in EQGainLimits.frequencies.indices {
                for gain in stride(from:Float(-15),through:15,by:0.5) {
                    let y=EQGainLimits.graphY(gain:gain,height:240)
                    precondition(y>=14 && y<=226)
                    precondition(EQGainLimits.graphGain(y:y,height:240,at:band)==gain)
                }
                let x=EQGainLimits.graphX(at:band,width:width),y=EQGainLimits.graphY(gain:gains[band],height:240)
                precondition(EQGainLimits.graphHitBand(x:x,y:y,width:width,height:240,gains:gains)==band)
                var reset=gains;reset[band]=0
                precondition(zip(gains,reset).enumerated().allSatisfy { index,pair in index==band ? pair.1==0 : pair.0==pair.1 })
            }
            precondition(EQGainLimits.graphHitBand(x:-100,y:0,width:width,height:240,gains:gains)==nil)
            precondition(EQGainLimits.graphHitBand(x:.nan,y:0,width:width,height:240,gains:gains)==nil)
        }
        precondition(EQGainLimits.graphY(gain:0,height:240)==120)
        var feedback=EQAdjustmentFeedback()
        let light=feedback.intensity(from:0,to:0.5,at:1)!
        precondition(feedback.intensity(from:0.5,to:1,at:1.01)==nil,"Haptic throttle bypassed")
        let strongPulse=feedback.intensity(from:14,to:15,at:1.1)!
        precondition(strongPulse>light && strongPulse<=1)
        precondition(feedback.intensity(from:15,to:15,at:2)==nil)
        precondition(feedback.intensity(from:0,to:.nan,at:3)==nil)
        let broken=Data("broken archive".utf8);defaults.set(broken,forKey:"eq.userPresets.v1")
        rejects { _ = try EQUserPresetStore(defaults:defaults).save(name:"not overwrite",gains:gains) }
        precondition(defaults.data(forKey:"eq.userPresets.v1")==broken)
        print("BassShake10 presets, historical migrations, backups, graph and haptic policy checks passed")
    }
}
'''
    body=(root/'Sonivo/playercore.swift').read_text().split('nonisolated static func persistedEQ() -> (gains: [Float], enabled: Bool) {',1)[1].split('\n    }',1)[0]
    body=body.replace('let defaults = UserDefaults.standard','let eqGainsKey = "eq.gains", eqEnabledKey = "eq.enabled"').replace('return (normalized(gains), enabled)','return (EQGainLimits.normalized(gains), enabled)')
    main=main.replace('__PERSISTED_EQ_BODY__',body)
    with tempfile.TemporaryDirectory() as d:
        p=Path(d);(p/'Checks.swift').write_text(main)
        built=subprocess.run(['swiftc','-swift-version','6',str(root/'Sonivo/EQGainLimits.swift'),str(root/'Sonivo/EQUserPresetStore.swift'),str(root/'Sonivo/EQAdjustmentFeedback.swift'),str(p/'Checks.swift'),'-o',str(p/'checks')],capture_output=True,text=True)
        assert built.returncode==0,built.stderr
        result=subprocess.run([str(p/'checks')],capture_output=True,text=True)
        assert result.returncode==0,result.stdout+result.stderr
        print(result.stdout.strip())
