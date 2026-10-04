import Compression
import XCTest
@testable import TargetBridge

final class TBNV12LZ4EncoderTests: XCTestCase {
    private func noise(count: Int, seed: UInt32) -> [UInt8] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return UInt8(truncatingIfNeeded: state >> 24)
        }
    }

    private func encode(
        _ input: [UInt8],
        encoder: TBNV12LZ4Encoder,
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
                    length: input.count,
                    scratch: nil
                )
            }
        }
        return Array(output.prefix(size))
    }

    /// Decodes with Apple's decoder, exactly as the Receiver does.
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

    /// Splits Apple LZ4 framing into block tags; nil if the stream is malformed.
    private func blockTags(_ encoded: [UInt8]) -> [String]? {
        func le32(_ offset: Int) -> Int {
            (0..<4).reduce(0) { $0 | Int(encoded[offset + $1]) << (8 * $1) }
        }
        var tags: [String] = []
        var offset = 0
        while offset + 4 <= encoded.count {
            let tag = String(decoding: encoded[offset..<(offset + 4)], as: UTF8.self)
            tags.append(tag)
            switch tag {
            case "bv4$":
                return offset + 4 == encoded.count ? tags : nil
            case "bv41":
                offset += 12 + le32(offset + 8)
            case "bv4-":
                offset += 8 + le32(offset + 4)
            default:
                return nil
            }
        }
        return nil
    }

    func testLibLZ4OutputDecodesWithAppleDecoder() throws {
        // Compressible, spanning several 1 MiB blocks with a partial tail.
        let blockSize = TBNV12LZ4Encoder.liblz4BlockSize
        let sparkle = noise(count: blockSize * 5 / 2, seed: 5)
        let gradient = sparkle.indices.map {
            $0 % 509 == 0
                ? sparkle[$0]
                : UInt8(truncatingIfNeeded: ($0 % 4096) / 16)
        }
        let encoded = encode(gradient, encoder: .liblz4(acceleration: 32))
        XCTAssertLessThan(encoded.count, gradient.count / 2)
        XCTAssertEqual(
            blockTags(encoded), ["bv41", "bv41", "bv41", "bv4$"]
        )
        XCTAssertEqual(appleDecode(encoded, count: gradient.count), gradient)
    }

    func testLibLZ4StoresIncompressibleBlocksRaw() throws {
        let input = noise(count: 300_000, seed: 7)
        let encoded = encode(input, encoder: .liblz4(acceleration: 32))
        XCTAssertEqual(blockTags(encoded), ["bv4-", "bv4$"])
        XCTAssertEqual(
            encoded.count, TBLZ4AppleFrameBound(input.count, 1 << 20) - 4
        )
        XCTAssertEqual(appleDecode(encoded, count: input.count), input)
    }

    func testLibLZ4HandlesTinyInputsAndRejectsSmallDestinations() {
        for input in [[UInt8(42)], [UInt8](repeating: 9, count: 17)] {
            let encoded = encode(input, encoder: .liblz4(acceleration: 1))
            XCTAssertEqual(appleDecode(encoded, count: input.count), input)
        }
        let input = noise(count: 4096, seed: 3)
        XCTAssertTrue(
            encode(input, encoder: .liblz4(acceleration: 32), capacity: 100)
                .isEmpty
        )
    }

    func testEnvironmentSelectsEncoder() {
        XCTAssertEqual(
            TBNV12LZ4Encoder.fromEnvironment([:]),
            .liblz4(acceleration: TBNV12LZ4Encoder.defaultAcceleration)
        )
        XCTAssertEqual(
            TBNV12LZ4Encoder.fromEnvironment(["TB_NV12_LIBLZ4": "0"]), .apple
        )
        XCTAssertEqual(
            TBNV12LZ4Encoder.fromEnvironment(
                ["TB_NV12_LIBLZ4_ACCELERATION": "8"]
            ),
            .liblz4(acceleration: 8)
        )
        XCTAssertEqual(
            TBNV12LZ4Encoder.fromEnvironment(
                ["TB_NV12_LIBLZ4_ACCELERATION": "-1"]
            ),
            .liblz4(acceleration: TBNV12LZ4Encoder.defaultAcceleration)
        )
        XCTAssertEqual(
            TBNV12LZ4Encoder.liblz4(acceleration: 32).diagnosticName,
            "liblz4-a32"
        )
    }

    func testFullAndRegionPacketsRoundTripWithLibLZ4() throws {
        let width = 256
        let height = 128
        let yStride = 288
        let uvStride = 288
        // Row gradients with sparse noise: compressible, but not trivially.
        let y = Data(noise(count: yStride * height, seed: 11).enumerated().map {
            $0.offset % 64 == 0
                ? $0.element
                : UInt8(truncatingIfNeeded: ($0.offset % yStride) / 2)
        })
        let uv = Data(noise(count: uvStride * height / 2, seed: 13).enumerated().map {
            $0.offset % 32 == 0 ? $0.element : 0x80
        })
        let encoder = TBNV12LZ4Encoder.liblz4(acceleration: 32)

        let full = try XCTUnwrap(TBNV12Compression.makePacket(
            y: y, uv: uv, width: width, height: height,
            yStride: yStride, uvStride: uvStride,
            checksumPolicy: .fnv64, encoder: encoder
        ))
        let decoded = try XCTUnwrap(
            TBNV12Compression.decodePacket(full.packet)
        )
        XCTAssertEqual(decoded.y, y)
        XCTAssertEqual(decoded.uv, uv)

        let regions = try y.withUnsafeBytes { yBytes in
            try uv.withUnsafeBytes { uvBytes in
                try [TBNV12LZ4Encoder.apple, encoder].map {
                    try XCTUnwrap(TBNV12Compression.makeRegionPacket(
                        yBase: yBytes.baseAddress!,
                        uvBase: uvBytes.baseAddress!,
                        width: width, height: height,
                        yStride: yStride, uvStride: uvStride,
                        x: 32, y: 16, regionWidth: 128, regionHeight: 64,
                        checksumPolicy: .fnv64, encoder: $0
                    )).packet
                }
            }
        }
        let fromApple = try XCTUnwrap(
            TBNV12Compression.decodeRegionPacket(regions[0])
        )
        let fromLibLZ4 = try XCTUnwrap(
            TBNV12Compression.decodeRegionPacket(regions[1])
        )
        XCTAssertEqual(fromLibLZ4.raw, fromApple.raw)
        XCTAssertEqual(fromLibLZ4.x, 32)
        XCTAssertEqual(fromLibLZ4.regionHeight, 64)
    }
}
