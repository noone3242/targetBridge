import CoreVideo
import Metal

final class TBNV12TileDetector {
    static let tileSize = 64

    /// A shift that reproduces `tiles` of the current frame from the committed
    /// baseline: current(x, y) == baseline(x - dx, y - dy) for every Y and UV
    /// sample of each tile, with the whole source rectangle inside the frame.
    struct CopyRect: Equatable {
        let dx: Int
        let dy: Int
        let tiles: Set<Int>
    }

    /// Copy-rect search tuning. Offsets are even so UV shifts exactly.
    enum CopyRectSearch {
        static let maxAnchors = 64
        static let matchesPerAnchor = 8
        static let minimumVotes = 2
        /// Drags: any offset within this box.
        static let dragRadius = 192
        /// Scrolls: purely vertical / horizontal offsets up to these.
        static let verticalScrollRange = 1440
        static let horizontalScrollRange = 1024
        /// Sample-to-sample luma changes an anchor needs among its 64 samples
        /// so flat tiles, which match almost any offset, are skipped.
        static let minimumAnchorTransitions: UInt32 = 8
        /// Predictions (the last vector, the pointer's move): any offset
        /// within this box around each, so fast diagonal drags beyond
        /// `dragRadius` are still found.
        static let predictionRadius = 64
        static let maxPredictions = 2
        static let predictionCapacity =
            maxPredictions * (predictionRadius + 1) * (predictionRadius + 1)

        /// Whether `offsets()` contains (`dx`, `dy`).
        static func isBaseOffset(dx: Int, dy: Int) -> Bool {
            guard dx % 2 == 0, dy % 2 == 0, dx != 0 || dy != 0 else {
                return false
            }
            if abs(dx) <= dragRadius, abs(dy) <= dragRadius { return true }
            if dx == 0 { return abs(dy) <= verticalScrollRange }
            if dy == 0 { return abs(dx) <= horizontalScrollRange }
            return false
        }

        /// Even offsets around each prediction that `offsets()` lacks, each
        /// once, so no anchor sees the same vector twice.
        static func predictedOffsets(
            around predictions: [SIMD2<Int>]
        ) -> [SIMD2<Int32>] {
            var seen = Set<SIMD2<Int>>()
            var result: [SIMD2<Int32>] = []
            for prediction in predictions.prefix(maxPredictions) {
                // Round down to even, so the box stays on the even grid.
                let centre = SIMD2(prediction.x & ~1, prediction.y & ~1)
                for dy in stride(
                    from: centre.y - predictionRadius,
                    through: centre.y + predictionRadius, by: 2
                ) {
                    for dx in stride(
                        from: centre.x - predictionRadius,
                        through: centre.x + predictionRadius, by: 2
                    )
                    where (dx != 0 || dy != 0) &&
                        !isBaseOffset(dx: dx, dy: dy) &&
                        seen.insert(SIMD2(dx, dy)).inserted {
                        result.append(SIMD2(Int32(dx), Int32(dy)))
                    }
                }
            }
            return result
        }

        static func offsets() -> [SIMD2<Int32>] {
            var offsets: [SIMD2<Int32>] = []
            for dy in stride(from: -dragRadius, through: dragRadius, by: 2) {
                for dx in stride(from: -dragRadius, through: dragRadius, by: 2)
                where dx != 0 || dy != 0 {
                    offsets.append(SIMD2(Int32(dx), Int32(dy)))
                }
            }
            for dy in stride(from: dragRadius + 2, through: verticalScrollRange, by: 2) {
                offsets.append(SIMD2(0, Int32(dy)))
                offsets.append(SIMD2(0, Int32(-dy)))
            }
            for dx in stride(from: dragRadius + 2, through: horizontalScrollRange, by: 2) {
                offsets.append(SIMD2(Int32(dx), 0))
                offsets.append(SIMD2(Int32(-dx), 0))
            }
            return offsets
        }
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let anchorPipeline: MTLComputePipelineState
    private let searchPipeline: MTLComputePipelineState
    private let verifyPipeline: MTLComputePipelineState
    private let offsetCount: Int
    private let offsetBuffer: MTLBuffer
    private let anchorBuffer: MTLBuffer
    private let anchorValidBuffer: MTLBuffer
    private let matchCountBuffer: MTLBuffer
    private let matchBuffer: MTLBuffer
    private var verifyTileBuffer: MTLBuffer?
    private var verifyFlagBuffer: MTLBuffer?
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

