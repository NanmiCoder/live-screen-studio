import AppKit
import Metal
import QuartzCore

/// Renders the zoomed IOSurface onto a layer inside `CursorCanvasWindow`, so the zoomed frame, ink strokes,
/// click ripples and cursor commit atomically in a single `NSWindow` / `CAContext` with zero tearing.
///
/// Uses a `CAMetalLayer` with zero-copy `IOSurface -> MTLTexture` wrapping and an exact 9-tap hardware-bilinear
/// Catmull-Rom bicubic filter for crisp, shimmer-free sub-pixel panning at 60–120 Hz. Falls back to a plain
/// `CALayer` if Metal is unavailable (e.g. headless CI without a GPU).
final class ZoomSurfaceRenderer {
    let layer: CALayer

    private let displaySize: CGSize
    private let slitFraction: CGFloat

    // Metal pipeline state (nil when running on the CALayer fallback).
    private let metalLayer: CAMetalLayer?
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let pipelineState: MTLRenderPipelineState?
    private let samplerState: MTLSamplerState?
    private let fallbackLayer: CALayer?

    // Cached zero-copy texture wrapper for the active IOSurface so panning across a static screen allocates nothing.
    private var cachedSurface: IOSurface?
    private var cachedSurfaceID: IOSurfaceID = 0
    private var cachedTexture: MTLTexture?
    private var lastSequence: Int = -1
    private var lastViewport: CGRect?

    init(screen: NSScreen) {
        displaySize = screen.frame.size
        let scale = max(screen.backingScaleFactor, 1)
        // Leave a 1-physical-pixel transparent slit at the very bottom edge of the transparent host window.
        // Because the opaque layer is strictly smaller than full-screen windows underneath, macOS never marks
        // browsers (Chrome/Safari/Electron) as occluded, while avoiding full-screen 5K desktop alpha blending
        // (alphaValue = 0.999) on every pan frame.
        let slitPoints = 1 / scale
        slitFraction = displaySize.height > 0 ? slitPoints / displaySize.height : 0
        let layerFrame = CGRect(
            x: 0,
            y: slitPoints,
            width: displaySize.width,
            height: max(displaySize.height - slitPoints, 1)
        )

        if let mtl = Self.makeMetalResources() {
            let ml = CAMetalLayer()
            ml.device = mtl.device
            ml.pixelFormat = .bgra8Unorm
            ml.colorspace = screen.colorSpace?.cgColorSpace
            ml.isOpaque = true
            ml.framebufferOnly = true
            ml.displaySyncEnabled = true
            ml.presentsWithTransaction = true
            ml.maximumDrawableCount = 3
            ml.contentsScale = scale
            ml.frame = layerFrame
            ml.drawableSize = CGSize(
                width: max((layerFrame.width * scale).rounded(), 1),
                height: max((layerFrame.height * scale).rounded(), 1)
            )
            ml.isHidden = true

            layer = ml
            metalLayer = ml
            device = mtl.device
            commandQueue = mtl.commandQueue
            pipelineState = mtl.pipelineState
            samplerState = mtl.samplerState
            fallbackLayer = nil
        } else {
            let fallback = CALayer()
            fallback.frame = layerFrame
            fallback.isOpaque = true
            fallback.contentsGravity = .resize
            fallback.magnificationFilter = .linear
            fallback.isHidden = true

            layer = fallback
            metalLayer = nil
            device = nil
            commandQueue = nil
            pipelineState = nil
            samplerState = nil
            fallbackLayer = fallback
        }
    }

    func clear() {
        cachedSurface = nil
        cachedSurfaceID = 0
        cachedTexture = nil
        lastSequence = -1
        lastViewport = nil
        layer.isHidden = true
        fallbackLayer?.contents = nil
    }

    /// Renders `viewport` (display-local, top-left origin, in points) of `surface`.
    /// Must be called inside an active `CATransaction` when `presentsWithTransaction` is enabled.
    func render(surface: IOSurface?, sequence: Int, viewport: CGRect) {
        let resolvedSurface = surface ?? cachedSurface
        guard let resolvedSurface else { return }

        // Skip redundant GPU work when both frame sequence and viewport are unchanged and already visible.
        if !layer.isHidden, sequence == lastSequence, resolvedSurface === cachedSurface, lastViewport == viewport {
            return
        }

        if let metalLayer, let device, let commandQueue, let pipelineState, let samplerState {
            guard let texture = texture(for: resolvedSurface, device: device) else { return }
            guard let drawable = metalLayer.nextDrawable() else { return }
            guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
            encoder.setRenderPipelineState(pipelineState)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(samplerState, index: 0)

            // Map the Metal layer's vertical range (top 0 .. 1 - slitFraction) into the exact sub-rect of
            // `viewport`, preserving 1:1 vertical aspect ratio with zero stretch.
            let visibleHeight = viewport.height * (1 - slitFraction)
            var uniforms = SIMD4<Float>(
                Float(viewport.minX / displaySize.width),
                Float(viewport.minY / displaySize.height),
                Float(viewport.width / displaySize.width),
                Float(visibleHeight / displaySize.height)
            )
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()

            commandBuffer.commit()
            // Required by CAMetalLayer.presentsWithTransaction so the Metal frame lands in the same
            // CATransaction as the cursor and ink layers in this window.
            commandBuffer.waitUntilScheduled()
            drawable.present()

            if layer.isHidden { layer.isHidden = false }
            lastSequence = sequence
            lastViewport = viewport
            return
        }

        if let fallbackLayer {
            if cachedSurface !== resolvedSurface || lastSequence != sequence {
                cachedSurface = resolvedSurface
                fallbackLayer.contents = resolvedSurface
            }
            let visibleHeight = viewport.height * (1 - slitFraction)
            let bottomY = viewport.minY + visibleHeight
            // contentsRect uses a bottom-left origin.
            fallbackLayer.contentsRect = CGRect(
                x: viewport.minX / displaySize.width,
                y: 1 - bottomY / displaySize.height,
                width: viewport.width / displaySize.width,
                height: visibleHeight / displaySize.height
            )
            if fallbackLayer.isHidden { fallbackLayer.isHidden = false }
            lastSequence = sequence
            lastViewport = viewport
        }
    }

