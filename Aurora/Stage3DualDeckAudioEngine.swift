@preconcurrency import AVFAudio
import AudioEngineCore
import Foundation
import MixModels

@MainActor
final class DualDeckAudioEngine {
    static let preferredSampleRate = 48_000.0
    static let preferredIOBufferDuration = 0.005
    private final class Slot: @unchecked Sendable {
        let deck: Deck; let player = AVAudioPlayerNode(); let timePitch = AVAudioUnitTimePitch()
        let eq = AVAudioUnitEQ(numberOfBands: 3); let delay = AVAudioUnitDelay(); let mixer = AVAudioMixerNode()
        var file: AVAudioFile?; var url: URL?; var start = 0.0; var duration = 0.0; var lastPosition = 0.0
        var rate: Float = 1; var prepared = false; var playing = false; var ended = false; var generation = UUID()
        init(_ deck: Deck) { self.deck = deck }
    }
    private let graph = AVAudioEngine(); private let a = Slot(.a); private let b = Slot(.b)
    init() throws {
        for s in [a,b] {
            graph.attach(s.player); graph.attach(s.timePitch); graph.attach(s.eq); graph.attach(s.delay); graph.attach(s.mixer)
            graph.connect(s.player, to: s.timePitch, format: nil); graph.connect(s.timePitch, to: s.eq, format: nil)
            graph.connect(s.eq, to: s.delay, format: nil); graph.connect(s.delay, to: s.mixer, format: nil)
            graph.connect(s.mixer, to: graph.mainMixerNode, format: nil); neutral(s)
        }
        a.mixer.outputVolume = 1; b.mixer.outputVolume = 0
        // Fixed headroom prevents inter-sample clipping when two decks and delay overlap.
        graph.mainMixerNode.outputVolume = 0.82
    }
    func prepare(_ deck: Deck, fileURL: URL, startTimeSeconds: Double = 0) async throws {
        try Task.checkCancellation(); let s=slot(deck); s.generation=UUID(); let generation=s.generation
        s.player.stop(); s.player.reset(); neutral(s)
        let file=try AVAudioFile(forReading:fileURL); let format=file.processingFormat; let sr=format.sampleRate
        guard sr.isFinite, sr>0, format.channelCount>0, file.length>0 else { try? FileManager.default.removeItem(at:fileURL); throw AudioEngineCoreError.unsupportedOutputFormat }
        let duration=Double(file.length)/sr; guard duration.isFinite,duration>0 else { throw AudioEngineCoreError.unsupportedOutputFormat }
        let requested=startTimeSeconds.isFinite ? max(0,startTimeSeconds):0; let start=min(requested,max(0,duration-1/sr))
        let frame=min(file.length-1,max(0,AVAudioFramePosition(start*sr))); let remaining=file.length-frame
        guard remaining>0 else { throw AudioEngineCoreError.conversionFailed("Audio file has no playable frames") }
        let count=AVAudioFrameCount(min(Int64(UInt32.max),remaining)); guard count>0 else { throw AudioEngineCoreError.conversionFailed("Audio segment is empty") }
        s.file=file; s.url=fileURL; s.start=start; s.duration=duration; s.lastPosition=start; s.prepared=true; s.playing=false; s.ended=false
        s.player.scheduleSegment(file,startingFrame:frame,frameCount:count,at:nil) { [weak s] in Task { @MainActor in
            guard let s,s.generation==generation else{return}; s.lastPosition=s.duration;s.playing=false;s.ended=true
        }}
    }
    func play(_ deck:Deck) async throws { let s=slot(deck);guard s.prepared,s.file != nil else{throw AudioEngineCoreError.deckNotPrepared(deck)};if !graph.isRunning{graph.prepare();try graph.start()};guard graph.isRunning else{throw AudioEngineCoreError.conversionFailed("Audio graph did not start")};if !s.player.isPlaying{s.player.play()};s.playing=true }
    func pause(_ deck:Deck) async { let s=slot(deck);s.lastPosition=currentPosition(s);s.player.pause();s.playing=false }
    func resume(_ deck:Deck) async throws { try await play(deck) }
    func stop(_ deck:Deck) async { let s=slot(deck);s.generation=UUID();s.player.stop();s.player.reset();s.file=nil;s.url=nil;s.start=0;s.duration=0;s.lastPosition=0;s.prepared=false;s.playing=false;s.ended=false;neutral(s) }
    func stopEngine() async { await stop(.a);await stop(.b);graph.stop() }
    func setGain(_ gain:Float,for deck:Deck) async { slot(deck).mixer.outputVolume=min(1,max(0,gain.isFinite ? gain:0)) }
    func setRate(_ rate:Float,for deck:Deck) async { let v=min(1.08,max(0.92,rate.isFinite ? rate:1));slot(deck).rate=v;slot(deck).timePitch.rate=v }
    func applyEffect(_ kind:FxKind,value:Float,param:Float?,bpm:Float,to deck:Deck) async { let s=slot(deck);guard value.isFinite else{return};switch kind {
        case .highPass: let x=s.eq.bands[1];x.frequency=min(18000,max(20,value));x.bypass=value<=21
        case .lowPass: let x=s.eq.bands[2];x.frequency=min(20000,max(100,value));x.bypass=value>=19900
        case .bassKill,.bassOn:s.eq.bands[0].gain=min(0,max(-24,-24*min(1,max(0,value))))
        case .echoOut:s.delay.wetDryMix=min(45,max(0,value));s.delay.feedback=min(40,max(0,param ?? 28));s.delay.delayTime=bpm>0 ? min(2,max(0.05,60/Double(bpm)*0.75)):0.375
        case .rateRamp:await setRate(value,for:deck);case .volume:break }
    }
    func resetEffects(_ deck:Deck,preservingRate:Bool=false) async { let s=slot(deck),r=s.rate;neutral(s);if preservingRate{s.rate=r;s.timePitch.rate=r} }
    func skip(from current:Deck,to next:Deck) async throws { try await play(next);await setGain(1,for:next);await stop(current);await resetEffects(next) }
    func crossfade(from outgoing:Deck,to incoming:Deck,durationSeconds:Double) async throws {
        guard durationSeconds.isFinite,durationSeconds>0 else{throw AudioEngineCoreError.conversionFailed("Invalid transition duration")}
        let out=slot(outgoing),inc=slot(incoming);try await play(incoming);let baseline=rendered(inc)
        do { while true { try Task.checkCancellation();let elapsed=max(0,rendered(inc)-baseline)/Double(max(inc.rate,0.01));let p=min(1,max(0,elapsed/durationSeconds));out.mixer.outputVolume=Float(1-p);inc.mixer.outputVolume=Float(p);if p>=1{break};try await ContinuousClock().sleep(for:.milliseconds(5)) } }
        catch { out.mixer.outputVolume=1;inc.mixer.outputVolume=0;inc.lastPosition=currentPosition(inc);inc.player.pause();inc.playing=false;await resetEffects(outgoing);await resetEffects(incoming);throw error }
        await stop(outgoing);await setGain(1,for:incoming);await resetEffects(incoming)
    }
    func snapshot() async -> AudioEngineSnapshot { let f=graph.mainMixerNode.outputFormat(forBus:0);return AudioEngineSnapshot(isRunning:graph.isRunning,sampleRate:f.sampleRate,channels:f.channelCount,deckA:snapshot(a),deckB:snapshot(b)) }
    private func neutral(_ s:Slot){let bass=s.eq.bands[0];bass.filterType = .lowShelf;bass.frequency=180;bass.gain=0;bass.bypass=false;let hp=s.eq.bands[1];hp.filterType = .highPass;hp.frequency=20;hp.bypass=true;let lp=s.eq.bands[2];lp.filterType = .lowPass;lp.frequency=20000;lp.bypass=true;s.delay.wetDryMix=0;s.delay.feedback=0;s.delay.delayTime=0.375;s.rate=1;s.timePitch.rate=1;s.timePitch.pitch=0;s.timePitch.overlap=8}
    private func rendered(_ s:Slot)->Double{guard let r=s.player.lastRenderTime,let t=s.player.playerTime(forNodeTime:r),t.sampleRate>0 else{return 0};return Double(t.sampleTime)/t.sampleRate}
    private func currentPosition(_ s:Slot)->Double{guard s.duration>0 else{return 0};if s.ended{return s.duration};return min(s.duration,max(s.start,s.start+max(0,rendered(s))))}
    private func snapshot(_ s:Slot)->DeckPlaybackSnapshot{let p:Double;if s.ended{p=s.duration}else if s.playing{p=currentPosition(s);s.lastPosition=p}else{p=min(s.duration,max(s.start,s.lastPosition))};return DeckPlaybackSnapshot(deck:s.deck,fileURL:s.url,isPrepared:s.prepared,isPlaying:s.playing,gain:s.mixer.outputVolume,queuedChunks:s.prepared && !s.ended ? 1:0,reachedEndOfFile:s.ended,positionSeconds:p,durationSeconds:s.prepared ? s.duration:nil)}
    private func slot(_ d:Deck)->Slot{d == .a ? a:b}
}
