import CoreVideo
import XCTest
@testable import TargetBridge

/// A tightly packed NV12 frame.
private struct NV12Frame: Equatable {
    let width: Int
    let height: Int
    var y: [UInt8]
    var uv: [UInt8]

    init(width: Int, height: Int, luma: UInt8 = 0x40, chroma: UInt8 = 0x80) {
        self.width = width
        self.height = height
        y = Array(repeating: luma, count: width * height)
        uv = Array(repeating: chroma, count: width * height / 2)
    }

    static func noise(width: Int, height: Int, seed: UInt32) -> NV12Frame {
        var frame = NV12Frame(width: width, height: height)
        var state = seed
        func next() -> UInt8 {
            state = state &* 1_664_525 &+ 1_013_904_223
            return UInt8(truncatingIfNeeded: state >> 24)
        }
        // Half noise, half gradient: textured everywhere, still compressible.
        for index in frame.y.indices {
            frame.y[index] = index % 2 == 0
                ? next() : UInt8(truncatingIfNeeded: index / 5)
        }
        for index in frame.uv.indices {
            frame.uv[index] = next()
        }
        return frame
    }

    /// Fills the luma-pixel rectangle with noise from `seed`.
    mutating func paintNoise(x: Int, y top: Int, width w: Int, height h: Int, seed: UInt32) {
        let source = NV12Frame.noise(width: width, height: height, seed: seed)
        copyRect(from: source, x: x, y: top, width: w, height: h, dx: 0, dy: 0)
    }

    /// Copies source(x - dx, y - dy) into self for the even-aligned rect.
    mutating func copyRect(
        from source: NV12Frame,
        x: Int, y top: Int, width w: Int, height h: Int,
        dx: Int, dy: Int
    ) {
        for row in top..<(top + h) {
            for column in x..<(x + w) {
                y[row * width + column] =
                    source.y[(row - dy) * width + column - dx]
            }
        }
        for row in (top / 2)..<((top + h) / 2) {
            for column in x..<(x + w) {
                uv[row * width + column] =
                    source.uv[(row - dy / 2) * width + column - dx]
            }
        }
    }

    func tileEquals(_ other: NV12Frame, tile: Int, dx: Int, dy: Int) -> Bool {
        let tileSize = TBNV12Compression.tileSize
        let tilesWide = width / tileSize
        let x = tile % tilesWide * tileSize
        let top = tile / tilesWide * tileSize
        guard x - dx >= 0, top - dy >= 0,
              x - dx + tileSize <= width, top - dy + tileSize <= height
        else {
            return false
        }
        for row in top..<(top + tileSize) {
            for column in x..<(x + tileSize)
            where y[row * width + column] !=
                other.y[(row - dy) * width + column - dx] {
                return false
            }
        }
        for row in (top / 2)..<((top + tileSize) / 2) {
            for column in x..<(x + tileSize)
            where uv[row * width + column] !=
                other.uv[(row - dy / 2) * width + column - dx] {
                return false
            }
        }
        return true
    }

    var tileCount: Int {
        (width / TBNV12Compression.tileSize) *
            (height / TBNV12Compression.tileSize)
    }

    func dirtyTiles(since previous: NV12Frame) -> Set<Int> {
        Set((0..<tileCount).filter {
            !tileEquals(previous, tile: $0, dx: 0, dy: 0)
        })
    }

    func copyableTiles(
        from previous: NV12Frame, among tiles: Set<Int>, dx: Int, dy: Int
    ) -> Set<Int> {
        tiles.filter { tileEquals(previous, tile: $0, dx: dx, dy: dy) }
    }