    private func texture(for surface: IOSurface, device: MTLDevice) -> MTLTexture? {
        let id = IOSurfaceGetID(surface)
        if cachedSurface === surface, cachedSurfaceID == id, let cachedTexture {
            return cachedTexture
        }
        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        guard width > 0, height > 0 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else {
            return nil
        }
        cachedSurface = surface
        cachedSurfaceID = id
        cachedTexture = texture
        return texture
    }

    // MARK: - Shared Metal Pipeline

    private struct MetalResources {
        let device: MTLDevice
        let commandQueue: MTLCommandQueue
        let pipelineState: MTLRenderPipelineState
        let samplerState: MTLSamplerState
    }

    private static var sharedMetal: MetalResources?
    private static var metalInitAttempted = false

    private static func makeMetalResources() -> MetalResources? {
        if metalInitAttempted { return sharedMetal }
        metalInitAttempted = true
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            log("Metal unavailable; using CALayer fallback for zoom surface")
            return nil
        }
        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            guard let vertexFn = library.makeFunction(name: "zoomVertex"),
                  let fragmentFn = library.makeFunction(name: "zoomFragmentBicubic") else {
                log("Metal shader functions missing; using CALayer fallback")
                return nil
            }
            let pipelineDesc = MTLRenderPipelineDescriptor()
            pipelineDesc.vertexFunction = vertexFn
            pipelineDesc.fragmentFunction = fragmentFn
            pipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
            let pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDesc)

            let samplerDesc = MTLSamplerDescriptor()
            samplerDesc.minFilter = .linear
            samplerDesc.magFilter = .linear
            samplerDesc.sAddressMode = .clampToEdge
            samplerDesc.tAddressMode = .clampToEdge
            guard let samplerState = device.makeSamplerState(descriptor: samplerDesc) else {
                return nil
            }

            let resources = MetalResources(
                device: device,
                commandQueue: commandQueue,
                pipelineState: pipelineState,
                samplerState: samplerState
            )
            sharedMetal = resources
            return resources
        } catch {
            log("Metal pipeline compilation failed: \(error.localizedDescription); using CALayer fallback")
            return nil
        }
    }

    /// Fullscreen triangle + exact 9-tap hardware-bilinear Catmull-Rom bicubic filter (equivalent to 16-tap
    /// Catmull-Rom with a = -0.5). Preserves razor-sharp Retina text while panning smoothly at sub-pixel precision.
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VertexOut zoomVertex(uint vid [[vertex_id]]) {
        VertexOut out;
        // Fullscreen triangle covering NDC [-1, 1] x [-1, 1]; UV (0, 0) at top-left, (1, 1) at bottom-right.
        float2 pos = float2((vid == 1) ? 3.0 : -1.0, (vid == 2) ? 3.0 : -1.0);
        float2 uv  = float2((vid == 1) ? 2.0 :  0.0, (vid == 2) ? -1.0 : 1.0);
        out.position = float4(pos, 0.0, 1.0);
        out.uv = uv;
        return out;
    }

    fragment float4 zoomFragmentBicubic(
        VertexOut in [[stage_in]],
        texture2d<float> tex [[texture(0)]],
        sampler linearSampler [[sampler(0)]],
        constant float4 &srcRect [[buffer(0)]]
    ) {
        float2 srcUV = srcRect.xy + in.uv * srcRect.zw;
        float2 texSize = float2(tex.get_width(), tex.get_height());
        float2 invTexSize = 1.0 / texSize;

        float2 samplePos = srcUV * texSize;
        float2 texPos1 = floor(samplePos - 0.5) + 0.5;
        float2 f = samplePos - texPos1;

        float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
        float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
        float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
        float2 w3 = f * f * (-0.5 + 0.5 * f);

        float2 w12 = w1 + w2;
        float2 offset12 = w2 / max(w12, float2(1e-5));

        float2 texPos0 = (texPos1 - 1.0) * invTexSize;
        float2 texPos3 = (texPos1 + 2.0) * invTexSize;
        float2 texPos12 = (texPos1 + offset12) * invTexSize;

        float3 result = 0.0;
        result += tex.sample(linearSampler, float2(texPos0.x,  texPos0.y)).rgb  * (w0.x  * w0.y);
        result += tex.sample(linearSampler, float2(texPos12.x, texPos0.y)).rgb  * (w12.x * w0.y);
        result += tex.sample(linearSampler, float2(texPos3.x,  texPos0.y)).rgb  * (w3.x  * w0.y);

        result += tex.sample(linearSampler, float2(texPos0.x,  texPos12.y)).rgb * (w0.x  * w12.y);
        result += tex.sample(linearSampler, float2(texPos12.x, texPos12.y)).rgb * (w12.x * w12.y);
        result += tex.sample(linearSampler, float2(texPos3.x,  texPos12.y)).rgb * (w3.x  * w12.y);

        result += tex.sample(linearSampler, float2(texPos0.x,  texPos3.y)).rgb  * (w0.x  * w3.y);
        result += tex.sample(linearSampler, float2(texPos12.x, texPos3.y)).rgb  * (w12.x * w3.y);
        result += tex.sample(linearSampler, float2(texPos3.x,  texPos3.y)).rgb  * (w3.x  * w3.y);

        return float4(clamp(result, 0.0, 1.0), 1.0);
    }
    """
}
