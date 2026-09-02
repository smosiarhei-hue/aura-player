import Foundation

// MARK: - Transition Plan Schema (Structured JSON from Gemini & Local DSP)

nonisolated struct TransitionAction: Codable, Sendable {
    let time: Double
    let target: String       // "source" | "target"
    let parameter: String    // "volume" | "lowEQ" | "midEQ" | "highEQ" | "filter" | "pan" | "pitch" | "reverb"
    let value: Double
    let duration: Double
}

/// Per-plan DSP character, chosen from the measured audio of the pair.
nonisolated struct TransitionEffects: Codable, Sendable {
    /// Factory reverb character for the outgoing lane's tail, e.g. "plate".
    var reverbPreset: String = "plate"

    static let reverbPresets = [
        "smallRoom", "mediumRoom", "largeRoom", "mediumHall", "largeHall",
        "plate", "mediumChamber", "largeChamber", "cathedral", "largeRoom2",
        "mediumHall2", "mediumHall3", "largeHall2"
    ]

    var resolvedReverbPreset: String {
        Self.reverbPresets.contains(reverbPreset) ? reverbPreset : "plate"
    }
}

nonisolated struct TransitionDecisionInfo: Codable, Sendable {
    let transitionType: String
    let confidence: Double
    let reason: String
}

nonisolated struct TransitionSourceTrackInfo: Codable, Sendable {
    let transitionStart: Double
    let transitionEnd: Double
    var duration: Double { max(0.5, transitionEnd - transitionStart) }
}

nonisolated struct TransitionTargetTrackInfo: Codable, Sendable {
    let startPosition: Double
}

nonisolated struct TransitionTempoInfo: Codable, Sendable {
    let targetBPM: Double
    let sourcePlaybackRate: Double
    let targetPlaybackRate: Double
}

nonisolated struct TransitionFallbackInfo: Codable, Sendable {
    let type: String
}

nonisolated struct TransitionPlan: Codable, Sendable {
    let decision: TransitionDecisionInfo
    let sourceTrack: TransitionSourceTrackInfo
    let targetTrack: TransitionTargetTrackInfo
    let tempo: TransitionTempoInfo
    let actions: [TransitionAction]
    let fallback: TransitionFallbackInfo
    /// Optional DSP character (reverb choice); local plans always set it.
    var effects: TransitionEffects = TransitionEffects()

    var strategy: TransitionStrategy {
        TransitionStrategy(rawValue: decision.transitionType) ?? .BASS_SWAP
    }

    var leadTime: Double {
        sourceTrack.duration
    }

    var cueTime: Double {
        sourceTrack.transitionStart
    }
}

// MARK: - Connectivity Diagnostics

/// Result of a direct, on-demand connectivity check against the Gemini API.
/// Used by the Settings screen so the user can toggle a VPN/proxy on or off
/// and immediately see whether Gemini is actually reachable from this
/// device right now - independent of AutoMix's own plan cache and circuit
/// breaker, which could otherwise mask a fresh, successful retry for hours.
nonisolated enum GeminiConnectivityStatus: Sendable {
    case ok(model: String)
    case regionBlocked(message: String)
    case httpError(code: Int, message: String)
    case networkError(String)
    case noApiKey
}

// MARK: - Gemini AI AutoMix Planner

