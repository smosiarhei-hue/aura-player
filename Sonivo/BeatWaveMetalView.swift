import SwiftUI
import MetalKit
import AVFoundation
import QuartzCore

/// One transparent Metal pass. CADisplayLink is the only frame scheduler.
struct BeatWaveMetalView: UIViewRepresentable {
    let colors: [Color]
    let darkMode: Bool
    let running: Bool
    let lowPower: Bool
    func makeCoordinator() -> BeatWaveMetalRenderer? {
        guard let device=MTLCreateSystemDefaultDevice() else { return nil }
        return BeatWaveMetalRenderer(device: device)
    }
    func makeUIView(context: Context) -> MTKView {
        let view=MTKView(frame: .zero,device: context.coordinator?.device)
        view.isOpaque=false; view.layer.isOpaque=false; view.backgroundColor = .clear
        view.clearColor=MTLClearColorMake(0,0,0,0)
        view.colorPixelFormat = .bgra8Unorm
        if let layer=view.layer as? CAMetalLayer { layer.colorspace=CGColorSpace(name: CGColorSpace.sRGB) }
        view.framebufferOnly=true
        view.delegate=context.coordinator
        view.autoResizeDrawable=false
        // Apple explicit-drawing mode: the ONE display link calls view.draw(),
        // which opens/closes the MTKView frame and invokes draw(in:) on the delegate.
        view.isPaused=true; view.enableSetNeedsDisplay=false
        view.isUserInteractionEnabled=false; view.isAccessibilityElement=false
        return view
    }
    func updateUIView(_ view: MTKView,context: Context) {
        context.coordinator?.configure(view,colors: colors,darkMode: darkMode,running: running,lowPower: lowPower)
    }
    static func dismantleUIView(_ view: MTKView,coordinator: BeatWaveMetalRenderer?) {
        coordinator?.stop()
        view.delegate=nil
        view.releaseDrawables()
    }
}

/// Weak target prevents CADisplayLink retaining the renderer after the hero is removed.
@MainActor
private final class BeatWaveDisplayLinkTarget: NSObject {
    weak var renderer: BeatWaveMetalRenderer?
    init(_ renderer: BeatWaveMetalRenderer) { self.renderer=renderer }
    @objc func tick(_ link: CADisplayLink) {
        guard let renderer else { link.invalidate(); return }
        renderer.tick(link)
    }
}

/// Completed GPU timing feedback, safe to update from Metal's completion thread.
nonisolated private final class BeatWaveGPUFeedback: @unchecked Sendable {
    private let lock=NSLock()
    private var milliseconds: Double = 0
    func record(_ value: Double) {
        guard value.isFinite, value>0 else { return }
        lock.lock(); milliseconds=milliseconds==0 ? value : milliseconds*0.8+value*0.2; lock.unlock()
    }
    func sample() -> Double { lock.lock(); defer { lock.unlock() }; return milliseconds }
}

@MainActor
final class BeatWaveMetalRenderer: NSObject, @preconcurrency MTKViewDelegate {
    let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let sdrPipeline: any MTLRenderPipelineState
    private let hdrPipeline: (any MTLRenderPipelineState)?
    private let noise: any MTLTexture
    private let inFlight=DispatchSemaphore(value: 2)
    private let gpuFeedback=BeatWaveGPUFeedback()
    private weak var view: MTKView?
    private var displayLink: CADisplayLink?
    private var linkTarget: BeatWaveDisplayLinkTarget?
    private var darkMode=false
    private var lowPower=false
    private var outputHDR=false
    private var headroom: Float=1
    private var targetHeadroom: Float=1
    private var palette=[SIMD3<Float>](repeating: SIMD3(0.5,0.5,0.5),count: 3)
    private var targetPalette=[SIMD3<Float>](repeating: SIMD3(0.5,0.5,0.5),count: 3)
    private var paletteInitialized=false
    private var motion=MusicWaveMotion()
    private var presentation=BeatWavePresentation()
    private var previousTimestamp: CFTimeInterval?
    private var outputDelay: TimeInterval=0
    private var lastDelayCheck: TimeInterval=0
    private var lastQualityCheck: CFTimeInterval=0
    private var renderScale: CGFloat=0.35
    private var targetFPS=0
    private var diagnosticWindow: CFTimeInterval=0
    private var diagnosticTicks=0
    private var diagnosticSubmissions=0
    private var diagnosticBusyDrops=0
    private var diagnosticFrameAge: Double=0
    private var previousMediaTime: TimeInterval?
    private var diagnosticClock="capture"
    private var diagnosticDisplayLead: Double=0
    private var strandTable=[Strand](repeating: Strand(),count: 32)