    /// Applies a decoded format 5 packet the way the Receiver does.
    func applying(_ packet: TBNV12Compression.DecodedCopyRect) -> NV12Frame {
        let tileSize = TBNV12Compression.tileSize
        var result = self
        for run in packet.copyRuns {
            result.copyRect(
                from: self,
                x: run.tileX * tileSize, y: run.tileY * tileSize,
                width: run.tileCountX * tileSize, height: tileSize,
                dx: packet.dx, dy: packet.dy
            )
        }
        let raw = [UInt8](packet.raw)
        for run in packet.freshRuns {
            var offset = run.dataOffset
            for row in 0..<run.pixelHeight {
                let start = (run.y + row) * width + run.x
                result.y.replaceSubrange(
                    start..<(start + run.pixelWidth),
                    with: raw[offset..<(offset + run.pixelWidth)]
                )
                offset += run.pixelWidth
            }
            for row in 0..<(run.pixelHeight / 2) {
                let start = (run.y / 2 + row) * width + run.x
                result.uv.replaceSubrange(
                    start..<(start + run.pixelWidth),
                    with: raw[offset..<(offset + run.pixelWidth)]
                )
                offset += run.pixelWidth
            }
        }
        return result
    }

    func makePixelBuffer() throws -> CVPixelBuffer {
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        var optionalBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault, width, height,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                attributes as CFDictionary, &optionalBuffer
            ),
            kCVReturnSuccess
        )
        let buffer = try XCTUnwrap(optionalBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for (plane, bytes, rows) in [(0, y, height), (1, uv, height / 2)] {
            let base = try XCTUnwrap(
                CVPixelBufferGetBaseAddressOfPlane(buffer, plane)
            )
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            bytes.withUnsafeBytes { source in
                for row in 0..<rows {
                    memcpy(
                        base.advanced(by: row * stride),
                        source.baseAddress!.advanced(by: row * width),
                        width
                    )
                }
            }
        }
        return buffer
    }
}

final class TBNV12CopyRectTests: XCTestCase {
    private let width = 1024
    private let height = 768

    private func makePacket(
        writer: TBNV12TileRunPacketWriter,
        frame: NV12Frame,
        copyTiles: Set<Int>,
        dx: Int,
        dy: Int,
        freshTiles: Set<Int>
    ) -> TBNV12Compression.PacketResult? {
        frame.y.withUnsafeBytes { y in
            frame.uv.withUnsafeBytes { uv in
                writer.makeCopyRectPacket(
                    yBase: y.baseAddress!,
                    uvBase: uv.baseAddress!,
                    yStride: frame.width,
                    uvStride: frame.width,
                    copyTiles: copyTiles,
                    dx: dx,
                    dy: dy,
                    freshTiles: freshTiles,
                    checksumPolicy: .fnv64
                )
            }
        }
    }

    /// A scroll, a drag and a drag to the left over a flat desktop, each
    /// with some unrelated fresh content.
    private func scenarios() -> [(name: String, old: NV12Frame, new: NV12Frame, dx: Int, dy: Int)] {
        let page = NV12Frame.noise(width: width, height: height, seed: 1)
        var scrolled = page
        scrolled.copyRect(
            from: page, x: 0, y: 0, width: width, height: height - 200,
            dx: 0, dy: -200
        )
        scrolled.paintNoise(
            x: 0, y: height - 200, width: width, height: 200, seed: 2
        )

        var desktop = NV12Frame(width: width, height: height)
        desktop.paintNoise(x: 100, y: 100, width: 512, height: 384, seed: 3)
        var dragged = NV12Frame(width: width, height: height)
        dragged.copyRect(
            from: desktop, x: 138, y: 76, width: 512, height: 384,
            dx: 38, dy: -24
        )
        dragged.paintNoise(x: 832, y: 640, width: 128, height: 64, seed: 4)

        var wide = NV12Frame(width: width, height: height)
        wide.paintNoise(x: 640, y: 64, width: 320, height: 448, seed: 5)
        var swept = NV12Frame(width: width, height: height)
        swept.copyRect(
            from: wide, x: 40, y: 64, width: 320, height: 448,
            dx: -600, dy: 0
        )
        return [
            ("vertical scroll", page, scrolled, 0, -200),
            ("drag", desktop, dragged, 38, -24),
            ("horizontal sweep", wide, swept, -600, 0),
        ]
    }

