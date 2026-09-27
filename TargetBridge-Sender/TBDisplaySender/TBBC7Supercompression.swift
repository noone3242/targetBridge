import Compression
import Foundation

enum TBBC7CompressionMode: String, CaseIterable, Identifiable {
    case off
    case lz4
    case lzfse

    var id: String { rawValue }

    func title(_ language: TBDisplaySenderLanguage) -> String {
        switch (self, language) {
        case (.off, .chinese): return "关闭（原始 BC7）"
        case (.off, _): return "Off (raw BC7)"
        case (.lz4, .chinese): return "LZ4（低延迟）"
        case (.lz4, _): return "LZ4 (low latency)"
        case (.lzfse, .chinese): return "LZFSE（高压缩率）"
        case (.lzfse, _): return "LZFSE (high compression)"
        }
    }
}

enum TBBC7CompressionAlgorithm: UInt8 {
    case lzfse = 1
    case lz4 = 2

    var compressionAlgorithm: compression_algorithm {
        switch self {
        case .lzfse: return COMPRESSION_LZFSE
        case .lz4: return COMPRESSION_LZ4
        }
    }

    var endMarkerThirdByte: UInt8 {
        switch self {
        case .lzfse: return 0x78
        case .lz4: return 0x34
        }
    }
}

enum TBBC7BlockTransform: UInt8 {
    case raw = 0
    case bytePlanes = 1
}

func tbResolveBC7CompressionMode(
    requested: TBBC7CompressionMode,
    supportsLZ4: Bool,
    supportsLZFSE: Bool
) -> TBBC7CompressionMode {
    switch requested {
    case .off:
        return .off
    case .lz4:
        return supportsLZ4 ? .lz4 : .off
    case .lzfse:
        return supportsLZFSE ? .lzfse : .off
    }
}

struct TBBC7CompressedPacketResult {
    let packet: Data
    let mode: TBBC7CompressionMode
    let rawPacketBytes: Int
    let rawBlockBytes: Int
    let compressedBlockBytes: Int
    let planeSplitNanoseconds: UInt64
    let compressionNanoseconds: UInt64
}

struct TBBC7WirePacketSelection {
    let packet: Data
    let compressedResult: TBBC7CompressedPacketResult?
    let compressionAttempted: Bool
}

func tbSelectBC7WirePacket(
    rawPacket: Data,
    compressionMode: TBBC7CompressionMode
) -> TBBC7WirePacketSelection {
    let attempted =
        compressionMode != .off &&
        rawPacket.count >= TBBC7Supercompression.minimumBlockBytes + 18
    let result = attempted
        ? TBBC7Supercompression.makeCompressedPacket(
            from: rawPacket,
            mode: compressionMode
        )
        : nil
    return TBBC7WirePacketSelection(
        packet: result?.packet ?? rawPacket,
        compressedResult: result,
        compressionAttempted: attempted
    )
}

enum TBBC7Supercompression {
    static let minimumBlockBytes = 64 * 1024
    static let minimumSavingsBytes = 4 * 1024

    private static let version: UInt8 = 1
    private static let wrapperHeaderBytes = 24

