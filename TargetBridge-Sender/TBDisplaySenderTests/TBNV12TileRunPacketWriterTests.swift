import XCTest
@testable import TargetBridge

final class TBNV12TileRunPacketWriterTests: XCTestCase {
    private let width = 512
    private let height = 256
    // Padded strides, as CoreVideo usually produces.
    private let yStride = 576
    private let uvStride = 576

    private func makePlanes() -> (y: Data, uv: Data) {
        var state: UInt32 = 0x1234_5678
        func next() -> UInt8 {
            state = state &* 1_664_525 &+ 1_013_904_223
            return UInt8(truncatingIfNeeded: state >> 24)
        }
        // Mix compressible gradients with noise so LZ4 emits both matches
        // and literals.
        let y = Data((0..<(yStride * height)).map {
            $0 % 7 == 0 ? next() : UInt8(truncatingIfNeeded: $0 / 3)
        })
        let uv = Data((0..<(uvStride * height / 2)).map {
            $0 % 5 == 0 ? next() : UInt8(truncatingIfNeeded: $0 &* 3)
        })
        return (y, uv)
    }

    private func packets(
        writer: TBNV12TileRunPacketWriter,
        dirtyTiles: Set<Int>,
        checksumPolicy: TBNV12ChecksumPolicy
    ) throws -> (reference: Data, zeroCopy: Data?) {
        let encoder = writer.encoder
        let (y, uv) = makePlanes()
        return try y.withUnsafeBytes { yBytes in
            try uv.withUnsafeBytes { uvBytes in
                let yBase = try XCTUnwrap(yBytes.baseAddress)
                let uvBase = try XCTUnwrap(uvBytes.baseAddress)
                let reference = try XCTUnwrap(
                    TBNV12Compression.makeTileRunPacket(
                        yBase: yBase,
                        uvBase: uvBase,
                        width: width,
                        height: height,
                        yStride: yStride,
                        uvStride: uvStride,
                        dirtyTiles: dirtyTiles,
                        checksumPolicy: checksumPolicy,
                        encoder: encoder
                    )
                ).packet
                let zeroCopy = writer.makeTileRunPacket(
                    yBase: yBase,
                    uvBase: uvBase,
                    yStride: yStride,
                    uvStride: uvStride,
                    dirtyTiles: dirtyTiles,
                    checksumPolicy: checksumPolicy
                )?.packet
                return (reference, zeroCopy)
            }
        }
    }

    func testPacketsMatchReferenceBuilderByteForByte() throws {
        // 8×4 tiles: a single tile, a full row, scattered runs, everything.
        let cases: [Set<Int>] = [
            [0],
            Set(8..<16),
            [1, 2, 5, 9, 10, 11, 20, 31],
            Set(0..<32),
        ]
        for encoder in [TBNV12LZ4Encoder.apple, .liblz4(acceleration: 32)] {
            let writer = try XCTUnwrap(
                TBNV12TileRunPacketWriter(
                    width: width, height: height, encoder: encoder
                )
            )
            for dirtyTiles in cases {
                for policy in [TBNV12ChecksumPolicy.disabled, .fnv64] {
                    let result = try packets(
                        writer: writer,
                        dirtyTiles: dirtyTiles,
                        checksumPolicy: policy
                    )
                    XCTAssertEqual(
                        try XCTUnwrap(result.zeroCopy),
                        result.reference,
                        "\(encoder) dirtyTiles \(dirtyTiles.sorted()) " +
                            "policy \(policy)"
                    )
                }
            }
            XCTAssertEqual(
                writer.availableSlotCount, TBNV12TileRunPacketWriter.slotCount
            )
        }
    }

