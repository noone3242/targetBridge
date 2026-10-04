import Compression
import XCTest
@testable import TargetBridge

final class TBNV12ParallelLZ4EncoderTests: XCTestCase {
    /// Compressible gradient with sparse noise, like captured desktop content.
    private func content(count: Int, seed: UInt32) -> [UInt8] {
        var state = seed
        return (0..<count).map { index in
            state = state &* 1_664_525 &+ 1_013_904_223
            return index % 97 == 0
                ? UInt8(truncatingIfNeeded: state >> 24)
                : UInt8(truncatingIfNeeded: (index % 4096) / 16)
        }
    }

    private func encode(
        _ input: [UInt8],
        with encoder: TBNV12ParallelLZ4Encoder,
        capacity: Int? = nil
    ) -> [UInt8] {
        let capacity = capacity ?? input.count + input.count / 256 + 64 * 1024
        var output = [UInt8](repeating: 0, count: capacity)
        let size = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                encoder.encode(
                    destination: destination.baseAddress!,
                    capacity: capacity,
                    source: source.baseAddress!,
                    length: input.count
                )
            }
        }
        return Array(output.prefix(size))
    }

    /// The plain single-call encoder the parallel one must match when it
    /// does not split.
    private func serialEncode(
        _ input: [UInt8], encoder: TBNV12LZ4Encoder
    ) -> [UInt8] {
        let capacity = input.count + input.count / 256 + 64 * 1024
        var output = [UInt8](repeating: 0, count: capacity)
        let size = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                encoder.encode(
                    destination: destination.baseAddress!,
                    capacity: capacity,
                    source: source.baseAddress!,
                    length: input.count,
                    scratch: nil
                )
            }
        }
        return Array(output.prefix(size))
    }

    private func appleDecode(_ encoded: [UInt8], count: Int) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: count)
        let size = encoded.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                compression_decode_buffer(
                    destination.baseAddress!, count,
                    source.baseAddress!, encoded.count,
                    nil, COMPRESSION_LZ4
                )
            }
        }
        return size == count ? output : nil
    }

    /// Decoded size of every block; nil if the framing is malformed.
    private func blockSizes(_ encoded: [UInt8]) -> [Int]? {
        func le32(_ offset: Int) -> Int {
            (0..<4).reduce(0) { $0 | Int(encoded[offset + $1]) << (8 * $1) }
        }
        var sizes: [Int] = []
        var offset = 0
        while offset + 4 <= encoded.count {
            switch String(decoding: encoded[offset..<(offset + 4)], as: UTF8.self) {
            case "bv4$":
                return offset + 4 == encoded.count ? sizes : nil
            case "bv41":
                sizes.append(le32(offset + 4))
                offset += 12 + le32(offset + 8)
            case "bv4-":
                sizes.append(le32(offset + 4))
                offset += 8 + le32(offset + 4)
            default:
                return nil
            }
        }
        return nil
    }

    func testSplitEncodeDecodesWithAppleDecoder() throws {
        let liblz4 = TBNV12LZ4Encoder.liblz4(acceleration: 32)
        // Uneven length: chunks end mid-block and the last chunk is shorter.
        let input = content(count: 5 * (1 << 20) + 12_345, seed: 3)
        let serial = serialEncode(input, encoder: liblz4)
        for threads in [2, 3, 4] {
            let encoder = TBNV12ParallelLZ4Encoder(
                encoder: liblz4, threadCount: threads
            )
            let encoded = encode(input, with: encoder)
            XCTAssertFalse(encoded.isEmpty, "threads \(threads)")
            XCTAssertEqual(
                appleDecode(encoded, count: input.count), input,
                "threads \(threads)"
            )
            let sizes = try XCTUnwrap(blockSizes(encoded))
            XCTAssertEqual(sizes.reduce(0, +), input.count)
            XCTAssertTrue(sizes.allSatisfy {
                $0 <= TBNV12LZ4Encoder.liblz4BlockSize
            })
            // A chunk boundary only adds a block or two; ratio barely moves.
            XCTAssertLessThan(
                Double(encoded.count), Double(serial.count) * 1.02,
                "threads \(threads)"
            )
            // Reusing the encoder (and its side buffers) is deterministic.
            XCTAssertEqual(encode(input, with: encoder), encoded)
        }
    }

    func testSerialPathsMatchTheSingleThreadEncoderByteForByte() {
        let liblz4 = TBNV12LZ4Encoder.liblz4(acceleration: 32)
        let large = content(count: 3 * (1 << 20), seed: 5)
        XCTAssertEqual(
            encode(large, with: TBNV12ParallelLZ4Encoder(
                encoder: liblz4, threadCount: 1
            )),
            serialEncode(large, encoder: liblz4)
        )
        // Below the threshold the split is skipped.
        let small = content(count: TBNV12ParallelLZ4Encoder.parallelThreshold - 1, seed: 7)
        let twoThreads = TBNV12ParallelLZ4Encoder(encoder: liblz4, threadCount: 2)
        XCTAssertEqual(
            encode(small, with: twoThreads), serialEncode(small, encoder: liblz4)
        )
        // Apple LZ4 always stays on one thread.
        let apple = TBNV12ParallelLZ4Encoder(encoder: .apple, threadCount: 4)
        XCTAssertEqual(apple.threadCount, 1)
        XCTAssertEqual(
            encode(large, with: apple), serialEncode(large, encoder: .apple)
        )
        XCTAssertEqual(appleDecode(encode(large, with: apple), count: large.count), large)
    }

    func testIncompressibleInputAndSmallDestinations() {
        var state: UInt32 = 9
        let noise = (0..<(3 * (1 << 20))).map { _ -> UInt8 in
            state = state &* 1_664_525 &+ 1_013_904_223
            return UInt8(truncatingIfNeeded: state >> 24)
        }
        let encoder = TBNV12ParallelLZ4Encoder(
            encoder: .liblz4(acceleration: 32), threadCount: 2
        )
        let encoded = encode(noise, with: encoder)
        XCTAssertEqual(appleDecode(encoded, count: noise.count), noise)
        XCTAssertLessThanOrEqual(
            encoded.count, TBLZ4AppleFrameBound(noise.count, 1 << 20) + 12
        )
        // Too small for chunk 0, then too small for the concatenation.
        XCTAssertTrue(encode(noise, with: encoder, capacity: 1000).isEmpty)
        XCTAssertTrue(
            encode(noise, with: encoder, capacity: noise.count * 3 / 4).isEmpty
        )
    }

    func testThreadCountDefaultsAndOverrides() {
        typealias Encoder = TBNV12ParallelLZ4Encoder
        XCTAssertEqual(Encoder.threadCount(environment: [:], performanceCores: 8), 2)
        XCTAssertEqual(Encoder.threadCount(environment: [:], performanceCores: 4), 2)
        XCTAssertEqual(Encoder.threadCount(environment: [:], performanceCores: 2), 1)
        XCTAssertEqual(
            Encoder.threadCount(
                environment: ["TB_NV12_LZ4_THREADS": "1"], performanceCores: 8
            ),
            1
        )
        XCTAssertEqual(
            Encoder.threadCount(
                environment: ["TB_NV12_LZ4_THREADS": "4"], performanceCores: 3
            ),
            3
        )
        XCTAssertEqual(
            Encoder.threadCount(
                environment: ["TB_NV12_LZ4_THREADS": "0"], performanceCores: 8
            ),
            2
        )
        XCTAssertGreaterThanOrEqual(Encoder.performanceCoreCount(), 1)
        XCTAssertEqual(
            Encoder.diagnosticName(
                encoder: .liblz4(acceleration: 32), threadCount: 2
            ),
            "liblz4-a32-t2"
        )
        XCTAssertEqual(
            Encoder.diagnosticName(
                encoder: .liblz4(acceleration: 32), threadCount: 1
            ),
            "liblz4-a32"
        )
        XCTAssertEqual(
            Encoder.diagnosticName(encoder: .apple, threadCount: 2), "apple"
        )
    }

    func testFullPacketWithParallelEncoderRoundTrips() throws {
        let width = 1024
        let height = 768
        let y = Data(content(count: width * height, seed: 11))
        let uv = Data(content(count: width * height / 2, seed: 13))
        let encoder = TBNV12LZ4Encoder.liblz4(acceleration: 32)
        let parallel = TBNV12ParallelLZ4Encoder(encoder: encoder, threadCount: 2)
        let result = try XCTUnwrap(TBNV12Compression.makePacket(
            y: y, uv: uv, width: width, height: height,
            yStride: width, uvStride: width,
            checksumPolicy: .fnv64, encoder: encoder,
            parallelEncoder: parallel
        ))
        let decoded = try XCTUnwrap(TBNV12Compression.decodePacket(result.packet))
        XCTAssertEqual(decoded.y, y)
        XCTAssertEqual(decoded.uv, uv)
    }

    func testWriterWithParallelEncoderDecodesToReferenceContents() throws {
        let width = 1024
        let height = 768
        let y = Data(content(count: width * height, seed: 17))
        let uv = Data(content(count: width * height / 2, seed: 19))
        let encoder = TBNV12LZ4Encoder.liblz4(acceleration: 32)
        let writer = try XCTUnwrap(TBNV12TileRunPacketWriter(
            width: width,
            height: height,
            lz4: TBNV12ParallelLZ4Encoder(encoder: encoder, threadCount: 2)
        ))
        // Everything but one tile, so the staged length exceeds the threshold.
        let dirty = Set(0..<(16 * 12)).subtracting([37])
        let packets = try y.withUnsafeBytes { yBytes in
            try uv.withUnsafeBytes { uvBytes in
                (
                    try XCTUnwrap(writer.makeTileRunPacket(
                        yBase: yBytes.baseAddress!, uvBase: uvBytes.baseAddress!,
                        yStride: width, uvStride: width,
                        dirtyTiles: dirty, checksumPolicy: .fnv64
                    )),
                    try XCTUnwrap(TBNV12Compression.makeTileRunPacket(
                        yBase: yBytes.baseAddress!, uvBase: uvBytes.baseAddress!,
                        width: width, height: height,
                        yStride: width, uvStride: width,
                        dirtyTiles: dirty, checksumPolicy: .fnv64,
                        encoder: encoder
                    ))
                )
            }
        }
        XCTAssertGreaterThanOrEqual(
            packets.0.rawBytes, TBNV12ParallelLZ4Encoder.parallelThreshold
        )
        XCTAssertNotEqual(packets.0.packet, packets.1.packet)
        let parallel = try XCTUnwrap(
            TBNV12Compression.decodeTileRunPacket(packets.0.packet)
        )
        let reference = try XCTUnwrap(
            TBNV12Compression.decodeTileRunPacket(packets.1.packet)
        )
        XCTAssertEqual(parallel.runs, reference.runs)
        XCTAssertEqual(parallel.raw, reference.raw)
    }
}