    private struct Uniforms {
        var resolution: SIMD4<Float>
        var motion: SIMD4<Float>
        var surface: SIMD4<Float>
        var colorA: SIMD4<Float>
        var colorB: SIMD4<Float>
        var colorC: SIMD4<Float>
        var display: SIMD4<Float>
    }
    private struct Strand {
        var direction=SIMD4<Float>(repeating: 0)
        var pigment=SIMD4<Float>(repeating: 0)
    }
    init?(device: any MTLDevice) {
        guard let queue=device.makeCommandQueue(),
              let library=device.makeDefaultLibrary(), let vertex=library.makeFunction(name: "beatWaveVertex"),
              let field=library.makeFunction(name: "beatWaveField"), let noise=Self.makeNoise(device) else { return nil }
        let descriptor=MTLRenderPipelineDescriptor()
        descriptor.vertexFunction=vertex; descriptor.fragmentFunction=field
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled=false
        do { self.sdrPipeline=try device.makeRenderPipelineState(descriptor: descriptor) }
        catch { NSLog("Beat Waves pipeline unavailable: %@",String(describing: error)); return nil }
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        self.hdrPipeline=try? device.makeRenderPipelineState(descriptor: descriptor)
        self.device=device; self.queue=queue; self.noise=noise
        super.init()
    }