    func testCopyRectPacketRebuildsTheNewFrame() throws {
        for scenario in scenarios() {
            let dirty = scenario.new.dirtyTiles(since: scenario.old)
            let copy = scenario.new.copyableTiles(
                from: scenario.old, among: dirty,
                dx: scenario.dx, dy: scenario.dy
            )
            XCTAssertGreaterThan(copy.count, 16, scenario.name)
            let fresh = dirty.subtracting(copy)
            for encoder in [TBNV12LZ4Encoder.apple, .liblz4(acceleration: 32)] {
                let writer = try XCTUnwrap(
                    TBNV12TileRunPacketWriter(
                        width: width, height: height, encoder: encoder
                    )
                )
                let result = try XCTUnwrap(
                    makePacket(
                        writer: writer, frame: scenario.new,
                        copyTiles: copy, dx: scenario.dx, dy: scenario.dy,
                        freshTiles: fresh
                    ),
                    scenario.name
                )
                let decoded = try XCTUnwrap(
                    TBNV12Compression.decodeCopyRectPacket(result.packet),
                    scenario.name
                )
                XCTAssertEqual(decoded.dx, scenario.dx)
                XCTAssertEqual(decoded.dy, scenario.dy)
                XCTAssertEqual(
                    decoded.copyRuns.reduce(0) { $0 + $1.tileCountX },
                    copy.count
                )
                XCTAssertEqual(
                    decoded.freshRuns.reduce(0) { $0 + $1.tileCountX },
                    fresh.count
                )
                XCTAssertTrue(
                    scenario.old.applying(decoded) == scenario.new,
                    "\(scenario.name) \(encoder)"
                )
                XCTAssertLessThan(
                    result.packet.count,
                    TBNV12Compression.makeTileRunPacket(
                        yBase: scenario.new.y, uvBase: scenario.new.uv,
                        width: width, height: height,
                        yStride: width, uvStride: width,
                        dirtyTiles: dirty, checksumPolicy: .fnv64,
                        encoder: encoder
                    )!.packet.count / 2,
                    scenario.name
                )
            }
        }
    }

    func testCopyOnlyPacketHasNoFreshData() throws {
        let scenario = scenarios()[0]
        let dirty = scenario.new.dirtyTiles(since: scenario.old)
        let copy = scenario.new.copyableTiles(
            from: scenario.old, among: dirty, dx: 0, dy: -200
        )
        let writer = try XCTUnwrap(
            TBNV12TileRunPacketWriter(width: width, height: height)
        )
        let result = try XCTUnwrap(
            makePacket(
                writer: writer, frame: scenario.new,
                copyTiles: copy, dx: 0, dy: -200, freshTiles: []
            )
        )
        XCTAssertEqual(result.rawBytes, 0)
        let decoded = try XCTUnwrap(
            TBNV12Compression.decodeCopyRectPacket(result.packet)
        )
        XCTAssertTrue(decoded.freshRuns.isEmpty)
        XCTAssertTrue(decoded.raw.isEmpty)
        // 45-byte header plus one 8-byte descriptor per copy row.
        XCTAssertEqual(result.packet.count, 45 + 8 * (copy.count / 16))
    }

    func testWriterRejectsInvalidCopies() throws {
        let frame = NV12Frame.noise(width: width, height: height, seed: 9)
        let writer = try XCTUnwrap(
            TBNV12TileRunPacketWriter(width: width, height: height)
        )
        // Odd vector, zero vector, source above the frame, overlapping sets.
        XCTAssertNil(makePacket(
            writer: writer, frame: frame, copyTiles: [20], dx: 1, dy: 0,
            freshTiles: []
        ))
        XCTAssertNil(makePacket(
            writer: writer, frame: frame, copyTiles: [20], dx: 0, dy: 0,
            freshTiles: []
        ))
        XCTAssertNil(makePacket(
            writer: writer, frame: frame, copyTiles: [3], dx: 0, dy: 2,
            freshTiles: []
        ))
        XCTAssertNil(makePacket(
            writer: writer, frame: frame, copyTiles: [20], dx: 0, dy: 2,
            freshTiles: [20, 21]
        ))
        XCTAssertNil(makePacket(
            writer: writer, frame: frame, copyTiles: [], dx: 0, dy: 2,
            freshTiles: [20]
        ))
        XCTAssertEqual(
            writer.availableSlotCount, TBNV12TileRunPacketWriter.slotCount
        )
    }

