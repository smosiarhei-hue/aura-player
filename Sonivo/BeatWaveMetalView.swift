import SwiftUI
import MetalKit

/// Two native GPU passes: expensive field once, then seven cheap optical texture samples.
struct BeatWaveMetalView: UIViewRepresentable {
    let motion: MusicWaveMotion
    let darkMode: Bool
    let running: Bool
    let lowPower: Bool

    func makeCoordinator() -> BeatWaveMetalRenderer? { BeatWaveMetalRenderer() }
    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator?.device)
        view.isOpaque = false
        view.layer.isOpaque = false
        view.backgroundColor = .clear
        view.clearColor = MTLClearColorMake(0,0,0,0)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        // SwiftUI's gated TimelineView owns scheduling. No second display-link runs offscreen.
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }
    func updateUIView(_ view: MTKView, context: Context) {
        guard running else { return }
        context.coordinator?.render(view, motion: motion, darkMode: darkMode, lowPower: lowPower)
    }
    static func dismantleUIView(_ view: MTKView, coordinator: BeatWaveMetalRenderer?) {
        view.isPaused = true
        view.releaseDrawables()
    }
}

@MainActor
final class BeatWaveMetalRenderer {
    let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let fieldPipeline: any MTLRenderPipelineState
    private let glassPipeline: any MTLRenderPipelineState
    private let noise: any MTLTexture
    private var fieldTexture: (any MTLTexture)?
    private let inFlight = DispatchSemaphore(value: 2)
    private var lastDraw: TimeInterval = 0

    // Three float4 values have identical alignment/stride to the Metal uniform struct (48 bytes).
    private struct Uniforms {
        var resolution: SIMD4<Float>
        var motion: SIMD4<Float>
        var surface: SIMD4<Float>
    }

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(), let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "beatWaveVertex"),
              let field = library.makeFunction(name: "beatWaveField"),
              let glass = library.makeFunction(name: "beatWaveGlass"),
              let noise = Self.makeNoise(device) else { return nil }
        func pipeline(_ fragment: any MTLFunction, format: MTLPixelFormat) throws -> any MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = format
            // Pass one stores straight RGB. Pass two writes premultiplied RGB to a transparent layer.
            descriptor.colorAttachments[0].isBlendingEnabled = false
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        do {
            self.fieldPipeline = try pipeline(field,format: .rgba16Float)
            self.glassPipeline = try pipeline(glass,format: .bgra8Unorm)
        } catch {
            NSLog("Beat Waves Metal pipeline unavailable: %@", String(describing: error))
            return nil
        }
        self.device=device; self.queue=queue; self.noise=noise
    }

    func render(_ view: MTKView, motion: MusicWaveMotion, darkMode: Bool, lowPower: Bool) {
        let now = CACurrentMediaTime()
        guard now-lastDraw >= (lowPower ? 1/20.0 : 1/30.0)*0.95,
              view.bounds.width>0, view.bounds.height>0,
              inFlight.wait(timeout: .now()) == .success else { return }
        var committed=false
        defer { if !committed { inFlight.signal() } }
        let screenScale = view.window?.screen.scale ?? 2
        let pixelScale = min(screenScale,2) * (lowPower ? 0.35 : 0.5)
        let width=max(1,Int(view.bounds.width*pixelScale))
        let height=max(1,Int(view.bounds.height*pixelScale))
        view.drawableSize=CGSize(width: width,height: height)
        if fieldTexture?.width != width || fieldTexture?.height != height {
            let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width,height: height,mipmapped: false)
            descriptor.usage=[.renderTarget,.shaderRead]
            descriptor.storageMode = .private
            fieldTexture=device.makeTexture(descriptor: descriptor)
        }
        guard let fieldTexture, let drawable=view.currentDrawable,
              let output=view.currentRenderPassDescriptor, let command=queue.makeCommandBuffer() else { return }
        var uniforms=Uniforms(resolution: SIMD4(Float(width),Float(height),0,0),
                              motion: SIMD4(Float(motion.phase),motion.energy,motion.impact,motion.detail),
                              surface: SIMD4(motion.springPosition,darkMode ? 1 : 0,36*Float(pixelScale),0))
        let fieldPass=MTLRenderPassDescriptor()
        fieldPass.colorAttachments[0].texture=fieldTexture
        fieldPass.colorAttachments[0].loadAction = .clear
        fieldPass.colorAttachments[0].storeAction = .store
        fieldPass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0)
        guard let encoder=command.makeRenderCommandEncoder(descriptor: fieldPass) else { return }
        encoder.setRenderPipelineState(fieldPipeline)
        encoder.setFragmentBytes(&uniforms,length: MemoryLayout<Uniforms>.stride,index: 0)
        encoder.setFragmentTexture(noise,index: 0)
        encoder.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: 3)
        encoder.endEncoding()
        guard let optics=command.makeRenderCommandEncoder(descriptor: output) else { return }
        optics.setRenderPipelineState(glassPipeline)
        optics.setFragmentBytes(&uniforms,length: MemoryLayout<Uniforms>.stride,index: 0)
        optics.setFragmentTexture(fieldTexture,index: 0)
        optics.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: 3)
        optics.endEncoding()
        let semaphore=inFlight
        command.addCompletedHandler { _ in semaphore.signal() }
        command.present(drawable)
        committed=true
        lastDraw=now
        command.commit()
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