    // 64 luma samples spread over a 64x64 tile on a staggered 8x8 grid, so
    // both horizontal and vertical structure is caught.
    static inline uint2 anchor_sample(uint index) {
        uint i = index & 7u;
        uint j = index >> 3u;
        return uint2(i * 8u + ((j * 3u) & 7u), j * 8u + ((i * 5u) & 7u));
    }

    kernel void nv12_anchor_texture(
        texture2d<float, access::read> current_y [[texture(0)]],
        device const uint2 *anchors [[buffer(0)]],
        device uint *anchor_valid [[buffer(1)]],
        constant uint4 &params [[buffer(2)]],
        uint anchor [[thread_position_in_grid]]
    ) {
        // params: offset count, anchor count, min transitions, unused.
        if (anchor >= params.y) {
            return;
        }
        uint2 origin = anchors[anchor];
        float previous = current_y.read(origin + anchor_sample(0u)).r;
        uint transitions = 0u;
        for (uint index = 1u; index < 64u; index++) {
            float value = current_y.read(origin + anchor_sample(index)).r;
            transitions += value != previous ? 1u : 0u;
            previous = value;
        }
        anchor_valid[anchor] = transitions >= params.z ? 1u : 0u;
    }

    kernel void nv12_shift_search(
        texture2d<float, access::read> current_y [[texture(0)]],
        texture2d<float, access::read> baseline_y [[texture(1)]],
        device const uint2 *anchors [[buffer(0)]],
        device const uint *anchor_valid [[buffer(1)]],
        device const int2 *offsets [[buffer(2)]],
        device atomic_uint *match_counts [[buffer(3)]],
        device uint *matches [[buffer(4)]],
        constant uint4 &params [[buffer(5)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        constexpr uint matches_per_anchor = 8u;
        if (gid.x >= params.x || gid.y >= params.y ||
            anchor_valid[gid.y] == 0u) {
            return;
        }
        int2 origin = int2(anchors[gid.y]);
        int2 source = origin - offsets[gid.x];
        int2 size = int2(current_y.get_width(), current_y.get_height());
        if (source.x < 0 || source.y < 0 ||
            source.x + 64 > size.x || source.y + 64 > size.y) {
            return;
        }
        for (uint index = 0u; index < 64u; index++) {
            int2 sample = int2(anchor_sample(index));
            if (current_y.read(uint2(origin + sample)).r !=
                baseline_y.read(uint2(source + sample)).r) {
                return;
            }
        }
        uint slot = atomic_fetch_add_explicit(
            &match_counts[gid.y], 1u, memory_order_relaxed
        );
        if (slot < matches_per_anchor) {
            matches[gid.y * matches_per_anchor + slot] = gid.x;
        }
    }

    // One threadgroup per listed tile: does the whole tile equal the
    // baseline shifted by `shift` (luma pixels, even)?
    kernel void nv12_tile_shift_compare(
        texture2d<float, access::read> current_y [[texture(0)]],
        texture2d<float, access::read> current_uv [[texture(1)]],
        texture2d<float, access::read> baseline_y [[texture(2)]],
        texture2d<float, access::read> baseline_uv [[texture(3)]],
        device const uint *tiles [[buffer(0)]],
        device uint *match_flags [[buffer(1)]],
        constant int4 &params [[buffer(2)]],
        uint thread_index [[thread_index_in_threadgroup]],
        uint group [[threadgroup_position_in_grid]]
    ) {
        constexpr int tile_size = 64;
        // params: dx, dy, tiles wide, tile count.
        threadgroup atomic_uint mismatch;
        if (thread_index == 0u) {
            atomic_store_explicit(&mismatch, 0u, memory_order_relaxed);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (int(group) >= params.w) {
            return;
        }
        uint tile = tiles[group];
        int2 origin = int2(int(tile % uint(params.z)), int(tile / uint(params.z))) *
            tile_size;
        int2 shift = params.xy;
        int2 source = origin - shift;
        int2 size = int2(current_y.get_width(), current_y.get_height());
        bool inside = source.x >= 0 && source.y >= 0 &&
            source.x + tile_size <= size.x && source.y + tile_size <= size.y;
        if (inside) {
            int x = int(thread_index);
            for (int row = 0; row < tile_size; row++) {
                if ((row & 7) == 0 &&
                    atomic_load_explicit(&mismatch, memory_order_relaxed) != 0u) {
                    break;
                }
                if (current_y.read(uint2(origin.x + x, origin.y + row)).r !=
                    baseline_y.read(uint2(source.x + x, source.y + row)).r) {
                    atomic_store_explicit(&mismatch, 1u, memory_order_relaxed);
                    break;
                }
            }
            // 32x32 UV samples: each thread covers half a row.
            int2 uv_origin = origin / 2;
            int2 uv_source = source / 2;
            int uv_x = x & 31;
            for (int row = x >> 5; row < tile_size / 2; row += 2) {
                if ((row & 7) < 2 &&
                    atomic_load_explicit(&mismatch, memory_order_relaxed) != 0u) {
                    break;
                }
                if (any(current_uv.read(uint2(uv_origin.x + uv_x, uv_origin.y + row)).rg !=
                        baseline_uv.read(uint2(uv_source.x + uv_x, uv_source.y + row)).rg)) {
                    atomic_store_explicit(&mismatch, 1u, memory_order_relaxed);
                    break;
                }
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (thread_index == 0u) {
            match_flags[group] = inside &&
                atomic_load_explicit(&mismatch, memory_order_relaxed) == 0u
                ? 1u : 0u;
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
                  let anchorFunction = library.makeFunction(
                      name: "nv12_anchor_texture"
                  ),
                  let searchFunction = library.makeFunction(
                      name: "nv12_shift_search"
                  ),
                  let verifyFunction = library.makeFunction(
                      name: "nv12_tile_shift_compare"
                  )
            else {
                return nil
            }
            pipeline = try device.makeComputePipelineState(function: function)
            anchorPipeline = try device.makeComputePipelineState(
                function: anchorFunction
            )
            searchPipeline = try device.makeComputePipelineState(
                function: searchFunction
            )
            verifyPipeline = try device.makeComputePipelineState(
                function: verifyFunction
            )
        } catch {
            NSLog(
                "TargetBridge: unable to compile NV12 tile detector: %@",
                error.localizedDescription
            )
            return nil
        }
        let offsets = CopyRectSearch.offsets()
        let maxAnchors = CopyRectSearch.maxAnchors
        // The fixed offsets, then room for the per-frame predicted ones.
        guard let offsetBuffer = device.makeBuffer(
                  length: (offsets.count + CopyRectSearch.predictionCapacity) *
                      MemoryLayout<SIMD2<Int32>>.stride,
                  options: .storageModeShared
              ),
              let anchorBuffer = device.makeBuffer(
                  length: maxAnchors * MemoryLayout<SIMD2<UInt32>>.stride,
                  options: .storageModeShared
              ),
              let anchorValidBuffer = device.makeBuffer(
                  length: maxAnchors * MemoryLayout<UInt32>.stride,
                  options: .storageModeShared
              ),
              let matchCountBuffer = device.makeBuffer(
                  length: maxAnchors * MemoryLayout<UInt32>.stride,
                  options: .storageModeShared
              ),
              let matchBuffer = device.makeBuffer(
                  length: maxAnchors * CopyRectSearch.matchesPerAnchor *
                      MemoryLayout<UInt32>.stride,
                  options: .storageModeShared
              )
        else {
            return nil
        }
        offsets.withUnsafeBytes {
            offsetBuffer.contents().copyMemory(
                from: $0.baseAddress!, byteCount: $0.count
            )
        }
        offsetCount = offsets.count
        self.offsetBuffer = offsetBuffer
        self.anchorBuffer = anchorBuffer
        self.anchorValidBuffer = anchorValidBuffer
        self.matchCountBuffer = matchCountBuffer
        self.matchBuffer = matchBuffer
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

    /// Looks for one shift that reproduces many of `dirtyTiles` from the
    /// committed baseline. Call right after `analyze` returned `dirtyTiles`
    /// against a baseline, before committing or discarding the candidate.
    /// `preferred` breaks ties, so a steady drag keeps its vector.
    func findCopyRect(
        dirtyTiles: Set<Int>,
        preferred: SIMD2<Int>? = nil,
        predictions: [SIMD2<Int>] = [],
        minimumTiles: Int = 16
    ) -> CopyRect? {
        guard let shift = searchShift(
            dirtyTiles: dirtyTiles, preferred: preferred,
            predictions: predictions
        ),
        let tiles = verifyShift(
            dx: shift.x, dy: shift.y, tiles: dirtyTiles
        ),
        tiles.count >= minimumTiles
        else {
            return nil
        }
        return CopyRect(dx: shift.x, dy: shift.y, tiles: tiles)
    }

    /// Votes over sparse matches of up to `maxAnchors` textured dirty tiles
    /// against every candidate offset, plus a box around each prediction.
    /// Only a hint: `verifyShift` decides.
    func searchShift(
        dirtyTiles: Set<Int>,
        preferred: SIMD2<Int>? = nil,
        predictions: [SIMD2<Int>] = []
    ) -> SIMD2<Int>? {
        guard hasStagedCandidate, hasBaseline,
              let candidateY, let committedY,
              !dirtyTiles.isEmpty,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            return nil
        }
        let tilesWide = width / Self.tileSize
        let sorted = dirtyTiles.sorted()
        let anchorCount = min(CopyRectSearch.maxAnchors, sorted.count)
        let anchors = anchorBuffer.contents()
            .assumingMemoryBound(to: SIMD2<UInt32>.self)
        for index in 0..<anchorCount {
            // Evenly spaced over the dirty set, centred in each stride.
            let tile = sorted[
                (2 * index + 1) * sorted.count / (2 * anchorCount)
            ]
            anchors[index] = SIMD2(
                UInt32(tile % tilesWide * Self.tileSize),
                UInt32(tile / tilesWide * Self.tileSize)
            )
        }
        let predicted = CopyRectSearch.predictedOffsets(around: predictions)
        predicted.withUnsafeBytes {
            guard let base = $0.baseAddress else { return }
            offsetBuffer.contents()
                .advanced(by: offsetCount * MemoryLayout<SIMD2<Int32>>.stride)
                .copyMemory(from: base, byteCount: $0.count)
        }
        let searchCount = offsetCount + predicted.count
        memset(matchCountBuffer.contents(), 0, matchCountBuffer.length)
        var params = SIMD4<UInt32>(
            UInt32(searchCount),
            UInt32(anchorCount),
            CopyRectSearch.minimumAnchorTransitions,
            0
        )
        encoder.setComputePipelineState(anchorPipeline)
        encoder.setTexture(candidateY, index: 0)
        encoder.setBuffer(anchorBuffer, offset: 0, index: 0)
        encoder.setBuffer(anchorValidBuffer, offset: 0, index: 1)
        encoder.setBytes(
            &params, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 2
        )
        encoder.dispatchThreads(
            MTLSize(width: anchorCount, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: min(anchorCount, 64), height: 1, depth: 1
            )
        )
        encoder.setComputePipelineState(searchPipeline)
        encoder.setTexture(candidateY, index: 0)
        encoder.setTexture(committedY, index: 1)
        encoder.setBuffer(anchorBuffer, offset: 0, index: 0)
        encoder.setBuffer(anchorValidBuffer, offset: 0, index: 1)
        encoder.setBuffer(offsetBuffer, offset: 0, index: 2)
        encoder.setBuffer(matchCountBuffer, offset: 0, index: 3)
        encoder.setBuffer(matchBuffer, offset: 0, index: 4)
        encoder.setBytes(
            &params, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 5
        )
        encoder.dispatchThreads(
            MTLSize(width: searchCount, height: anchorCount, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: min(256, searchPipeline.maxTotalThreadsPerThreadgroup),
                height: 1, depth: 1
            )
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }

        let counts = matchCountBuffer.contents()
            .assumingMemoryBound(to: UInt32.self)
        let matches = matchBuffer.contents()
            .assumingMemoryBound(to: UInt32.self)
        let offsets = offsetBuffer.contents()
            .assumingMemoryBound(to: SIMD2<Int32>.self)
        let perAnchor = CopyRectSearch.matchesPerAnchor
        var votes: [Int: Int] = [:]
        for anchor in 0..<anchorCount {
            let count = Int(counts[anchor])
            // Repetitive content matches too many offsets to be evidence.
            guard count > 0, count <= perAnchor else { continue }
            for slot in 0..<count {
                votes[Int(matches[anchor * perAnchor + slot]), default: 0] += 1
            }
        }
        func vector(_ index: Int) -> SIMD2<Int> {
            SIMD2(Int(offsets[index].x), Int(offsets[index].y))
        }
        let best = votes.max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            let lhsVector = vector(lhs.key)
            let rhsVector = vector(rhs.key)
            if let preferred, (lhsVector == preferred) != (rhsVector == preferred) {
                return rhsVector == preferred
            }
            let lhsLength = abs(lhsVector.x) + abs(lhsVector.y)
            let rhsLength = abs(rhsVector.x) + abs(rhsVector.y)
            if lhsLength != rhsLength { return lhsLength > rhsLength }
            return lhs.key > rhs.key
        }
        guard let best, best.value >= CopyRectSearch.minimumVotes else {
            return nil
        }
        return vector(best.key)
    }

    /// Exactly compares each of `tiles` with the committed baseline shifted
    /// by (`dx`, `dy`). Returns the tiles that match, or nil on GPU failure.
    func verifyShift(dx: Int, dy: Int, tiles: Set<Int>) -> Set<Int>? {
        guard hasStagedCandidate, hasBaseline,
              dx % 2 == 0, dy % 2 == 0,
              let candidateY, let candidateUV,
              let committedY, let committedUV,
              let verifyTileBuffer, let verifyFlagBuffer,
              !tiles.isEmpty, tiles.count <= tileCount,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            return nil
        }
        let list = verifyTileBuffer.contents()
            .assumingMemoryBound(to: UInt32.self)
        var count = 0
        for tile in tiles {
            guard tile >= 0, tile < tileCount else { return nil }
            list[count] = UInt32(tile)
            count += 1
        }
        var params = SIMD4<Int32>(
            Int32(dx), Int32(dy),
            Int32(width / Self.tileSize), Int32(count)
        )
        encoder.setComputePipelineState(verifyPipeline)
        encoder.setTexture(candidateY, index: 0)
        encoder.setTexture(candidateUV, index: 1)
        encoder.setTexture(committedY, index: 2)
        encoder.setTexture(committedUV, index: 3)
        encoder.setBuffer(verifyTileBuffer, offset: 0, index: 0)
        encoder.setBuffer(verifyFlagBuffer, offset: 0, index: 1)
        encoder.setBytes(
            &params, length: MemoryLayout<SIMD4<Int32>>.stride, index: 2
        )
        encoder.dispatchThreadgroups(
            MTLSize(width: count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }
        let flags = verifyFlagBuffer.contents()
            .assumingMemoryBound(to: UInt32.self)
        var matched = Set<Int>()
        for index in 0..<count where flags[index] != 0 {
            matched.insert(Int(list[index]))
        }
        return matched
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
              ),
              let verifyTileBuffer = device.makeBuffer(
                  length: count * MemoryLayout<UInt32>.stride,
                  options: .storageModeShared
              ),
              let verifyFlagBuffer = device.makeBuffer(
                  length: count * MemoryLayout<UInt32>.stride,
                  options: .storageModeShared
              )
        else {
            return false
        }
        self.verifyTileBuffer = verifyTileBuffer
        self.verifyFlagBuffer = verifyFlagBuffer
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

/// Skips copy-rect searches while busy content keeps missing (video,
/// animation, full redraws), so mostly scrolls and drags pay for the GPU
/// search. Skips count only frames large enough to search; a quiet frame,
/// or a pause in such frames (capture sends nothing while the screen is
/// idle), ends the busy stretch, so a scroll that follows searches at once.
struct TBNV12CopyRectBackoff {
    static let missesBeforeSkipping = 2
    static let initialSkip = 4
    static let maxSkip = 8
    static let idleResetNanoseconds: UInt64 = 100_000_000

    private(set) var consecutiveMisses = 0
    private var skipLength = 0
    private var remainingSkips = 0
    private var lastFrameAt: UInt64?

    /// Whether a frame large enough to search should run the search; a
    /// skipped frame counts down the current backoff. While the pointer
    /// moves, a window may be dragging, so every frame still searches.
    mutating func shouldSearch(
        at nanoseconds: UInt64,
        pointerMoving: Bool = false
    ) -> Bool {
        if let lastFrameAt,
           nanoseconds &- lastFrameAt > Self.idleResetNanoseconds {
            reset()
        }
        lastFrameAt = nanoseconds
        guard remainingSkips == 0 else {
            remainingSkips -= 1
            return pointerMoving
        }
        return true
    }

    /// After `missesBeforeSkipping` misses in a row, skips the next
    /// `initialSkip` frames, doubling up to `maxSkip` while probes keep
    /// missing.
    mutating func recordMiss() {
        consecutiveMisses += 1
        guard consecutiveMisses >= Self.missesBeforeSkipping else { return }
        skipLength = skipLength == 0
            ? Self.initialSkip
            : min(skipLength * 2, Self.maxSkip)
        remainingSkips = skipLength
    }

    /// A hit or a quiet frame.
    mutating func reset() {
        consecutiveMisses = 0
        skipLength = 0
        remainingSkips = 0
    }
}

/// Where the tiles of frames eligible for copy-rect went, cumulative, so a
/// capture shows which part of a drag or scroll still costs bandwidth.
struct TBNV12CopyRectStats: Equatable {
    /// Frames sent as tile runs: the backoff skipped the search, or the
    /// search found nothing usable (no vector, too little copied, too many
    /// fresh runs, no free writer slot).
    var skippedTiles = 0
    var missedTiles = 0
    /// Copy-rect frames: fresh tiles next to a copied tile (a moved edge or
    /// its shadow, only partly new), and fresh tiles elsewhere.
    var edgeTiles = 0
    var freshAreaTiles = 0
    /// Searches that found no vector, or one that copied too little.
    var noVectorFrames = 0
    var lowCoverageFrames = 0
    /// Misses while the pointer moved further than `dragRadius` in a frame.
    var fastPointerMisses = 0
    /// Vectors sent: within 64 pixels, within the drag box, on a scroll
    /// axis, or found only around a prediction.
    var nearVectors = 0
    var dragVectors = 0
    var scrollVectors = 0
    var predictedVectors = 0

    mutating func recordHit(
        dx: Int, dy: Int,
        copyTiles: Set<Int>, freshTiles: Set<Int>,
        tilesWide: Int, tilesHigh: Int
    ) {
        let edges = Self.edgeTileCount(
            freshTiles: freshTiles, copyTiles: copyTiles,
            tilesWide: tilesWide, tilesHigh: tilesHigh
        )
        edgeTiles += edges
        freshAreaTiles += freshTiles.count - edges
        let search = TBNV12TileDetector.CopyRectSearch.self
        let reach = max(abs(dx), abs(dy))
        if !search.isBaseOffset(dx: dx, dy: dy) {
            predictedVectors += 1
        } else if reach <= 64 {
            nearVectors += 1
        } else if reach <= search.dragRadius {
            dragVectors += 1
        } else {
            scrollVectors += 1
        }
    }

    /// Fresh tiles with a copied tile among their eight neighbours.
    static func edgeTileCount(
        freshTiles: Set<Int>, copyTiles: Set<Int>,
        tilesWide: Int, tilesHigh: Int
    ) -> Int {
        freshTiles.filter { tile in
            let x = tile % tilesWide
            let y = tile / tilesWide
            for ny in max(0, y - 1)...min(tilesHigh - 1, y + 1) {
                for nx in max(0, x - 1)...min(tilesWide - 1, x + 1)
                where copyTiles.contains(ny * tilesWide + nx) {
                    return true
                }
            }
            return false
        }.count
    }

    var metrics: [String: Int] {
        [
            "nv12CopyRectSkippedTiles": skippedTiles,
            "nv12CopyRectMissedTiles": missedTiles,
            "nv12CopyRectEdgeTiles": edgeTiles,
            "nv12CopyRectFreshAreaTiles": freshAreaTiles,
            "nv12CopyRectNoVectorFrames": noVectorFrames,
            "nv12CopyRectLowCoverageFrames": lowCoverageFrames,
            "nv12CopyRectFastPointerMisses": fastPointerMisses,
            "nv12CopyRectNearVectors": nearVectors,
            "nv12CopyRectDragVectors": dragVectors,
            "nv12CopyRectScrollVectors": scrollVectors,
            "nv12CopyRectPredictedVectors": predictedVectors,
        ]
    }
}