    func testDecoderRejectsCorruptPackets() throws {
        let scenario = scenarios()[1]
        let dirty = scenario.new.dirtyTiles(since: scenario.old)
        let copy = scenario.new.copyableTiles(
            from: scenario.old, among: dirty, dx: 38, dy: -24
        )
        let writer = try XCTUnwrap(
            TBNV12TileRunPacketWriter(width: width, height: height)
        )
        let packet = try XCTUnwrap(
            makePacket(
                writer: writer, frame: scenario.new,
                copyTiles: copy, dx: 38, dy: -24,
                freshTiles: dirty.subtracting(copy)
            )
        ).packet
        XCTAssertNotNil(TBNV12Compression.decodeCopyRectPacket(packet))
        func corrupted(_ offset: Int, _ value: UInt8) -> Data {
            var bytes = Data(packet)
            bytes[offset] = value
            return bytes
        }
        // Odd dx, a copy source dragged outside the frame, a nonzero
        // reserved field, and a truncated packet.
        XCTAssertNil(TBNV12Compression.decodeCopyRectPacket(corrupted(38, 39)))
        XCTAssertNil(TBNV12Compression.decodeCopyRectPacket(corrupted(37, 0x40)))
        XCTAssertNil(TBNV12Compression.decodeCopyRectPacket(corrupted(52, 1)))
        XCTAssertNil(TBNV12Compression.decodeCopyRectPacket(packet.dropLast()))
    }

    func testDetectorFindsScrollsAndDrags() throws {
        guard let detector = TBNV12TileDetector() else {
            throw XCTSkip("Metal NV12 tile detector unavailable")
        }
        for scenario in scenarios() {
            detector.reset()
            _ = try XCTUnwrap(
                detector.analyze(pixelBuffer: scenario.old.makePixelBuffer())
            )
            detector.commitCandidate()
            let dirty = try XCTUnwrap(
                detector.analyze(pixelBuffer: scenario.new.makePixelBuffer())
            )
            XCTAssertEqual(
                dirty, scenario.new.dirtyTiles(since: scenario.old),
                scenario.name
            )
            let found = try XCTUnwrap(
                detector.findCopyRect(dirtyTiles: dirty), scenario.name
            )
            XCTAssertEqual(found.dx, scenario.dx, scenario.name)
            XCTAssertEqual(found.dy, scenario.dy, scenario.name)
            XCTAssertEqual(
                found.tiles,
                scenario.new.copyableTiles(
                    from: scenario.old, among: dirty,
                    dx: scenario.dx, dy: scenario.dy
                ),
                scenario.name
            )
            // Verification is exact for any vector, not just the found one.
            XCTAssertEqual(
                detector.verifyShift(
                    dx: scenario.dx + 2, dy: scenario.dy, tiles: dirty
                ),
                scenario.new.copyableTiles(
                    from: scenario.old, among: dirty,
                    dx: scenario.dx + 2, dy: scenario.dy
                ),
                scenario.name
            )
            detector.commitCandidate()
        }
    }

    func testDetectorRejectsUnrelatedAndFlatContent() throws {
        guard let detector = TBNV12TileDetector() else {
            throw XCTSkip("Metal NV12 tile detector unavailable")
        }
        let pairs: [(NV12Frame, NV12Frame)] = [
            (
                NV12Frame.noise(width: width, height: height, seed: 11),
                NV12Frame.noise(width: width, height: height, seed: 12)
            ),
            (
                NV12Frame(width: width, height: height, luma: 0x30),
                NV12Frame(width: width, height: height, luma: 0x90)
            ),
        ]
        for (old, new) in pairs {
            detector.reset()
            _ = try XCTUnwrap(detector.analyze(pixelBuffer: old.makePixelBuffer()))
            detector.commitCandidate()
            let dirty = try XCTUnwrap(
                detector.analyze(pixelBuffer: new.makePixelBuffer())
            )
            XCTAssertEqual(dirty.count, new.tileCount)
            XCTAssertNil(detector.findCopyRect(dirtyTiles: dirty))
        }
        // Without a staged candidate there is nothing to search.
        detector.commitCandidate()
        XCTAssertNil(detector.searchShift(dirtyTiles: [0, 1, 2]))
    }

