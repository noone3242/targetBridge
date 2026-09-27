import CoreVideo
import Metal

struct TBNV12PackedRuns {
    let buffer: MTLBuffer
    let length: Int
    let packingNanoseconds: UInt64
}

final class TBNV12TileDetector {
    static let tileSize = 64

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let packingPipeline: MTLComputePipelineState
    private var textureCache: CVMetalTextureCache?
    private var committedY: MTLTexture?
    private var committedUV: MTLTexture?
    private var candidateY: MTLTexture?
    private var candidateUV: MTLTexture?
    private var dirtyBuffer: MTLBuffer?
    private var runDescriptorBuffer: MTLBuffer?
    private var packedBuffer: MTLBuffer?
    private var runDescriptorCapacity = 0
    private var packedCapacity = 0
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

    struct NV12RunDescriptor {
        ushort tile_x;
        ushort tile_y;
        ushort tile_count_x;
        ushort pixel_height;
        uint data_offset;
        uint data_length;
    };

    kernel void nv12_pack_runs(
        texture2d<float, access::read> current_y [[texture(0)]],
        texture2d<float, access::read> current_uv [[texture(1)]],
        device const NV12RunDescriptor *runs [[buffer(0)]],
        device uchar *packed [[buffer(1)]],
        uint thread_index [[thread_index_in_threadgroup]],
        uint run_index [[threadgroup_position_in_grid]]
    ) {
        constexpr uint tile_size = 64u;
        constexpr uint threads_per_run = 64u;
        NV12RunDescriptor run = runs[run_index];
        uint origin_x = uint(run.tile_x) * tile_size;
        uint origin_y = uint(run.tile_y) * tile_size;
        uint pixel_width = uint(run.tile_count_x) * tile_size;
        uint pixel_height = uint(run.pixel_height);
        uint y_pixels = pixel_width * pixel_height;
        for (uint index = thread_index; index < y_pixels;
             index += threads_per_run) {
            uint x = origin_x + index % pixel_width;
            uint y = origin_y + index / pixel_width;
            packed[run.data_offset + index] = uchar(clamp(
                round(current_y.read(uint2(x, y)).r * 255.0f),
                0.0f,
                255.0f
            ));
        }

        uint uv_width = pixel_width / 2u;
        uint uv_height = pixel_height / 2u;
        uint uv_texels = uv_width * uv_height;
        uint uv_offset = run.data_offset + y_pixels;
        for (uint index = thread_index; index < uv_texels;
             index += threads_per_run) {
            uint x = origin_x / 2u + index % uv_width;
            uint y = origin_y / 2u + index / uv_width;
            float2 value = current_uv.read(uint2(x, y)).rg;
            packed[uv_offset + index * 2u] = uchar(clamp(
                round(value.x * 255.0f), 0.0f, 255.0f
            ));
            packed[uv_offset + index * 2u + 1u] = uchar(clamp(
                round(value.y * 255.0f), 0.0f, 255.0f
            ));
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
            guard let function = library.makeFunction(name: "nv12_tile_compare"),
                  let packingFunction =
                    library.makeFunction(name: "nv12_pack_runs")
            else {
                return nil
            }
            pipeline = try device.makeComputePipelineState(function: function)
            packingPipeline = try device.makeComputePipelineState(
                function: packingFunction
            )
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

    func pack(
        pixelBuffer: CVPixelBuffer,
        runs: [TBNV12Compression.TileRun]
    ) -> TBNV12PackedRuns? {
        guard !runs.isEmpty,
              CVPixelBufferGetPlaneCount(pixelBuffer) >= 2,
              let textureCache
        else {
            return nil
        }
        let lumaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let lumaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let uvWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let uvHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
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

        let packedLength = runs.reduce(0) { $0 + $1.dataLength }
        let descriptorLength =
            runs.count * MemoryLayout<MetalRunDescriptor>.stride
        if runDescriptorBuffer == nil ||
            runDescriptorCapacity < descriptorLength {
            runDescriptorBuffer = device.makeBuffer(
                length: descriptorLength,
                options: .storageModeShared
            )
            runDescriptorCapacity = descriptorLength
        }
        if packedBuffer == nil || packedCapacity < packedLength {
            packedBuffer = device.makeBuffer(
                length: packedLength,
                options: .storageModeShared
            )
            packedCapacity = packedLength
        }
        guard let runDescriptorBuffer,
              let packedBuffer,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            return nil
        }
        let descriptors = runDescriptorBuffer.contents()
            .assumingMemoryBound(to: MetalRunDescriptor.self)
        for (index, run) in runs.enumerated() {
            descriptors[index] = MetalRunDescriptor(
                tileX: UInt16(run.tileX),
                tileY: UInt16(run.tileY),
                tileCountX: UInt16(run.tileCountX),
                pixelHeight: UInt16(run.pixelHeight),
                dataOffset: UInt32(run.dataOffset),
                dataLength: UInt32(run.dataLength)
            )
        }

        let started = DispatchTime.now().uptimeNanoseconds
        encoder.setComputePipelineState(packingPipeline)
        encoder.setTexture(sourceY, index: 0)
        encoder.setTexture(sourceUV, index: 1)
        encoder.setBuffer(runDescriptorBuffer, offset: 0, index: 0)
        encoder.setBuffer(packedBuffer, offset: 0, index: 1)
        encoder.dispatchThreadgroups(
            MTLSize(width: runs.count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            if let error = commandBuffer.error {
                NSLog(
                    "TargetBridge: NV12 tile packing failed: %@",
                    error.localizedDescription
                )
            }
            return nil
        }
        return TBNV12PackedRuns(
            buffer: packedBuffer,
            length: packedLength,
            packingNanoseconds:
                DispatchTime.now().uptimeNanoseconds - started
        )
    }

    func discardCandidate() {
        hasStagedCandidate = false
    }

    private struct MetalRunDescriptor {
        var tileX: UInt16
        var tileY: UInt16
        var tileCountX: UInt16
        var pixelHeight: UInt16
        var dataOffset: UInt32
        var dataLength: UInt32
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
