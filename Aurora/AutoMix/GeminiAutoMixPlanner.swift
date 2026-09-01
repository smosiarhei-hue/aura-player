import Foundation

// MARK: - Transition Plan Schema (Structured JSON from Gemini 3.7 Flash & Local DSP)

nonisolated struct TransitionAction: Codable, Sendable {
    let time: Double
    let target: String       // "source" | "target"
    let parameter: String    // "volume" | "lowEQ" | "midEQ" | "highEQ" | "filter" | "pan" | "pitch"
    let value: Double
    let duration: Double
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

// MARK: - Gemini 3.7 Flash AI AutoMix Planner

actor GeminiAutoMixPlanner {
    static let shared = GeminiAutoMixPlanner()

    private var cache: [String: TransitionPlan] = [:]
    private var inFlightTasks: [String: Task<TransitionPlan, Never>] = [:]

    private init() {}

    // MARK: - Public Planner API

    func planTransition(
        sourceTrack: Track,
        sourceAnalysis: TrackAnalysis,
        targetTrack: Track,
        targetAnalysis: TrackAnalysis,
        currentPosition: Double
    ) async -> TransitionPlan {
        let cacheKey = "\(sourceTrack.id.uuidString)_\(targetTrack.id.uuidString)"

        if let cached = cache[cacheKey] {
            return cached
        }

        if let inFlight = inFlightTasks[cacheKey] {
            return await inFlight.value
        }

        let task = Task<TransitionPlan, Never> {
            // 1. Try Gemini 3.7 Flash Background AI Planning
            if let aiPlan = await self.requestGeminiPlan(
                sourceTrack: sourceTrack,
                sourceAnalysis: sourceAnalysis,
                targetTrack: targetTrack,
                targetAnalysis: targetAnalysis,
                currentPosition: currentPosition
            ) {
                SonivoDiagnostics.log("[AutoMix AI] Gemini 3.7 Flash plan generated: \(aiPlan.decision.transitionType) (conf: \(String(format: "%.2f", aiPlan.decision.confidence))), reason: \(aiPlan.decision.reason)", tag: "AUTOMIX")
                return aiPlan
            }

            // 2. Offline / API Error Fallback (Local DSP Decision Engine)
            let fallbackPlan = TransitionPlanner.planLocalFallback(
                sourceTrack: sourceTrack,
                sourceAnalysis: sourceAnalysis,
                targetTrack: targetTrack,
                targetAnalysis: targetAnalysis
            )
            SonivoDiagnostics.log("[AutoMix Local] Local DSP plan generated: \(fallbackPlan.decision.transitionType), cue: \(String(format: "%.1f", fallbackPlan.cueTime))s, dur: \(String(format: "%.1f", fallbackPlan.leadTime))s", tag: "AUTOMIX")
            return fallbackPlan
        }

        inFlightTasks[cacheKey] = task
        let plan = await task.value
        inFlightTasks[cacheKey] = nil
        cache[cacheKey] = plan
        return plan
    }

    // MARK: - Gemini 3.7 Flash API Request

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
        }
        return nil
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
Use time stretching only when the resulting speed change is musically reasonable.
If a complex transition would sound worse than a simple transition, choose the simple transition.
If the tracks are incompatible, choose a safe fallback such as silence trimming, short crossfade, echo-out or hard cut at a musical boundary.
Return ONLY valid JSON matching the supplied schema.
Never return markdown.
Never return explanations outside the JSON.
Never invent unavailable audio-analysis data.
Use confidence values between 0 and 1.
Your transition plan must always contain a fallback strategy.
"""

        let prompt = """
CURRENT TRACK:
- Title: \(sourceTrack.title)
- Artist: \(sourceTrack.artist)
- Duration: \(sourceAnalysis.duration)
- BPM: \(sourceAnalysis.bpm ?? 120.0) (confidence: \(sourceAnalysis.bpmConfidence))
- Key: \(sourceAnalysis.musicalKey ?? "Unknown") (confidence: \(sourceAnalysis.keyConfidence))
- Energy: \(sourceAnalysis.energy)
- Outro Start: \(sourceAnalysis.outroStart)
- Beats Count: \(sourceAnalysis.beats.count)

NEXT TRACK:
- Title: \(targetTrack.title)
- Artist: \(targetTrack.artist)
- Duration: \(targetAnalysis.duration)
- BPM: \(targetAnalysis.bpm ?? 120.0) (confidence: \(targetAnalysis.bpmConfidence))
- Key: \(targetAnalysis.musicalKey ?? "Unknown") (confidence: \(targetAnalysis.keyConfidence))
- Energy: \(targetAnalysis.energy)
- Intro End: \(targetAnalysis.introEnd)

PLAYER STATE:
- Current Position: \(currentPosition)
- Remaining Duration: \(sourceAnalysis.duration - currentPosition)

Respond ONLY with a JSON object matching this schema:
{
  "decision": {
    "transitionType": "BASS_SWAP | BEAT_MATCH | BEAT_MATCH_EQ | FILTER_TRANSITION | BUILDUP_TO_DROP | DROP_SWITCH | ECHO_OUT | LOOP_TRANSITION | SILENCE_TRIM | SIMPLE_CROSSFADE | HARD_CUT",
    "confidence": 0.92,
    "reason": "Harmonic bass swap on bar boundary with tempo sync"
  },
  "sourceTrack": {
    "transitionStart": \(max(0, sourceAnalysis.duration - 16.0)),
    "transitionEnd": \(sourceAnalysis.duration)
  },
  "targetTrack": {
    "startPosition": 0.0
  },
  "tempo": {
    "targetBPM": \(targetAnalysis.bpm ?? 120.0),
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
    "type": "BASS_SWAP"
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
        request.timeoutInterval = 5.0

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }

            if http.statusCode != 200 {
                let errStr = String(data: data, encoding: .utf8) ?? ""
                SonivoDiagnostics.log("[AutoMix AI] HTTP \(http.statusCode): \(errStr.prefix(90))", tag: "AUTOMIX")
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
                  let plan = try? JSONDecoder().decode(TransitionPlan.self, from: jsonData) else {
                SonivoDiagnostics.log("[AutoMix AI] JSON decode failed: \(cleanedJson.prefix(80))", tag: "AUTOMIX")
                return nil
            }

            SonivoDiagnostics.log("[AutoMix AI] Plan: \(plan.decision.transitionType) (cue: \(String(format: "%.1f", plan.cueTime))s, dur: \(String(format: "%.1f", plan.leadTime))s, rate: \(String(format: "%.2f", plan.tempo.targetPlaybackRate)))", tag: "AUTOMIX")
            return plan
        } catch {
            SonivoDiagnostics.log("[AutoMix AI] Network error: \(error.localizedDescription)", tag: "AUTOMIX")
            return nil
        }
    }
}
