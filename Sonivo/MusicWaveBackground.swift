import SwiftUI
import AVFoundation
import UIKit

/// Approved Beat Waves field, scoped to the scrolling My Wave hero. No audio ownership here.
struct MusicWaveBackground: View {
    let colors: [Color] // Retained call-site compatibility; approved shader uses its Sonivo palette.
    let isPlaying: Bool
    let isVisible: Bool
    @State private var analyzer = SpectrumAnalyzer.shared
    @State private var isOnScreen = false
    @State private var motion = MusicWaveMotion()
    @State private var presentation = BeatWavePresentation()
    @State private var previousFrame: TimeInterval?
    @State private var outputDelay: TimeInterval = 0
    @State private var lastDelayCheck: TimeInterval = 0
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    private var running: Bool { isOnScreen && isPlaying && isVisible && !reduceMotion && scenePhase == .active }
    private var interval: Double { lowPower ? 1 / 20.0 : 1 / 30.0 }

    var body: some View {
        TimelineView(.animation(minimumInterval: interval, paused: !running)) { timeline in
            BeatWaveMetalView(motion: motion, darkMode: colorScheme == .dark, running: running, lowPower: lowPower)
                .onChange(of: timeline.date) { _, date in
                    guard running else { previousFrame=nil; return }
                    let now=date.timeIntervalSinceReferenceDate
                    let delta=Float(min(0.10,max(0,now-(previousFrame ?? now))))
                    previousFrame=now
                    if now-lastDelayCheck>1 {
                        let session=AVAudioSession.sharedInstance()
                        // Route-reported estimate, not a promise of exact Bluetooth/acoustic latency.
                        outputDelay=max(0,min(0.5,session.outputLatency+session.ioBufferDuration))
                        lastDelayCheck=now
                    }
                    guard analyzer.beatWaveFrame.capturedAt>0 else {
                        presentation.reset(); motion.settle(); return
                    }
                    presentation.push(analyzer.beatWaveFrame)
                    let frame=presentation.sample(now: now,estimatedOutputDelay: outputDelay)
                    let age=now-frame.capturedAt
                    let fresh=frame.capturedAt>0 && age>=0 && age<outputDelay+0.4
                    let newKick=motion.advance(delta: delta,frame: frame,hasFreshAudio: fresh)
                    if newKick {
                        MusicHapticsManager.core.playBeatWaveKick(eventID: frame.kickEventID,
                                                               strength: frame.kickConfidence)
                    }
                }
        }
        .mask {
            RoundedRectangle(cornerRadius: 40,style: .continuous)
                .fill(.white)
                .blur(radius: 24)
                .padding(12)
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: running) { _, active in
            previousFrame=nil
            presentation.reset()
            motion.consume(analyzer.beatWaveFrame.kickEventID)
            MusicHapticsManager.core.setBeatWaveOverride(active)
            if !active { motion.settle() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower=ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .onAppear { isOnScreen=true; previousFrame=nil }
        .onDisappear {
            isOnScreen=false; previousFrame=nil; presentation.reset(); motion.settle()
            MusicHapticsManager.core.setBeatWaveOverride(false)
        }
    }
}
