import CoreVideo
import Metal

final class TBNV12TileDetector {
    static let tileSize = 64

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private var textureCache: CVMetalTextureCache?
    private var committedY: MTLTexture?
    private var committedUV: MTLTexture?
    private var candidateY: MTLTexture?
    private var candidateUV: MTLTexture?
    private var dirtyBuffer: MTLBuffer?
    private var width = 0
    private var height = 0
    private var tileCount = 0
    private(set) var hasBaseline = false
    private var hasStagedCandidate = false

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void nv12_tile_compare(
        texture2d<float, access::read> current_y [[texture(0)]],
        texture2d<float, access::read> current_uv [[texture(1)]],
        texture2d<float, access::read> baseline_y [[texture(2)]],
        texture2d<float, access::read> baseline_uv [[texture(3)]],
        device uint *dirty_flags [[buffer(0)]],
        constant uint2 &luma_size [[buffer(1)]],
        uint thread_index [[thread_index_in_threadgroup]],
        uint2 tile_position [[threadgroup_position_in_grid]]
    ) {
        constexpr uint tile_size = 64u;
        constexpr uint threads_per_tile = 64u;
        threadgroup atomic_uint changed;
        if (thread_index == 0u) {
            atomic_store_explicit(&changed, 0u, memory_order_relaxed);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        uint origin_x = tile_position.x * tile_size;
        uint origin_y = tile_position.y * tile_size;
        uint tile_width = min(tile_size, luma_size.x - origin_x);
        uint tile_height = min(tile_size, luma_size.y - origin_y);
        uint luma_pixels = tile_width * tile_height;
        for (uint index = thread_index; index < luma_pixels;
             index += threads_per_tile) {
            uint x = origin_x + index % tile_width;
            uint y = origin_y + index / tile_width;
            if (current_y.read(uint2(x, y)).r !=
                baseline_y.read(uint2(x, y)).r) {
                atomic_store_explicit(&changed, 1u, memory_order_relaxed);
            }
        }

        uint uv_origin_x = origin_x / 2u;
        uint uv_origin_y = origin_y / 2u;
        uint uv_width = tile_width / 2u;
        uint uv_height = tile_height / 2u;
        uint uv_pixels = uv_width * uv_height;
        for (uint index = thread_index; index < uv_pixels;
             index += threads_per_tile) {
            uint x = uv_origin_x + index % uv_width;
            uint y = uv_origin_y + index / uv_width;
            if (any(current_uv.read(uint2(x, y)).rg !=
                    baseline_uv.read(uint2(x, y)).rg)) {
                atomic_store_explicit(&changed, 1u, memory_order_relaxed);
            }
        }

        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (thread_index == 0u) {
            uint tiles_wide = (luma_size.x + tile_size - 1u) / tile_size;
            uint tile_index = tile_position.y * tiles_wide + tile_position.x;
            dirty_flags[tile_index] =
                atomic_load_explicit(&changed, memory_order_relaxed);
        }
    }
    """

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue()
        else {
            return nil
        }
        do {
            let library = try device.makeLibrary(source: Self.source, options: nil)
            guard let function = library.makeFunction(name: "nv12_tile_compare")
            else {
                return nil
            }
            pipeline = try device.makeComputePipelineState(function: function)
        } catch {
            NSLog(
                "TargetBridge: unable to compile NV12 tile detector: %@",
                error.localizedDescription
            )
            return nil
        }
        self.device = device
        self.commandQueue = commandQueue
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(
            kCFAllocatorDefault, nil, device, nil, &cache
        ) == kCVReturnSuccess else {
            return nil
        }
        textureCache = cache
    }

    func analyze(pixelBuffer: CVPixelBuffer) -> Set<Int>? {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2,
              let textureCache
        else {
            return nil
        }
        let lumaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let lumaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let uvWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let uvHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        guard lumaWidth > 0, lumaHeight > 0,
              lumaWidth % Self.tileSize == 0,
              lumaHeight % Self.tileSize == 0,
              uvWidth * 2 == lumaWidth,
              uvHeight * 2 == lumaHeight
        else {
            return nil
        }

        var yReference: CVMetalTexture?
        var uvReference: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .r8Unorm, lumaWidth, lumaHeight, 0, &yReference
        ) == kCVReturnSuccess,
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .rg8Unorm, uvWidth, uvHeight, 1, &uvReference
        ) == kCVReturnSuccess,
        let yReference,
        let uvReference,
        let sourceY = CVMetalTextureGetTexture(yReference),
        let sourceUV = CVMetalTextureGetTexture(uvReference)
        else {
            return nil
        }

        if width != lumaWidth || height != lumaHeight ||
            committedY == nil || committedUV == nil ||
            candidateY == nil || candidateUV == nil {
            guard allocateTextures(
                lumaWidth: lumaWidth,
                lumaHeight: lumaHeight,
                uvWidth: uvWidth,
                uvHeight: uvHeight
            ) else {
                return nil
            }
        }
        guard let candidateY,
              let candidateUV,
              let dirtyBuffer,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            return nil
        }

        let tilesWide = lumaWidth / Self.tileSize
        let tilesHigh = lumaHeight / Self.tileSize
        if hasBaseline {
            guard let committedY,
                  let committedUV,
                  let encoder = commandBuffer.makeComputeCommandEncoder()
            else {
                return nil
            }
            memset(dirtyBuffer.contents(), 0, dirtyBuffer.length)
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(sourceY, index: 0)
            encoder.setTexture(sourceUV, index: 1)
            encoder.setTexture(committedY, index: 2)
            encoder.setTexture(committedUV, index: 3)
            encoder.setBuffer(dirtyBuffer, offset: 0, index: 0)
            var lumaSize = SIMD2<UInt32>(
                UInt32(lumaWidth), UInt32(lumaHeight)
            )
            encoder.setBytes(
                &lumaSize,
                length: MemoryLayout<SIMD2<UInt32>>.stride,
                index: 1
            )
            encoder.dispatchThreadgroups(
                MTLSize(width: tilesWide, height: tilesHigh, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1)
            )
            encoder.endEncoding()
        } else {
            let flags = dirtyBuffer.contents().assumingMemoryBound(to: UInt32.self)
            for index in 0..<tileCount {
                flags[index] = 1
            }
        }

        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            return nil
        }
        blit.copy(
            from: sourceY,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: lumaWidth, height: lumaHeight, depth: 1),
            to: candidateY,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.copy(
            from: sourceUV,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: uvWidth, height: uvHeight, depth: 1),
            to: candidateUV,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            if let error = commandBuffer.error {
                NSLog(
                    "TargetBridge: NV12 tile detection failed: %@",
                    error.localizedDescription
                )
            }
            return nil
        }
        hasStagedCandidate = true
        let flags = dirtyBuffer.contents().assumingMemoryBound(to: UInt32.self)
        return Set((0..<tileCount).filter { flags[$0] != 0 })
    }

    func commitCandidate() {
        guard hasStagedCandidate else { return }
        swap(&committedY, &candidateY)
        swap(&committedUV, &candidateUV)
        hasBaseline = true
        hasStagedCandidate = false
    }

    func discardCandidate() {
        hasStagedCandidate = false
    }

    func reset() {
        hasBaseline = false
        hasStagedCandidate = false
    }

    private func allocateTextures(
        lumaWidth: Int,
        lumaHeight: Int,
        uvWidth: Int,
        uvHeight: Int
    ) -> Bool {
        func makeTexture(
            format: MTLPixelFormat,
            width: Int,
            height: Int
        ) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead]
            return device.makeTexture(descriptor: descriptor)
        }

        let tilesWide = lumaWidth / Self.tileSize
        let tilesHigh = lumaHeight / Self.tileSize
        let count = tilesWide * tilesHigh
        guard let committedY = makeTexture(
                  format: .r8Unorm, width: lumaWidth, height: lumaHeight
              ),
              let committedUV = makeTexture(
                  format: .rg8Unorm, width: uvWidth, height: uvHeight
              ),
              let candidateY = makeTexture(
                  format: .r8Unorm, width: lumaWidth, height: lumaHeight
              ),
              let candidateUV = makeTexture(
                  format: .rg8Unorm, width: uvWidth, height: uvHeight
              ),
              let dirtyBuffer = device.makeBuffer(
                  length: count * MemoryLayout<UInt32>.stride,
                  options: .storageModeShared
              )
        else {
            return false
        }
        self.committedY = committedY
        self.committedUV = committedUV
        self.candidateY = candidateY
        self.candidateUV = candidateUV
        self.dirtyBuffer = dirtyBuffer
        width = lumaWidth
        height = lumaHeight
        tileCount = count
        hasBaseline = false
        hasStagedCandidate = false
        memset(dirtyBuffer.contents(), 0, dirtyBuffer.length)
        return true
    }
}