    static func makeCompressedPacket(
        from legacyPacket: Data,
        mode: TBBC7CompressionMode = .lzfse
    ) -> TBBC7CompressedPacketResult? {
        guard mode != .off else { return nil }
        guard legacyPacket.count >= 5,
              TBMonitorProtocol.readBE32(legacyPacket, offset: 0) ==
                UInt32(legacyPacket.count - 4),
              let type = TBMonitorPacketType(rawValue: legacyPacket[4]),
              let parts = splitLegacyPacket(legacyPacket, type: type),
              parts.blocks.count >= minimumBlockBytes
        else {
            return nil
        }

        let algorithm: TBBC7CompressionAlgorithm
        let transform: TBBC7BlockTransform
        let splitStarted = DispatchTime.now().uptimeNanoseconds
        let compressionSource: Data
        let planeSplitNanoseconds: UInt64
        switch mode {
        case .off:
            return nil
        case .lz4:
            algorithm = .lz4
            transform = .raw
            compressionSource = parts.blocks
            planeSplitNanoseconds = 0
        case .lzfse:
            algorithm = .lzfse
            transform = .bytePlanes
            guard let planes = planeSplit(parts.blocks) else { return nil }
            compressionSource = planes
            planeSplitNanoseconds =
                DispatchTime.now().uptimeNanoseconds - splitStarted
        }
        let compressionStarted = DispatchTime.now().uptimeNanoseconds
        guard let compressed = compress(
            compressionSource,
            algorithm: algorithm.compressionAlgorithm
        ) else {
            return nil
        }
        let compressionFinished = DispatchTime.now().uptimeNanoseconds

        let compressedType: TBMonitorPacketType
        switch type {
        case .bc7Frame:
            compressedType = .bc7CompressedFrame
        case .bc7TileDelta:
            compressedType = .bc7CompressedDelta
        default:
            return nil
        }

        var payload = Data(
            capacity: wrapperHeaderBytes + parts.metadata.count + compressed.count
        )
        payload.append(version)
        payload.append(algorithm.rawValue)
        payload.append(transform.rawValue)
        payload.append(0)
        TBMonitorProtocol.appendBE32(&payload, UInt32(parts.metadata.count))
        TBMonitorProtocol.appendBE32(&payload, UInt32(parts.blocks.count))
        TBMonitorProtocol.appendBE32(&payload, UInt32(compressed.count))
        TBMonitorProtocol.appendBE64(&payload, checksum(compressed))
        payload.append(parts.metadata)
        payload.append(compressed)
        let packet = TBMonitorProtocol.makePacket(type: compressedType, payload: payload)
        guard legacyPacket.count - packet.count >= minimumSavingsBytes else {
            return nil
        }

        return TBBC7CompressedPacketResult(
            packet: packet,
            mode: mode,
            rawPacketBytes: legacyPacket.count,
            rawBlockBytes: parts.blocks.count,
            compressedBlockBytes: compressed.count,
            planeSplitNanoseconds: planeSplitNanoseconds,
            compressionNanoseconds: compressionFinished - compressionStarted
        )
    }

    static func decodeCompressedPacket(_ packet: Data) -> Data? {
        guard packet.count >= 5 + wrapperHeaderBytes,
              TBMonitorProtocol.readBE32(packet, offset: 0) ==
                UInt32(packet.count - 4),
              let compressedType = TBMonitorPacketType(rawValue: packet[4]),
              compressedType == .bc7CompressedFrame ||
                compressedType == .bc7CompressedDelta
        else {
            return nil
        }
        let payload = packet.subdata(in: 5..<packet.count)
        guard let algorithm = TBBC7CompressionAlgorithm(rawValue: payload[1]),
              let transform = TBBC7BlockTransform(rawValue: payload[2])
        else {
            return nil
        }
        guard payload[0] == version,
              payload[3] == 0,
              (algorithm == .lzfse && transform == .bytePlanes) ||
              (algorithm == .lz4 && transform == .raw)
        else {
            return nil
        }
        let metadataLength = Int(TBMonitorProtocol.readBE32(payload, offset: 4))
        let blockLength = Int(TBMonitorProtocol.readBE32(payload, offset: 8))
        let compressedLength = Int(TBMonitorProtocol.readBE32(payload, offset: 12))
        let compressedChecksum = TBMonitorProtocol.readBE64(payload, offset: 16)
        guard metadataLength >= 0,
              blockLength > 0,
              blockLength % 16 == 0,
              compressedLength > 0,
              wrapperHeaderBytes + metadataLength + compressedLength == payload.count
        else {
            return nil
        }
        let metadataStart = wrapperHeaderBytes
        let compressedStart = metadataStart + metadataLength
        let metadataIsValid: Bool
        switch compressedType {
        case .bc7CompressedFrame:
            metadataIsValid = validateFrameMetadata(
                payload,
                offset: metadataStart,
                length: metadataLength,
                blockLength: blockLength
            )
        case .bc7CompressedDelta:
            metadataIsValid = validateDeltaMetadata(
                payload,
                offset: metadataStart,
                length: metadataLength,
                blockLength: blockLength
            )
        default:
            metadataIsValid = false
        }
        guard metadataIsValid else { return nil }
        let metadata = payload.subdata(
            in: metadataStart..<compressedStart
        )
        let compressed = payload.subdata(
            in: compressedStart..<payload.count
        )
        guard compressed.count >= 4,
              compressed[compressed.count - 4] == 0x62,
              compressed[compressed.count - 3] == 0x76,
              compressed[compressed.count - 2] ==
                algorithm.endMarkerThirdByte,
              compressed[compressed.count - 1] == 0x24
        else {
            return nil
        }
        guard checksum(compressed) == compressedChecksum else { return nil }
        guard let transformed = decompress(
            compressed,
            uncompressedLength: blockLength,
            algorithm: algorithm.compressionAlgorithm
        ) else {
            return nil
        }
        let blocks: Data
        if transform == .bytePlanes {
            guard let restored = inversePlaneSplit(transformed) else {
                return nil
            }
            blocks = restored
        } else {
            blocks = transformed
        }

        let legacyPayload: Data?
        switch compressedType {
        case .bc7CompressedFrame:
            legacyPayload = reconstructFramePayload(
                metadata: metadata,
                blocks: blocks
            )
        case .bc7CompressedDelta:
            legacyPayload = reconstructDeltaPayload(
                metadata: metadata,
                blocks: blocks
            )
        default:
            legacyPayload = nil
        }
        guard let legacyPayload else { return nil }
        let legacyType: TBMonitorPacketType =
            compressedType == .bc7CompressedFrame ? .bc7Frame : .bc7TileDelta
        return TBMonitorProtocol.makePacket(type: legacyType, payload: legacyPayload)
    }