    func testSearchOffsetsAreEvenAndUnique() {
        let offsets = TBNV12TileDetector.CopyRectSearch.offsets()
        XCTAssertEqual(Set(offsets.map { [$0.x, $0.y] }).count, offsets.count)
        XCTAssertTrue(offsets.allSatisfy {
            $0.x % 2 == 0 && $0.y % 2 == 0 && ($0.x != 0 || $0.y != 0)
        })
        XCTAssertTrue(offsets.contains(SIMD2(0, -1440)))
        XCTAssertTrue(offsets.contains(SIMD2(1024, 0)))
        XCTAssertTrue(offsets.contains(SIMD2(-192, 192)))
        XCTAssertFalse(offsets.contains(SIMD2(194, 2)))
    }

    func testBackoffSkipsSearchesWhileMissesContinue() {
        var backoff = TBNV12CopyRectBackoff()
        let frame: UInt64 = 16_666_667
        var now: UInt64 = 0
        func search(_ missed: Bool) -> Bool {
            now += frame
            guard backoff.shouldSearch(at: now) else { return false }
            if missed { backoff.recordMiss() } else { backoff.reset() }
            return true
        }
        // The first miss alone does not skip; the second skips 4 frames.
        XCTAssertTrue(search(true))
        XCTAssertTrue(search(true))
        XCTAssertEqual((0..<4).filter { _ in search(true) }.count, 0)
        // Each missed probe doubles the skip, capped at 8 frames.
        XCTAssertTrue(search(true))
        XCTAssertEqual((0..<8).filter { _ in search(true) }.count, 0)
        XCTAssertTrue(search(true))
        XCTAssertEqual((0..<8).filter { _ in search(true) }.count, 0)
        // A hit on the next probe resumes searching every frame.
        XCTAssertTrue(search(false))
        XCTAssertTrue(search(true))
        XCTAssertTrue(search(true))
        XCTAssertFalse(search(true))
        // An idle pause ends the busy stretch.
        now += TBNV12CopyRectBackoff.idleResetNanoseconds + 1
        XCTAssertTrue(search(true))
        // So does a quiet frame.
        XCTAssertTrue(search(true))
        backoff.reset()
        XCTAssertTrue(search(true))
    }

    func testPredictedOffsetsExtendTheTableWithoutDuplicates() {
        typealias Search = TBNV12TileDetector.CopyRectSearch
        let base = Set(Search.offsets().map { [Int($0.x), Int($0.y)] })
        let predicted = Search.predictedOffsets(
            around: [SIMD2(301, -239), SIMD2(330, -250), SIMD2(10, 0)]
        )
        let pairs = predicted.map { [Int($0.x), Int($0.y)] }
        XCTAssertEqual(Set(pairs).count, pairs.count)
        XCTAssertTrue(Set(pairs).isDisjoint(with: base))
        XCTAssertLessThanOrEqual(predicted.count, Search.predictionCapacity)
        XCTAssertTrue(predicted.allSatisfy { $0.x % 2 == 0 && $0.y % 2 == 0 })
        // The box around (300, -240) is in; the base table covers (10, 0).
        XCTAssertTrue(pairs.contains([300, -240]))
        XCTAssertTrue(pairs.contains([364, -176]))
        XCTAssertFalse(pairs.contains([10, 0]))
        for pair in base.prefix(1000) {
            XCTAssertTrue(Search.isBaseOffset(dx: pair[0], dy: pair[1]))
        }
        XCTAssertFalse(Search.isBaseOffset(dx: 194, dy: 2))
        XCTAssertFalse(Search.isBaseOffset(dx: 0, dy: 0))
        XCTAssertFalse(Search.isBaseOffset(dx: 3, dy: 0))
    }