    func testPacketDecodesToDirtyTileContents() throws {
        let writer = try XCTUnwrap(
            TBNV12TileRunPacketWriter(width: width, height: height)
        )
        let result = try packets(
            writer: writer,
            dirtyTiles: [3, 4, 12],
            checksumPolicy: .fnv64
        )
        let packet = try XCTUnwrap(result.zeroCopy)
        let decoded = try XCTUnwrap(
            TBNV12Compression.decodeTileRunPacket(packet)
        )
        let reference = try XCTUnwrap(
            TBNV12Compression.decodeTileRunPacket(result.reference)
        )
        XCTAssertEqual(decoded.runs, reference.runs)
        XCTAssertEqual(decoded.raw, reference.raw)
    }

    func testLibLZ4PacketDecodesToSameContentsAsAppleLZ4() throws {
        let dirtyTiles: Set<Int> = [1, 2, 5, 9, 10, 11, 20, 31]
        let apple = try XCTUnwrap(
            TBNV12TileRunPacketWriter(width: width, height: height)
        )
        let liblz4 = try XCTUnwrap(
            TBNV12TileRunPacketWriter(
                width: width,
                height: height,
                encoder: .liblz4(acceleration: 32)
            )
        )
        let applePacket = try XCTUnwrap(
            packets(
                writer: apple, dirtyTiles: dirtyTiles, checksumPolicy: .fnv64
            ).zeroCopy
        )
        let liblz4Packet = try XCTUnwrap(
            packets(
                writer: liblz4, dirtyTiles: dirtyTiles, checksumPolicy: .fnv64
            ).zeroCopy
        )
        XCTAssertNotEqual(liblz4Packet, applePacket)
        let fromApple = try XCTUnwrap(
            TBNV12Compression.decodeTileRunPacket(applePacket)
        )
        let fromLibLZ4 = try XCTUnwrap(
            TBNV12Compression.decodeTileRunPacket(liblz4Packet)
        )
        XCTAssertEqual(fromLibLZ4.runs, fromApple.runs)
        XCTAssertEqual(fromLibLZ4.raw, fromApple.raw)
    }

    func testBusySlotsAreNeverReusedUntilPacketsAreReleased() throws {
        let writer = try XCTUnwrap(
            TBNV12TileRunPacketWriter(width: width, height: height)
        )
        var held: [Data] = []
        for _ in 0..<TBNV12TileRunPacketWriter.slotCount {
            let result = try packets(
                writer: writer, dirtyTiles: Set(0..<32), checksumPolicy: .disabled
            )
            held.append(try XCTUnwrap(result.zeroCopy))
        }
        XCTAssertEqual(writer.availableSlotCount, 0)
        let snapshot = held.map { Data(Array($0)) }

        // With every slot busy the writer must refuse instead of overwriting.
        let exhausted = try packets(
            writer: writer, dirtyTiles: [0], checksumPolicy: .disabled
        )
        XCTAssertNil(exhausted.zeroCopy)
        XCTAssertEqual(held, snapshot)

        held.removeFirst()
        XCTAssertEqual(writer.availableSlotCount, 1)
        let reused = try packets(
            writer: writer, dirtyTiles: [0], checksumPolicy: .disabled
        )
        XCTAssertEqual(try XCTUnwrap(reused.zeroCopy), reused.reference)
        XCTAssertEqual(held[0], snapshot[1])
    }

    func testRejectsUnsupportedGeometryAndInvalidTiles() throws {
        XCTAssertNil(TBNV12TileRunPacketWriter(width: 100, height: 64))
        let writer = try XCTUnwrap(
            TBNV12TileRunPacketWriter(width: width, height: height)
        )
        let (y, uv) = makePlanes()
        let invalid = y.withUnsafeBytes { yBytes in
            uv.withUnsafeBytes { uvBytes in
                writer.makeTileRunPacket(
                    yBase: yBytes.baseAddress!,
                    uvBase: uvBytes.baseAddress!,
                    yStride: yStride,
                    uvStride: uvStride,
                    dirtyTiles: [32]
                )
            }
        }
        XCTAssertNil(invalid)
        XCTAssertEqual(
            writer.availableSlotCount, TBNV12TileRunPacketWriter.slotCount
        )
    }
}