actor GeminiAutoMixPlanner {
    static let shared = GeminiAutoMixPlanner()

    /// Bump when the prompt/schema changes so stale cached plans are dropped.
    private static let planCacheVersion = 4

    private var cache: [String: TransitionPlan] = [:]
    private var inFlightTasks: [String: Task<TransitionPlan, Never>] = [:]

    /// Circuit breaker: after a regional/billing API refusal (HTTP 400 with
    /// "location is not supported") every further call would fail the same
    /// way for hours. Stop calling the API until the cool-down passes so the
    /// planner answers instantly from the local DSP instead of burning ~10 s
    /// per pair on doomed network round-trips.
    private var geminiDisabledUntil: Date?
    /// True when the failure was a regional block (worth skipping entirely).
    private var geminiRegionBlocked = false
    private static let regionBlockCooldown: TimeInterval = 6 * 3600

    /// Which engine produced the most recently returned transition plan -
    /// exposed so the on-screen AutoMix mark can show whether Gemini
    /// actually answered or the local DSP took over (region block, offline,
    /// or any other API failure). Only ever written from this actor and
    /// read as a quick, best-effort status peek from the main-thread UI,
    /// which is why it deliberately opts out of actor isolation instead of
    /// forcing every render to await the actor just for a label.
    nonisolated(unsafe) static var lastPlanUsedGemini = false

    private init() {}

    // MARK: - Public Planner API

    func planTransition(
        sourceTrack: Track,
        sourceAnalysis: TrackAnalysis,
        targetTrack: Track,
        targetAnalysis: TrackAnalysis,
        currentPosition: Double
    ) async -> TransitionPlan {
        let cacheKey = "v\(Self.planCacheVersion)_\(sourceTrack.id.uuidString)_\(targetTrack.id.uuidString)"

        if let cached = cache[cacheKey] {
            return cached
        }

        if let inFlight = inFlightTasks[cacheKey] {
            return await inFlight.value
        }

        let task = Task<TransitionPlan, Never> {
            // 0. Circuit breaker: skip the doomed network call entirely while
            //    the API is known to refuse this region.
            let geminiAvailable: Bool
            if let blocked = geminiDisabledUntil {
                if Date() < blocked {
                    geminiAvailable = false
                } else {
                    geminiDisabledUntil = nil
                    geminiRegionBlocked = false
                    geminiAvailable = true
                }
            } else {
                geminiAvailable = true
            }

            // 1. Try Gemini background AI planning (never on the realtime path).
            if geminiAvailable,
               var aiPlan = await requestGeminiPlan(
                sourceTrack: sourceTrack,
                sourceAnalysis: sourceAnalysis,
                targetTrack: targetTrack,
                targetAnalysis: targetAnalysis,
                currentPosition: currentPosition
               ) {
                aiPlan = TransitionPlanner.sanitize(
                    aiPlan,
                    sourceAnalysis: sourceAnalysis,
                    targetAnalysis: targetAnalysis
                )
                SonivoDiagnostics.log(
                    "[AutoMix AI] Gemini plan: \(aiPlan.decision.transitionType) (conf: \(String(format: "%.2f", aiPlan.decision.confidence))), reason: \(aiPlan.decision.reason)",
                    tag: "AUTOMIX"
                )
                Self.lastPlanUsedGemini = true
                return aiPlan
            }

            // 2. Offline / API error fallback (local DSP decision engine).
            let fallbackPlan = TransitionPlanner.planLocalFallback(
                sourceTrackID: sourceTrack.id,
                sourceAnalysis: sourceAnalysis,
                targetTrackID: targetTrack.id,
                targetAnalysis: targetAnalysis
            )
            SonivoDiagnostics.log(
                "[AutoMix Local] DSP plan: \(fallbackPlan.decision.transitionType), cue: \(String(format: "%.1f", fallbackPlan.cueTime))s, dur: \(String(format: "%.1f", fallbackPlan.leadTime))s",
                tag: "AUTOMIX"
            )
            Self.lastPlanUsedGemini = false
            return fallbackPlan
        }

        inFlightTasks[cacheKey] = task
        let plan = await task.value
        inFlightTasks[cacheKey] = nil
        cache[cacheKey] = plan
        return plan
    }

    // MARK: - Gemini API Request

    private func requestGeminiPlan(
        sourceTrack: Track,
        sourceAnalysis: TrackAnalysis,
        targetTrack: Track,
        targetAnalysis: TrackAnalysis,
        currentPosition: Double
    ) async -> TransitionPlan? {
        let apiKey = SonivoAIConfig.geminiApiKey
        guard !apiKey.isEmpty else { return nil }

        for model in SonivoAIConfig.candidateModels {
            guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)") else {
                continue
            }
            if let plan = await executeGeminiRequest(
                url: url,
                sourceTrack: sourceTrack,
                sourceAnalysis: sourceAnalysis,
                targetTrack: targetTrack,
                targetAnalysis: targetAnalysis,
                currentPosition: currentPosition
            ) {
                return plan
            }
            // A regional refusal is not model-specific: do not retry the
            // remaining candidate models on a breaker-worthy failure.
            if geminiRegionBlocked { return nil }
        }
        return nil
    }

    /// Compact section summary so the prompt stays small but still describes
    /// the musical structure the planner needs for phrase-aware decisions.
    nonisolated private static func describeSections(_ analysis: TrackAnalysis) -> String {
        guard !analysis.sections.isEmpty else { return "none detected" }
        return analysis.sections.prefix(20).map { section in
            String(format: "%.0f-%.0fs %@ (energy %.2f)", section.start, section.end, section.type.rawValue, section.energy)
        }.joined(separator: "; ")
    }

    nonisolated private static func describeRanges(_ ranges: [TimeRange], limit: Int = 12) -> String {
        guard !ranges.isEmpty else { return "none" }
        return ranges.prefix(limit).map { String(format: "%.1f-%.1fs", $0.start, $0.end) }.joined(separator: ", ")
    }

    nonisolated private static func describeTimes(_ times: [Double], limit: Int = 8) -> String {
        guard !times.isEmpty else { return "none" }
        return times.prefix(limit).map { String(format: "%.1fs", $0) }.joined(separator: ", ")
    }

    private func executeGeminiRequest(
        url: URL,
        sourceTrack: Track,
        sourceAnalysis: TrackAnalysis,
        targetTrack: Track,
        targetAnalysis: TrackAnalysis,
        currentPosition: Double
    ) async -> TransitionPlan? {

        let systemInstruction = """
You are the AI transition director for a professional music player.
Your job is NOT to mix audio directly.
Your job is to analyze two musical tracks and generate the safest and most musical DJ-style transition plan that can be executed by a local audio engine.
The goal is seamless continuous playback similar in user experience to a modern intelligent DJ mix.
Never assume that every pair of tracks should use the same transition.
Prefer musicality over complexity.
Do not force beat matching when the BPM difference, structure, genre, energy or harmony is incompatible.
Avoid overlapping vocals whenever possible.
Avoid simultaneous full low-end from both tracks.
Transitions should align with musical phrases, bars, beats, drops, breakdowns, intros and outros.
Prefer 8, 16 or 32 bar musical structures.
Use time stretching only when the resulting speed change is musically reasonable (stay within 0.94-1.06 playback rate).
If a complex transition would sound worse than a simple transition, choose the simple transition.
If the tracks are incompatible, choose a safe fallback such as silence trimming, short crossfade, echo-out or hard cut at a musical boundary.
Use only the analysis data provided. All numbers you output (transitionStart, transitionEnd, rates) must be physically valid for these tracks.
Return ONLY valid JSON matching the supplied schema.
Never return markdown.
Never return explanations outside the JSON.
Use confidence values between 0 and 1.
Your transition plan must always contain a fallback strategy.
"""

        // Privacy (TZ Section 33): only musical facts, no user identifiers.
        let prompt = """
CURRENT TRACK:
- Title: \(sourceTrack.title)
- Artist: \(sourceTrack.artist)
- Duration: \(String(format: "%.1f", sourceAnalysis.duration))s
- BPM: \(sourceAnalysis.bpm.map { String(format: "%.1f", $0) } ?? "unknown") (confidence: \(String(format: "%.2f", sourceAnalysis.bpmConfidence)))
- Key: \(sourceAnalysis.musicalKey ?? "unknown") (confidence: \(String(format: "%.2f", sourceAnalysis.keyConfidence)))
- Energy: \(String(format: "%.2f", sourceAnalysis.energy))
- Intro ends at: \(String(format: "%.1f", sourceAnalysis.introEnd))s
- Outro starts at: \(String(format: "%.1f", sourceAnalysis.outroStart))s
- Sections: \(Self.describeSections(sourceAnalysis))
- Vocal regions: \(Self.describeRanges(sourceAnalysis.vocalRegions))
- Instrumental regions: \(Self.describeRanges(sourceAnalysis.instrumentalRegions))
- Silence regions: \(Self.describeRanges(sourceAnalysis.silenceRegions))
- Drops: \(Self.describeTimes(sourceAnalysis.drops))
- Build-ups: \(Self.describeRanges(sourceAnalysis.buildUps))
- Last beat: \(sourceAnalysis.lastBeat.map { String(format: "%.1fs", $0) } ?? "unknown")
- Last downbeat: \(sourceAnalysis.downbeats.last.map { String(format: "%.1fs", $0) } ?? "unknown")

NEXT TRACK:
- Title: \(targetTrack.title)
- Artist: \(targetTrack.artist)
- Duration: \(String(format: "%.1f", targetAnalysis.duration))s
- BPM: \(targetAnalysis.bpm.map { String(format: "%.1f", $0) } ?? "unknown") (confidence: \(String(format: "%.2f", targetAnalysis.bpmConfidence)))
- Key: \(targetAnalysis.musicalKey ?? "unknown") (confidence: \(String(format: "%.2f", targetAnalysis.keyConfidence)))
- Energy: \(String(format: "%.2f", targetAnalysis.energy))
- Intro ends at: \(String(format: "%.1f", targetAnalysis.introEnd))s
- Outro starts at: \(String(format: "%.1f", targetAnalysis.outroStart))s
- Sections: \(Self.describeSections(targetAnalysis))
- Vocal regions: \(Self.describeRanges(targetAnalysis.vocalRegions))
- Instrumental regions: \(Self.describeRanges(targetAnalysis.instrumentalRegions))
- Drops: \(Self.describeTimes(targetAnalysis.drops))
- Build-ups: \(Self.describeRanges(targetAnalysis.buildUps))
- First beat: \(targetAnalysis.firstBeat.map { String(format: "%.1fs", $0) } ?? "unknown")
- First downbeat: \(targetAnalysis.downbeats.first.map { String(format: "%.1fs", $0) } ?? "unknown")

PLAYER STATE:
- Current position: \(String(format: "%.1f", currentPosition))s
- Remaining duration: \(String(format: "%.1f", max(0, sourceAnalysis.duration - currentPosition)))s

The effects.reverbPreset describes the reverb character for the outgoing track's tail. Pick it from the measured audio: short bright tails (plate, smallRoom, mediumRoom) for upbeat club material so the kick stays readable; long lush tails (largeHall, cathedral, largeRoom) for slow or quiet material; chambers and halls for vocal-heavy pairs. You may also add "reverb" action keyframes (0...1 wetness over time) on the source lane.
Every plan should feel individual: vary blend lengths, curve shapes and effect depths based on what the analysis actually shows about THIS pair of tracks.

Respond ONLY with a JSON object matching this schema:
{
  "decision": {
    "transitionType": "BASS_SWAP | BEAT_MATCH | BEAT_MATCH_EQ | FILTER_TRANSITION | BUILDUP_TO_DROP | DROP_SWITCH | ECHO_OUT | LOOP_TRANSITION | SILENCE_TRIM | SIMPLE_CROSSFADE | VOCAL_CUT | INSTRUMENTAL_OVERLAY | ENERGY_BLEND | HARD_CUT",
    "confidence": 0.92,
    "reason": "Harmonic bass swap on bar boundary with tempo sync"
  },
  "sourceTrack": {
    "transitionStart": \(String(format: "%.1f", max(0, sourceAnalysis.duration - 16.0))),
    "transitionEnd": \(String(format: "%.1f", sourceAnalysis.duration))
  },
  "targetTrack": {
    "startPosition": 0.0
  },
  "tempo": {
    "targetBPM": \(targetAnalysis.bpm.map { String(format: "%.1f", $0) } ?? "120.0"),
    "sourcePlaybackRate": 1.0,
    "targetPlaybackRate": 1.0
  },
  "actions": [
    { "time": 0.0, "target": "source", "parameter": "volume", "value": 1.0, "duration": 0.0 },
    { "time": 4.0, "target": "source", "parameter": "lowEQ", "value": 0.1, "duration": 4.0 },
    { "time": 0.0, "target": "target", "parameter": "volume", "value": 0.0, "duration": 0.0 },
    { "time": 4.0, "target": "target", "parameter": "volume", "value": 0.8, "duration": 8.0 }
  ],
  "fallback": {
    "type": "SIMPLE_CROSSFADE"
  },
  "effects": {
    "reverbPreset": "plate"
  }
}
"""

        let body: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [["text": prompt]]
                ]
            ],
            "systemInstruction": [
                "parts": [["text": systemInstruction]]
            ],
            "generationConfig": [
                "temperature": 0.2,
                "responseMimeType": "application/json"
            ]
        ]

        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        request.timeoutInterval = 6.0

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }

            if http.statusCode != 200 {
                let errStr = String(data: data, encoding: .utf8) ?? ""
                SonivoDiagnostics.log("[AutoMix AI] HTTP \(http.statusCode): \(errStr.prefix(90))", tag: "AUTOMIX")
                // Regional / policy refusal: every call from this device will
                // fail identically. Open the circuit breaker so the local DSP
                // answers instantly instead of stalling every pair for seconds.
                if http.statusCode == 400 || http.statusCode == 403 {
                    let lowered = errStr.lowercased()
                    if lowered.contains("location is not supported")
                        || lowered.contains("user location")
                        || lowered.contains("not available in your country")
                        || lowered.contains("billing")
                        || lowered.contains("api key not valid") {
                        geminiRegionBlocked = true
                        geminiDisabledUntil = Date().addingTimeInterval(Self.regionBlockCooldown)
                        SonivoDiagnostics.log(
                            "[AutoMix AI] Region/key refusal detected - local DSP planning takes over for \(Int(Self.regionBlockCooldown / 3600))h",
                            tag: "AUTOMIX"
                        )
                        return nil
                    }
                }
                return nil
            }

            struct GeminiResponse: Codable {
                struct Candidate: Codable {
                    struct Content: Codable {
                        struct Part: Codable {
                            let text: String?
                        }
                        let parts: [Part]?
                    }
                    let content: Content?
                }
                let candidates: [Candidate]?
            }

            guard let resp = try? JSONDecoder().decode(GeminiResponse.self, from: data),
                  let text = resp.candidates?.first?.content?.parts?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return nil
            }

            let cleanedJson = text
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard let jsonData = cleanedJson.data(using: .utf8),
                  let rawPlan = try? JSONDecoder().decode(TransitionPlan.self, from: jsonData) else {
                SonivoDiagnostics.log("[AutoMix AI] JSON decode failed: \(cleanedJson.prefix(80))", tag: "AUTOMIX")
                return nil
            }

            // Trust, but verify: reject plans that contradict measured audio.
            let cueValid = rawPlan.sourceTrack.transitionStart.isFinite
                && rawPlan.sourceTrack.transitionStart >= 0
                && rawPlan.sourceTrack.transitionStart <= sourceAnalysis.duration + 1
            guard cueValid else {
                SonivoDiagnostics.log("[AutoMix AI] Plan rejected: invalid cue \(rawPlan.sourceTrack.transitionStart)", tag: "AUTOMIX")
                return nil
            }

            let confidence = rawPlan.decision.confidence.isFinite
                ? min(1, max(0, rawPlan.decision.confidence))
                : 0.5
            let plan = TransitionPlan(
                decision: TransitionDecisionInfo(
                    transitionType: rawPlan.decision.transitionType,
                    confidence: confidence,
                    reason: rawPlan.decision.reason
                ),
                sourceTrack: rawPlan.sourceTrack,
                targetTrack: rawPlan.targetTrack,
                tempo: rawPlan.tempo,
                actions: rawPlan.actions,
                fallback: rawPlan.fallback
            )
            return plan
        } catch {
            SonivoDiagnostics.log("[AutoMix AI] Network error: \(error.localizedDescription)", tag: "AUTOMIX")
            return nil
        }
    }

    // MARK: - On-Demand Connectivity Test (Settings Diagnostic)

    /// Fires one small, real request straight at the Gemini API right now,
    /// completely bypassing the plan cache and the circuit breaker, so a
    /// user toggling a VPN/proxy on or off gets an immediate, trustworthy
    /// answer instead of a stale cached result from hours ago.
    func testConnectivity() async -> GeminiConnectivityStatus {
        let apiKey = SonivoAIConfig.geminiApiKey
        guard !apiKey.isEmpty else { return .noApiKey }

        guard let model = SonivoAIConfig.candidateModels.first,
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)") else {
            return .networkError("Некорректный адрес Gemini API")
        }

        let body: [String: Any] = [
            "contents": [
                ["role": "user", "parts": [["text": "ping"]]]
            ],
            "generationConfig": ["maxOutputTokens": 8]
        ]

        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            return .networkError("Не удалось сформировать запрос")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        request.timeoutInterval = 8.0

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                SonivoDiagnostics.log("[AutoMix AI] Diagnostic ping: no HTTP response", tag: "AUTOMIX")
                return .networkError("Сервер не ответил")
            }

            if http.statusCode == 200 {
                SonivoDiagnostics.log("[AutoMix AI] Diagnostic ping succeeded (\(model))", tag: "AUTOMIX")
                // A live 200 here proves the key/region are healthy RIGHT NOW.
                // Without this reset, a single earlier region/key refusal (for
                // example from a since-replaced API key) leaves the circuit
                // breaker (`geminiDisabledUntil`) armed for up to 6h, so real
                // AutoMix planning keeps silently falling back to the local DSP
                // engine even though this diagnostic - which deliberately
                // bypasses that breaker - just reported success. Clear the
                // breaker and drop any transition plans cached while it was
                // open so the very next scheduled transition retries Gemini
                // for real instead of reusing a stale local-DSP plan.
                geminiDisabledUntil = nil
                geminiRegionBlocked = false
                cache.removeAll()
                return .ok(model: model)
            }

            let errStr = String(data: data, encoding: .utf8) ?? ""
            let lowered = errStr.lowercased()
            if (http.statusCode == 400 || http.statusCode == 403),
               lowered.contains("location is not supported")
                || lowered.contains("user location")
                || lowered.contains("not available in your country")
                || lowered.contains("billing")
                || lowered.contains("api key not valid") {
                SonivoDiagnostics.log("[AutoMix AI] Diagnostic ping: region/key refusal", tag: "AUTOMIX")
                return .regionBlocked(message: errStr.isEmpty ? "Регион не поддерживается" : String(errStr.prefix(160)))
            }

            SonivoDiagnostics.log("[AutoMix AI] Diagnostic ping: HTTP \(http.statusCode)", tag: "AUTOMIX")
            return .httpError(code: http.statusCode, message: String(errStr.prefix(160)))
        } catch {
            SonivoDiagnostics.log("[AutoMix AI] Diagnostic ping network error: \(error.localizedDescription)", tag: "AUTOMIX")
            return .networkError(error.localizedDescription)
        }
    }
}