    static func planeSplit(_ blocks: Data) -> Data? {
        guard !blocks.isEmpty, blocks.count % 16 == 0 else { return nil }
        let blockCount = blocks.count / 16
        var result = Data(count: blocks.count)
        blocks.withUnsafeBytes { sourceBytes in
            result.withUnsafeMutableBytes { destinationBytes in
                guard let source = sourceBytes.baseAddress?
                    .assumingMemoryBound(to: UInt8.self),
                    let destination = destinationBytes.baseAddress?
                    .assumingMemoryBound(to: UInt8.self)
                else {
                    return
                }
                for byteIndex in 0..<16 {
                    let planeOffset = byteIndex * blockCount
                    for blockIndex in 0..<blockCount {
                        destination[planeOffset + blockIndex] =
                            source[blockIndex * 16 + byteIndex]
                    }
                }
            }
        }
        return result
    }

    static func inversePlaneSplit(_ planes: Data) -> Data? {
        guard !planes.isEmpty, planes.count % 16 == 0 else { return nil }
        let blockCount = planes.count / 16
        var result = Data(count: planes.count)
        planes.withUnsafeBytes { sourceBytes in
            result.withUnsafeMutableBytes { destinationBytes in
                guard let source = sourceBytes.baseAddress?
                    .assumingMemoryBound(to: UInt8.self),
                    let destination = destinationBytes.baseAddress?
                    .assumingMemoryBound(to: UInt8.self)
                else {
                    return
                }
                for byteIndex in 0..<16 {
                    let planeOffset = byteIndex * blockCount
                    for blockIndex in 0..<blockCount {
                        destination[blockIndex * 16 + byteIndex] =
                            source[planeOffset + blockIndex]
                    }
                }
            }
        }
        return result
    }

    private static func splitLegacyPacket(
        _ packet: Data,
        type: TBMonitorPacketType
    ) -> (metadata: Data, blocks: Data)? {
        let payload = packet.subdata(in: 5..<packet.count)
        switch type {
        case .bc7Frame:
            guard !payload.isEmpty else { return nil }
            let headerLength: Int
            switch payload[0] {
            case 1: headerLength = 13
            case 2: headerLength = 29
            default: return nil
            }
            guard payload.count > headerLength else { return nil }
            return (
                payload.subdata(in: 0..<headerLength),
                payload.subdata(in: headerLength..<payload.count)
            )
        case .bc7TileDelta:
            guard payload.count >= 37, payload[0] == 1 else { return nil }
            let runCount = Int(TBMonitorProtocol.readBE16(payload, offset: 35))
            var metadata = Data(payload.prefix(37))
            var blocks = Data()
            var offset = 37
            for _ in 0..<runCount {
                guard payload.count - offset >= 12 else { return nil }
                let dataLength = Int(
                    TBMonitorProtocol.readBE32(payload, offset: offset + 8)
                )
                let dataStart = offset + 12
                guard dataLength >= 0,
                      payload.count - dataStart >= dataLength
                else {
                    return nil
                }
                metadata.append(payload[offset..<(offset + 12)])
                blocks.append(payload[dataStart..<(dataStart + dataLength)])
                offset = dataStart + dataLength
            }
            guard offset == payload.count, !blocks.isEmpty else { return nil }
            return (metadata, blocks)
        default:
            return nil
        }
    }

