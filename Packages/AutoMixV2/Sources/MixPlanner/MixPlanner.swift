// Path: Packages/AutoMixV2/Sources/MixPlanner/MixPlanner.swift

import Foundation
import MixModels

public enum MixPlanner {
    public static func plan(
        from a: TrackProfile,
        to b: TrackProfile,
        aMeta: TrackMeta,
        bMeta: TrackMeta,
        settings: MixSettings
    ) -> TransitionPlan {
        if settings.mode == .off {
            return none(a: a, b: b, reason: "Переходы выключены в настройках")
        }
        if settings.skipTransitionsWithinAlbum,
           let albumA = aMeta.albumID, albumA == bMeta.albumID,
           !a.endsInSilence {
            return none(a: a, b: b, reason: "Треки одного альбома: сохранён gapless-переход")
        }
        if a.durationSec < 60 || b.durationSec < 60 {
            return none(a: a, b: b, reason: "Один из треков короче 60 секунд")
        }

        let seconds = settings.mode == .crossfade
            ? min(12, max(1, settings.crossfadeSeconds)) : 4
        let gainOffset: Float
        if settings.loudnessNormalization {
            gainOffset = min(12, max(-12, settings.targetLUFS - b.integratedLUFS))
        } else {
            gainOffset = 0
        }
        let start = min(max(0, a.mixOutSec), max(0, a.durationSec - seconds))
        let incoming = min(max(0, b.mixInSec), max(0, b.durationSec - 0.1))
        let fx = [
            FxEvent(target: .a, kind: .volume, startBar: 0, endBar: seconds,
                    fromValue: 0, toValue: -60, curve: .sCurve),
            FxEvent(target: .b, kind: .volume, startBar: 0, endBar: seconds,
                    fromValue: -60, toValue: 0, curve: .sCurve)
        ]
        let reason = settings.mode == .crossfade
            ? "Умный кроссфейд по cue-точкам пользователя"
            : "Этап 2: безопасный кроссфейд по измеренным cue-точкам"
        return TransitionPlan(type: .crossfade, aOutStartSec: start, bInStartSec: incoming,
                              bars: seconds, tempoTargetBPM: 0, rateA: 1, rateB: 1,
                              gainOffsetBdB: gainOffset, loopBarsA: 0, fx: fx, reason: reason)
    }

    private static func none(a: TrackProfile, b: TrackProfile, reason: String) -> TransitionPlan {
        TransitionPlan(type: .none, aOutStartSec: a.durationSec, bInStartSec: 0,
                       bars: 0, tempoTargetBPM: 0, rateA: 1, rateB: 1,
                       gainOffsetBdB: 0, loopBarsA: 0, fx: [], reason: reason)
    }
}