    func configure(_ view: MTKView,colors: [Color],darkMode: Bool,running: Bool,lowPower: Bool) {
        self.view=view; self.darkMode=darkMode; self.lowPower=lowPower
        setPalette(colors)
        guard running else { stop(); return }
        configureOutput(view)
        if displayLink==nil {
            if SpectrumAnalyzer.shared.beatWaveFrame.mediaTime==nil {
                motion.consume(SpectrumAnalyzer.shared.beatWaveFrame.kickEventID)
            }
            _=SpectrumAnalyzer.shared.drainBeatWaveFrames()
            previousTimestamp=nil; presentation.reset(); targetFPS=0
            diagnosticWindow=0; diagnosticTicks=0; diagnosticSubmissions=0; diagnosticBusyDrops=0
            renderScale=lowPower ? 0.3 : 0.35
            let target=BeatWaveDisplayLinkTarget(self)
            let link=CADisplayLink(target: target,selector: #selector(BeatWaveDisplayLinkTarget.tick(_:)))
            linkTarget=target; displayLink=link
            link.add(to: .main,forMode: .common) // Keeps rendering during scroll tracking.
            MusicHapticsManager.core.setBeatWaveOverride(true)
        }
        configureFrameRate()
    }
    private func configureFrameRate() {
        let maximum=view?.window?.windowScene?.screen.maximumFramesPerSecond ?? 60
        let desired=lowPower ? min(30,maximum) : min(120,maximum)
        guard desired != targetFPS else { return }
        targetFPS=desired
        displayLink?.preferredFrameRateRange=CAFrameRateRange(minimum: Float(lowPower ? desired : min(60,desired)),maximum: Float(desired),preferred: Float(desired))
    }
    func stop() {
        displayLink?.invalidate(); displayLink=nil; linkTarget=nil
        previousTimestamp=nil; previousMediaTime=nil; presentation.reset(); motion.settle()
        MusicHapticsManager.core.setBeatWaveOverride(false)
        (view?.layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent=false
    }
    fileprivate func tick(_ link: CADisplayLink) {
        guard let view,view.window != nil else { return }
        // The screen may attach after makeUIView; re-read refresh rate and AVAILABLE EDR headroom.
        configureFrameRate()
        configureOutput(view)
        let dt=Float(max(0,min(0.1,link.timestamp-(previousTimestamp ?? link.timestamp))))
        previousTimestamp=link.timestamp
        diagnosticTicks += 1
        let now=Date.timeIntervalSinceReferenceDate
        if now-lastDelayCheck>1 {
            let session=AVAudioSession.sharedInstance()
            outputDelay=max(0,min(0.5,session.outputLatency+session.ioBufferDuration))
            lastDelayCheck=now
        }
        // Draw for the UPCOMING display deadline, not the previous presented frame.
        let displayLead=max(0,min(0.05,link.targetTimestamp-CACurrentMediaTime()))
        diagnosticDisplayLead=displayLead*1000
        let capture=SpectrumAnalyzer.shared.beatWaveFrame
        let captures=SpectrumAnalyzer.shared.drainBeatWaveFrames()
        if capture.capturedAt<=0 { presentation.reset(); motion.settle(); previousMediaTime=nil }
        else {
            let frame: BeatWaveAudioFrame
            let fresh: Bool
            if capture.mediaTime != nil,let clock=StreamBeatTap.shared.currentMediaClock() {
                if let previousMediaTime,clock.time<previousMediaTime-0.02 || clock.time-previousMediaTime>0.25 {
                    presentation.reset(); motion.settle()
                }
                previousMediaTime=clock.time
                for feature in captures { presentation.push(feature) }
                presentation.push(capture)
                let mediaDeadline=clock.time+displayLead*max(0,clock.rate)
                frame=clock.rate>0 ? (presentation.sampleMedia(at: mediaDeadline) ?? BeatWaveAudioFrame()) : BeatWaveAudioFrame()
                let age=mediaDeadline-(frame.mediaTime ?? mediaDeadline)
                diagnosticFrameAge=age*1000; diagnosticClock="media"
                fresh=frame.mediaTime != nil && clock.rate>0 && age>=0 && age<0.12
                // AVPlayer's media timebase owns stream A/V sync; do not add a second guessed route delay.
            } else {
                previousMediaTime=nil
                for feature in captures { presentation.push(feature) }
                presentation.push(capture)
                frame=presentation.sample(now: now+displayLead,estimatedOutputDelay: outputDelay)
                let age=now-frame.capturedAt
                diagnosticFrameAge=frame.capturedAt>0 ? age*1000 : 0; diagnosticClock="capture"
                fresh=frame.capturedAt>0 && age>=(-displayLead) && age<outputDelay+0.4
            }
            let newKick=motion.advance(delta: dt,frame: frame,hasFreshAudio: fresh)
            if newKick { MusicHapticsManager.core.playBeatWaveKick(eventID: frame.kickEventID,strength: frame.kickConfidence) }
        }
        let paletteMix=1-exp(-dt/0.85)
        for i in 0..<3 { palette[i]+=(targetPalette[i]-palette[i])*paletteMix }
        headroom=min(targetHeadroom,headroom+(targetHeadroom-headroom)*(1-exp(-dt/0.8))) // Drop immediately; never exceed available headroom.
        // Reduce pixel work rather than limiting ProMotion to the old hard-coded 30 FPS.
        if link.timestamp-lastQualityCheck>0.75 {
            lastQualityCheck=link.timestamp
            let gpuMs=gpuFeedback.sample()
            let budget=1000.0/Double(max(1,targetFPS))
            let ceiling: CGFloat=lowPower ? 0.3 : (outputHDR ? 0.4 : 0.5)
            if gpuMs>budget*0.8 { renderScale=max(0.25,renderScale-0.05) }
            else if gpuMs>0 && gpuMs<budget*0.45 { renderScale=min(ceiling,renderScale+0.025) }
            renderScale=min(ceiling,renderScale)
        }
        // Do not bypass MTKView's frame lifecycle or reuse its cached drawable.
        // The pool encloses draw() itself so MetalKit's autoreleased frame resources drain.
        autoreleasepool { view.draw() }
        if diagnosticWindow==0 { diagnosticWindow=link.timestamp }
        let elapsed=link.timestamp-diagnosticWindow
        if elapsed>=5 {
            // Local report only. Submitted frames are not proof of actually displayed 120 FPS.
            let ticks=Double(diagnosticTicks)/elapsed, submitted=Double(diagnosticSubmissions)/elapsed
            let gpu=gpuFeedback.sample()
            SonivoDiagnostics.log(String(format: "ticks=%.1f submitted=%.1f target=%d gpuMs=%.2f busyDrops=%d scale=%.3f audioAgeMs=%.1f routeDelayMs=%.1f edr=%d headroom=%.2f clock=%@ displayLeadMs=%.1f",ticks,submitted,targetFPS,gpu,diagnosticBusyDrops,Double(renderScale),diagnosticFrameAge,outputDelay*1000,outputHDR ? 1 : 0,Double(headroom),diagnosticClock,diagnosticDisplayLead),tag: "BEAT_WAVE")
            diagnosticWindow=link.timestamp; diagnosticTicks=0; diagnosticSubmissions=0; diagnosticBusyDrops=0
        }
    }

    // Called synchronously by our MAIN-run-loop view.draw(), not a background MetalKit timer.
    // @preconcurrency adapts the SDK's nonisolated delegate protocol; all UIKit access stays MainActor.
    func draw(in view: MTKView) {
        guard displayLink != nil else { return }
        autoreleasepool { render(view) }
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // No render here: drawing is owned exclusively by the display-link frame callback.
    }

    private func setPalette(_ colors: [Color]) {
        let space=CGColorSpace(name: CGColorSpace.sRGB)!
        let rgb=colors.prefix(3).compactMap { color -> SIMD3<Float>? in
            guard let converted=UIColor(color).cgColor.converted(to: space,intent: .relativeColorimetric,options: nil),
                  let c=converted.components,c.count>=3 else { return nil }
            return SIMD3(Float(c[0]),Float(c[1]),Float(c[2]))
        }
        guard let first=rgb.first else { return }
        targetPalette=[first,rgb.count>1 ? rgb[1] : first,rgb.count>2 ? rgb[2] : (rgb.last ?? first)]
        if !paletteInitialized { palette=targetPalette; paletteInitialized=true }
    }

    private func configureOutput(_ view: MTKView) {
        guard let layer=view.layer as? CAMetalLayer else { return }
        let screen=view.window?.windowScene?.screen
        let potential=Float(screen?.potentialEDRHeadroom ?? 1)
        let current=Float(screen?.currentEDRHeadroom ?? 1)
        let desired = !lowPower && potential.isFinite && potential>1 && hdrPipeline != nil
        if desired != outputHDR {
            outputHDR=desired; headroom=1
            view.releaseDrawables()
            view.colorPixelFormat=desired ? .rgba16Float : .bgra8Unorm
            layer.colorspace=CGColorSpace(name: desired ? CGColorSpace.extendedLinearDisplayP3 : CGColorSpace.sRGB)
        }
        if layer.wantsExtendedDynamicRangeContent != desired { layer.wantsExtendedDynamicRangeContent=desired }
        targetHeadroom=desired ? BeatWavePaletteMath.safeHeadroom(potential: potential,current: current,lowPower: lowPower) : 1
    }

    private func updateStrands() {
        let count: Float=24 // More visible filaments, but one strand call each instead of crossed pairs.
        for i in 0..<32 {
            let index=Float(i),fade=max(0,min(1,count-index)),id=index/(count-1)
            if fade<=0 { strandTable[i]=Strand(); continue }
            let angle: Float=0.28 // ONE fixed direction: coherent parallel flow, never radial/orbiting.
            let blend=id
            var tint=palette[0]*(1-blend)+palette[1]*blend
            let mixC: Float=0.20*id
            tint=tint*(1-mixC)+palette[2]*mixC
            let lane=(id-0.5)*1.12
            strandTable[i].direction=SIMD4(sin(angle),cos(angle),fade,lane)
            strandTable[i].pigment=SIMD4(tint.x,tint.y,tint.z,index)
        }
    }

    private func render(_ view: MTKView) {
        guard view.bounds.width>0,view.bounds.height>0 else { return }
        guard inFlight.wait(timeout: .now()) == .success else { diagnosticBusyDrops += 1; return }
        var committed=false
        defer { if !committed { inFlight.signal() } }
        let screenScale=view.window?.windowScene?.screen.scale ?? 2
        let pixelScale=min(screenScale,2)*renderScale
        let width=max(1,Int(view.bounds.width*pixelScale)),height=max(1,Int(view.bounds.height*pixelScale))
        let size=CGSize(width: width,height: height)
        if view.drawableSize != size { view.drawableSize=size }
        guard let command=queue.makeCommandBuffer() else { return }
        updateStrands()
        var uniforms=Uniforms(resolution: SIMD4(Float(width),Float(height),0,0),
                              motion: SIMD4(Float(motion.phase),motion.energy,motion.impact,motion.detail),
                              surface: SIMD4(motion.springPosition,darkMode ? 1 : 0,lowPower ? 2 : 3,motion.lowEnergy),
                              colorA: SIMD4(palette[0].x,palette[0].y,palette[0].z,1),
                              colorB: SIMD4(palette[1].x,palette[1].y,palette[1].z,1),
                              colorC: SIMD4(palette[2].x,palette[2].y,palette[2].z,1),
                              display: SIMD4(headroom,outputHDR ? 1 : 0,0,0))
        // Late acquisition inside the MetalKit draw callback: descriptor obtains THIS frame's drawable.
        guard let pass=view.currentRenderPassDescriptor,let drawable=view.currentDrawable,
              let encoder=command.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(outputHDR ? (hdrPipeline ?? sdrPipeline) : sdrPipeline)
        encoder.setFragmentBytes(&uniforms,length: MemoryLayout<Uniforms>.stride,index: 0)
        strandTable.withUnsafeBytes { bytes in
            if let base=bytes.baseAddress { encoder.setFragmentBytes(base,length: bytes.count,index: 1) }
        }
        encoder.setFragmentTexture(noise,index: 0)
        encoder.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: 3)
        encoder.endEncoding()
        let semaphore=inFlight,feedback=gpuFeedback
        command.addCompletedHandler { buffer in
            if buffer.status == .error {
                SonivoDiagnostics.log("GPU command failed: \(String(describing: buffer.error))",tag: "BEAT_WAVE")
            } else {
                feedback.record((buffer.gpuEndTime-buffer.gpuStartTime)*1000)
            }
            semaphore.signal()
        }
        command.present(drawable); committed=true; command.commit()
        diagnosticSubmissions += 1
    }

    private static func makeNoise(_ device: any MTLDevice) -> (any MTLTexture)? {
        let data=BeatWaveNoise.rgba()
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,width: 512,height: 512,mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture=device.makeTexture(descriptor: descriptor) else { return nil }
        data.withUnsafeBytes { bytes in
            if let base=bytes.baseAddress {
                texture.replace(region: MTLRegionMake2D(0,0,512,512),mipmapLevel: 0,withBytes: base,bytesPerRow: 512*4)
            }
        }
        return texture
    }
}