    private static func reconstructFramePayload(
        metadata: Data,
        blocks: Data
    ) -> Data? {
        guard !metadata.isEmpty else { return nil }
        let expectedMetadataLength: Int
        switch metadata[0] {
        case 1: expectedMetadataLength = 13
        case 2: expectedMetadataLength = 29
        default: return nil
        }
        guard metadata.count == expectedMetadataLength else { return nil }
        return metadata + blocks
    }

    private static func reconstructDeltaPayload(
        metadata: Data,
        blocks: Data
    ) -> Data? {
        guard metadata.count >= 37, metadata[0] == 1 else { return nil }
        let runCount = Int(TBMonitorProtocol.readBE16(metadata, offset: 35))
        guard metadata.count == 37 + runCount * 12 else { return nil }
        var blockOffset = 0
        var payload = Data(metadata.prefix(37))
        for runIndex in 0..<runCount {
            let descriptorOffset = 37 + runIndex * 12
            let dataLength = Int(
                TBMonitorProtocol.readBE32(
                    metadata,
                    offset: descriptorOffset + 8
                )
            )
            guard dataLength >= 0, blocks.count - blockOffset >= dataLength else {
                return nil
            }
            payload.append(
                metadata[descriptorOffset..<(descriptorOffset + 12)]
            )
            payload.append(blocks[blockOffset..<(blockOffset + dataLength)])
            blockOffset += dataLength
        }
        return blockOffset == blocks.count ? payload : nil
    }

    private static func validateFrameMetadata(
        _ payload: Data,
        offset: Int,
        length: Int,
        blockLength: Int
    ) -> Bool {
        guard offset >= 0, length > 0, payload.count - offset >= length else {
            return false
        }
        let format = payload[offset]
        let expectedLength: Int
        let dimensionOffset: Int
        switch format {
        case 1:
            expectedLength = 13
            dimensionOffset = offset + 1
        case 2:
            expectedLength = 29
            dimensionOffset = offset + 17
        default:
            return false
        }
        guard length == expectedLength else { return false }
        let width = Int(
            TBMonitorProtocol.readBE32(payload, offset: dimensionOffset)
        )
        let height = Int(
            TBMonitorProtocol.readBE32(payload, offset: dimensionOffset + 4)
        )
        let bytesPerRow = Int(
            TBMonitorProtocol.readBE32(payload, offset: dimensionOffset + 8)
        )
        return width > 0 && height > 0 &&
            width <= 8192 && height <= 8192 &&
            width % 4 == 0 && height % 4 == 0 &&
            bytesPerRow == width / 4 * 16 &&
            blockLength == bytesPerRow * (height / 4) &&
            length + blockLength < 64 * 1024 * 1024
    }

    private static func validateDeltaMetadata(
        _ payload: Data,
        offset: Int,
        length: Int,
        blockLength: Int
    ) -> Bool {
        guard offset >= 0, length >= 37,
              payload.count - offset >= length,
              payload[offset] == 1
        else {
            return false
        }
        let width = Int(TBMonitorProtocol.readBE32(payload, offset: offset + 25))
        let height = Int(TBMonitorProtocol.readBE32(payload, offset: offset + 29))
        let tileSize = Int(TBMonitorProtocol.readBE16(payload, offset: offset + 33))
        let runCount = Int(TBMonitorProtocol.readBE16(payload, offset: offset + 35))
        guard width > 0, height > 0,
              width <= 8192, height <= 8192,
              width % 4 == 0, height % 4 == 0,
              tileSize == TBBC7DeltaPlanner.tileSize,
              width % tileSize == 0,
              runCount <= TBBC7DeltaPlanner.maxDeltaRuns,
              length == 37 + runCount * 12,
              length + blockLength < 64 * 1024 * 1024
        else {
            return false
        }
        let tilesWide = width / tileSize
        let tilesHigh = (height + tileSize - 1) / tileSize
        var expectedBlocks = 0
        for runIndex in 0..<runCount {
            let descriptorOffset = offset + 37 + runIndex * 12
            let tileX = Int(
                TBMonitorProtocol.readBE16(payload, offset: descriptorOffset)
            )
            let tileY = Int(
                TBMonitorProtocol.readBE16(payload, offset: descriptorOffset + 2)
            )
            let tileCountX = Int(
                TBMonitorProtocol.readBE16(payload, offset: descriptorOffset + 4)
            )
            let pixelHeight = Int(
                TBMonitorProtocol.readBE16(payload, offset: descriptorOffset + 6)
            )
            let dataLength = Int(
                TBMonitorProtocol.readBE32(payload, offset: descriptorOffset + 8)
            )
            guard tileCountX > 0,
                  tileY < tilesHigh,
                  tileX + tileCountX <= tilesWide
            else {
                return false
            }
            let expectedHeight = min(tileSize, height - tileY * tileSize)
            let expectedLength =
                tileCountX * (tileSize / 4) * 16 * (expectedHeight / 4)
            guard pixelHeight == expectedHeight,
                  dataLength == expectedLength,
                  expectedBlocks <= Int.max - dataLength
            else {
                return false
            }
            expectedBlocks += dataLength
        }
        return expectedBlocks == blockLength
    }

