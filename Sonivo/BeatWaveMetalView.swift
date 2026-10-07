import SwiftUI
import MetalKit
import AVFoundation

/// One transparent Metal pass. CADisplayLink is the only frame scheduler.
struct BeatWaveMetalView: UIViewRepresentable {
    let darkMode: Bool
    let running: Bool
    let lowPower: Bool
    func makeCoordinator() -> BeatWaveMetalRenderer? { BeatWaveMetalRenderer() }
    func makeUIView(context: Context) -> MTKView {
        let view=MTKView(frame: .zero,device: context.coordinator?.device)
        view.isOpaque=false; view.layer.isOpaque=false; view.backgroundColor = .clear
        view.clearColor=MTLClearColorMake(0,0,0,0)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly=true
        view.autoResizeDrawable=false
        // No MTKView timer competes with our display link.
        view.isPaused=true; view.enableSetNeedsDisplay=false
        view.isUserInteractionEnabled=false; view.isAccessibilityElement=false
        return view
    }
    func updateUIView(_ view: MTKView,context: Context) {
        context.coordinator?.configure(view,darkMode: darkMode,running: running,lowPower: lowPower)
    }
    static func dismantleUIView(_ view: MTKView,coordinator: BeatWaveMetalRenderer?) {
        coordinator?.stop()
        view.releaseDrawables()
    }
}

/// Weak target prevents CADisplayLink retaining the renderer after the hero is removed.
@MainActor
private final class BeatWaveDisplayLinkTarget: NSObject {
    weak var renderer: BeatWaveMetalRenderer?
    init(_ renderer: BeatWaveMetalRenderer) { self.renderer=renderer }
    @objc func tick(_ link: CADisplayLink) { renderer?.tick(link) }
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
final class BeatWaveMetalRenderer {
    let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let pipeline: any MTLRenderPipelineState
    private let noise: any MTLTexture
    private let inFlight=DispatchSemaphore(value: 2)
    private let gpuFeedback=BeatWaveGPUFeedback()
    private weak var view: MTKView?
    private var displayLink: CADisplayLink?
    private var linkTarget: BeatWaveDisplayLinkTarget?
    private var darkMode=false
    private var lowPower=false
    private var motion=MusicWaveMotion()
    private var presentation=BeatWavePresentation()
    private var previousTimestamp: CFTimeInterval?
    private var outputDelay: TimeInterval=0
    private var lastDelayCheck: TimeInterval=0
    private var lastQualityCheck: CFTimeInterval=0
    private var renderScale: CGFloat=0.35
    private var targetFPS=0
    private var strandTable=[Strand](repeating: Strand(),count: 32)

    private struct Uniforms {
        var resolution: SIMD4<Float>
        var motion: SIMD4<Float>
        var surface: SIMD4<Float>
    }
    private struct Strand {
        var direction=SIMD4<Float>(repeating: 0)
        var pigment=SIMD4<Float>(repeating: 0)
    }
    init?() {
        guard let device=MTLCreateSystemDefaultDevice(), let queue=device.makeCommandQueue(),
              let library=device.makeDefaultLibrary(), let vertex=library.makeFunction(name: "beatWaveVertex"),
              let field=library.makeFunction(name: "beatWaveField"), let noise=Self.makeNoise(device) else { return nil }
        let descriptor=MTLRenderPipelineDescriptor()
        descriptor.vertexFunction=vertex; descriptor.fragmentFunction=field
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled=false
        do { self.pipeline=try device.makeRenderPipelineState(descriptor: descriptor) }
        catch { NSLog("Beat Waves pipeline unavailable: %@",String(describing: error)); return nil }
        self.device=device; self.queue=queue; self.noise=noise
    }