    func testDetectorFindsFastDiagonalDragAroundPrediction() throws {
        guard let detector = TBNV12TileDetector() else {
            throw XCTSkip("Metal NV12 tile detector unavailable")
        }
        var desktop = NV12Frame(width: width, height: height)
        desktop.paintNoise(x: 80, y: 380, width: 512, height: 384, seed: 6)
        var dragged = NV12Frame(width: width, height: height)
        dragged.copyRect(
            from: desktop, x: 380, y: 140, width: 512, height: 384,
            dx: 300, dy: -240
        )
        _ = try XCTUnwrap(detector.analyze(pixelBuffer: desktop.makePixelBuffer()))
        detector.commitCandidate()
        let dirty = try XCTUnwrap(
            detector.analyze(pixelBuffer: dragged.makePixelBuffer())
        )
        // Beyond the drag box on both axes, the fixed table misses it.
        XCTAssertNil(detector.findCopyRect(dirtyTiles: dirty))
        // A prediction within 64 pixels, e.g. the pointer's move, finds it.
        let found = try XCTUnwrap(
            detector.findCopyRect(
                dirtyTiles: dirty, predictions: [SIMD2(331, -207)]
            )
        )
        XCTAssertEqual(found.dx, 300)
        XCTAssertEqual(found.dy, -240)
        XCTAssertEqual(
            found.tiles,
            dragged.copyableTiles(
                from: desktop, among: dirty, dx: 300, dy: -240
            )
        )
    }

    func testStatsSplitFreshTilesAndVectors() {
        // A 4x3 grid: tiles 5 and 6 copied.
        //   0  1  2  3
        //   4 [5][6] 7
        //   8  9 10 11
        let edges = TBNV12CopyRectStats.edgeTileCount(
            freshTiles: [0, 3, 7, 8, 11], copyTiles: [5, 6],
            tilesWide: 4, tilesHigh: 3
        )
        XCTAssertEqual(edges, 5)
        XCTAssertEqual(
            TBNV12CopyRectStats.edgeTileCount(
                freshTiles: [3, 7, 11], copyTiles: [4, 8],
                tilesWide: 4, tilesHigh: 3
            ),
            0
        )
        var stats = TBNV12CopyRectStats()
        for (dx, dy) in [(4, -2), (100, 120), (0, -600), (300, -240)] {
            stats.recordHit(
                dx: dx, dy: dy, copyTiles: [5], freshTiles: [0, 3],
                tilesWide: 4, tilesHigh: 3
            )
        }
        XCTAssertEqual(stats.nearVectors, 1)
        XCTAssertEqual(stats.dragVectors, 1)
        XCTAssertEqual(stats.scrollVectors, 1)
        XCTAssertEqual(stats.predictedVectors, 1)
        XCTAssertEqual(stats.edgeTiles, 4)
        XCTAssertEqual(stats.freshAreaTiles, 4)
        XCTAssertEqual(stats.metrics["nv12CopyRectEdgeTiles"], 4)
    }

    func testBackoffKeepsSearchingWhileThePointerMoves() {
        var backoff = TBNV12CopyRectBackoff()
        var now: UInt64 = 0
        func search(missed: Bool, pointerMoving: Bool) -> Bool {
            now += 16_666_667
            guard backoff.shouldSearch(
                at: now, pointerMoving: pointerMoving
            ) else { return false }
            if missed { backoff.recordMiss() } else { backoff.reset() }
            return true
        }
        XCTAssertTrue(search(missed: true, pointerMoving: false))
        XCTAssertTrue(search(missed: true, pointerMoving: false))
        XCTAssertFalse(search(missed: true, pointerMoving: false))
        // A drag starts during the skip: every frame probes, and a hit
        // ends the backoff.
        XCTAssertTrue(search(missed: true, pointerMoving: true))
        XCTAssertTrue(search(missed: false, pointerMoving: true))
        XCTAssertTrue(search(missed: true, pointerMoving: false))
    }
}