    private static func compress(
        _ source: Data,
        algorithm: compression_algorithm
    ) -> Data? {
        let destinationCapacity = source.count + 64 * 1024
        var destination = Data(count: destinationCapacity)
        let scratchSize = compression_encode_scratch_buffer_size(algorithm)
        let scratch = UnsafeMutableRawPointer.allocate(
            byteCount: max(1, scratchSize),
            alignment: 64
        )
        defer { scratch.deallocate() }
        let encodedSize = source.withUnsafeBytes { sourceBytes in
            destination.withUnsafeMutableBytes { destinationBytes in
                guard let sourceAddress = sourceBytes.baseAddress?
                    .assumingMemoryBound(to: UInt8.self),
                    let destinationAddress = destinationBytes.baseAddress?
                    .assumingMemoryBound(to: UInt8.self)
                else {
                    return 0
                }

                return compression_encode_buffer(
                    destinationAddress,
                    destinationCapacity,
                    sourceAddress,
                    source.count,
                    scratch,
                    algorithm
                )
            }
        }
        guard encodedSize > 0 else { return nil }
        destination.count = encodedSize
        return destination
    }

    private static func checksum(_ data: Data) -> UInt64 {
        var hash = UInt64(14_695_981_039_346_656_037)
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    private static func decompress(
        _ source: Data,
        uncompressedLength: Int,
        algorithm: compression_algorithm
    ) -> Data? {
        guard uncompressedLength > 0, uncompressedLength < Int.max else {
            return nil
        }
        var destination = Data(count: uncompressedLength + 1)
        let valid = source.withUnsafeBytes { sourceBytes in
            destination.withUnsafeMutableBytes { destinationBytes in
                guard let sourceAddress = sourceBytes.baseAddress?
                    .assumingMemoryBound(to: UInt8.self),
                    let destinationAddress = destinationBytes.baseAddress?
                    .assumingMemoryBound(to: UInt8.self)
                else {
                    return false
                }
                var stream = compression_stream(
                    dst_ptr: destinationAddress,
                    dst_size: uncompressedLength + 1,
                    src_ptr: sourceAddress,
                    src_size: source.count,
                    state: nil
                )
                guard compression_stream_init(
                    &stream,
                    COMPRESSION_STREAM_DECODE,
                    algorithm
                ) != COMPRESSION_STATUS_ERROR else {
                    return false
                }
                defer { compression_stream_destroy(&stream) }
                stream.src_ptr = sourceAddress
                stream.src_size = source.count
                stream.dst_ptr = destinationAddress
                stream.dst_size = uncompressedLength + 1
                var status: compression_status
                repeat {
                    let previousSourceSize = stream.src_size
                    let previousDestinationSize = stream.dst_size
                    status = compression_stream_process(
                        &stream,
                        Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                    )
                    if status == COMPRESSION_STATUS_OK,
                       stream.src_size == previousSourceSize,
                       stream.dst_size == previousDestinationSize {
                        return false
                    }
                } while status == COMPRESSION_STATUS_OK && stream.dst_size > 0
                let decodedSize =
                    uncompressedLength + 1 - stream.dst_size
                return status == COMPRESSION_STATUS_END &&
                    stream.src_size == 0 &&
                    decodedSize == uncompressedLength
            }
        }
        guard valid else { return nil }
        destination.count = uncompressedLength
        return destination
    }
}