    func configure(_ view: MTKView,darkMode: Bool,running: Bool,lowPower: Bool) {
        self.view=view; self.darkMode=darkMode; self.lowPower=lowPower
        guard running else { stop(); return }
        if displayLink==nil {
            motion.consume(SpectrumAnalyzer.shared.beatWaveFrame.kickEventID)
            previousTimestamp=nil; presentation.reset(); targetFPS=0
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
        previousTimestamp=nil; presentation.reset(); motion.settle()
        MusicHapticsManager.core.setBeatWaveOverride(false)
    }
    fileprivate func tick(_ link: CADisplayLink) {
        guard let view,view.window != nil else { return }
        // The screen may attach after makeUIView; re-read its actual supported refresh rate.
        configureFrameRate()
        let dt=Float(max(0,min(0.1,link.timestamp-(previousTimestamp ?? link.timestamp))))
        previousTimestamp=link.timestamp
        let now=Date.timeIntervalSinceReferenceDate
        if now-lastDelayCheck>1 {
            let session=AVAudioSession.sharedInstance()
            outputDelay=max(0,min(0.5,session.outputLatency+session.ioBufferDuration))
            lastDelayCheck=now
        }
        let capture=SpectrumAnalyzer.shared.beatWaveFrame
        if capture.capturedAt<=0 { presentation.reset(); motion.settle() }
        else {
            presentation.push(capture)
            let frame=presentation.sample(now: now,estimatedOutputDelay: outputDelay)
            let age=now-frame.capturedAt
            let fresh=frame.capturedAt>0 && age>=0 && age<outputDelay+0.4
            let newKick=motion.advance(delta: dt,frame: frame,hasFreshAudio: fresh)
            if newKick {
                MusicHapticsManager.core.playBeatWaveKick(eventID: frame.kickEventID,strength: frame.kickConfidence)
            }
        }
        // Reduce pixel work rather than limiting ProMotion to the old hard-coded 30 FPS.
        if link.timestamp-lastQualityCheck>0.75 {
            lastQualityCheck=link.timestamp
            let gpuMs=gpuFeedback.sample()
            let budget=1000.0/Double(max(1,targetFPS))
            let ceiling: CGFloat=lowPower ? 0.3 : 0.5
            if gpuMs>budget*0.8 { renderScale=max(0.25,renderScale-0.05) }
            else if gpuMs>0 && gpuMs<budget*0.45 { renderScale=min(ceiling,renderScale+0.025) }
            renderScale=min(ceiling,renderScale)
        }
        render(view)
    }

    private func updateStrands() {
        let t=Float(motion.phase)*0.6
        let count=max(14+(6+motion.energy*2.5)*sin(t*0.3),1)
        let a=SIMD3<Float>(1,0.15,0.55),b=SIMD3<Float>(0.58,0.20,0.95),c=SIMD3<Float>(0.10,0.85,0.98)
        for i in 0..<32 {
            let index=Float(i),fade=max(0,min(1,count-index)),id=index/count
            if fade<=0 { strandTable[i]=Strand(); continue }
            let angle=id*(2*Float.pi)+t*0.12
            let tintTime=id+t*0.05
            let blend=sin(tintTime*Float.pi*0.5)*0.5+0.5
            let shade=cos(tintTime*(2*Float.pi))*0.5+0.5
            var tint=a*(1-blend)+b*blend
            let mixC=0.28*sin(tintTime*2.5)+0.28
            tint=(tint*(1-mixC)+c*mixC)*(0.6+0.4*shade)
            tint *= (0.6+0.4*sin(index*3+t))*fade
            strandTable[i].direction=SIMD4(sin(angle),cos(angle),fade,0)
            strandTable[i].pigment=SIMD4(tint.x,tint.y,tint.z,0)
        }
    }
    private func render(_ view: MTKView) {
        guard view.bounds.width>0,view.bounds.height>0,
              inFlight.wait(timeout: .now()) == .success else { return }
        var committed=false
        defer { if !committed { inFlight.signal() } }
        let screenScale=view.window?.windowScene?.screen.scale ?? 2
        let pixelScale=min(screenScale,2)*renderScale
        let width=max(1,Int(view.bounds.width*pixelScale)),height=max(1,Int(view.bounds.height*pixelScale))
        let size=CGSize(width: width,height: height)
        if view.drawableSize != size { view.drawableSize=size }
        guard let drawable=view.currentDrawable,let pass=view.currentRenderPassDescriptor,
              let command=queue.makeCommandBuffer() else { return }
        updateStrands()
        var uniforms=Uniforms(resolution: SIMD4(Float(width),Float(height),0,0),
                              motion: SIMD4(Float(motion.phase),motion.energy,motion.impact,motion.detail),
                              surface: SIMD4(motion.springPosition,darkMode ? 1 : 0,lowPower ? 2 : 3,0))
        guard let encoder=command.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms,length: MemoryLayout<Uniforms>.stride,index: 0)
        strandTable.withUnsafeBytes { bytes in
            if let base=bytes.baseAddress { encoder.setFragmentBytes(base,length: bytes.count,index: 1) }
        }
        encoder.setFragmentTexture(noise,index: 0)
        encoder.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: 3)
        encoder.endEncoding()
        let semaphore=inFlight,feedback=gpuFeedback
        command.addCompletedHandler { buffer in
            feedback.record((buffer.gpuEndTime-buffer.gpuStartTime)*1000)
            semaphore.signal()
        }
        command.present(drawable); committed=true; command.commit()
    }

    private static func makeNoise(_ device: any MTLDevice) -> (any MTLTexture)? {
        // Same deterministic 128x128 hash and Hermite interpolation as supplied noiseTexture.ts.
        var permutation=[Float](repeating: 0,count: 16_384)
        for i in permutation.indices {
            var a=(UInt32(0x27d4eb2d)^UInt32(i)) &* 0x165667b1
            a ^= a >> 15
            a = a &* 0x2545f491
            permutation[i]=Float(Double(a ^ (a >> 13))/4_294_967_296.0)
        }
        func sample(_ x: Int,_ y: Int) -> Float { permutation[(y&127)*128+(x&127)] }
        var data=[UInt8](repeating: 0,count: 512*512*4)
        for y in 0..<512 {
            let ny=Float(y)/4, iy=Int(ny), ly=ny-Float(iy), sy=ly*ly*(3-2*ly)
            for x in 0..<512 {
                let nx=Float(x)/4, ix=Int(nx), lx=nx-Float(ix), sx=lx*lx*(3-2*lx)
                let a=sample(ix,iy)+(sample(ix+1,iy)-sample(ix,iy))*sx
                let b=sample(ix,iy+1)+(sample(ix+1,iy+1)-sample(ix,iy+1))*sx
                let value=UInt8(max(0,min(255,Int(((a+(b-a)*sy)*255).rounded()))))
                let i=(y*512+x)*4
                data[i]=value; data[i+1]=value; data[i+2]=value; data[i+3]=255
            }
        }
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
