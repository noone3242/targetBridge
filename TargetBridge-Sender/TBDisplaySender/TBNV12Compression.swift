import Compression
import Foundation

enum TBNV12ChecksumPolicy {
    case disabled
    case fnv64
}

enum TBNV12Compression {
    static let tileSize = 64
    static let maxTileRuns = 4096

    struct PacketResult {
        let packet: Data
        let rawBytes: Int
        let wireBytes: Int
        let copyNanoseconds: UInt64
        let compressionNanoseconds: UInt64
        let checksumNanoseconds: UInt64
        let packetNanoseconds: UInt64
        let regionPixels: Int
        let runCount: Int
    }

    struct TileRun: Equatable {
        let tileX: Int
        let tileY: Int
        let tileCountX: Int
        let pixelHeight: Int
        let dataOffset: Int
        let dataLength: Int

        var x: Int { tileX * TBNV12Compression.tileSize }
        var y: Int { tileY * TBNV12Compression.tileSize }
        var pixelWidth: Int {
            tileCountX * TBNV12Compression.tileSize
        }
    }

    struct Decoded {
        let y: Data
        let uv: Data
        let width: Int
        let height: Int
        let yStride: Int
        let uvStride: Int
    }

    struct DecodedRegion {
        let raw: Data
        let width: Int
        let height: Int
        let yStride: Int
        let uvStride: Int
        let x: Int
        let y: Int
        let regionWidth: Int
        let regionHeight: Int
    }

    struct DecodedTileRuns {
        let raw: Data
        let width: Int
        let height: Int
        let runs: [TileRun]
    }

    static func tileRuns(
        dirtyTiles: Set<Int>,
        width: Int,
        height: Int
    ) -> [TileRun]? {
        guard width > 0, height > 0,
              width % tileSize == 0, height % tileSize == 0,
              !dirtyTiles.isEmpty
        else {
            return nil
        }
        let tilesWide = width / tileSize
        let tilesHigh = height / tileSize
        guard dirtyTiles.allSatisfy({
            $0 >= 0 && $0 < tilesWide * tilesHigh
        }) else {
            return nil
        }
        var runs: [TileRun] = []
        var dataOffset = 0
        for tileY in 0..<tilesHigh {
            var tileX = 0
            while tileX < tilesWide {
                guard dirtyTiles.contains(tileY * tilesWide + tileX) else {
                    tileX += 1
                    continue
                }
                let startX = tileX
                while tileX < tilesWide,
                      dirtyTiles.contains(tileY * tilesWide + tileX) {
                    tileX += 1
                }
                let tileCountX = tileX - startX
                let dataLength =
                    tileCountX * tileSize * tileSize * 3 / 2
                runs.append(
                    TileRun(
                        tileX: startX,
                        tileY: tileY,
                        tileCountX: tileCountX,
                        pixelHeight: tileSize,
                        dataOffset: dataOffset,
                        dataLength: dataLength
                    )
                )
                dataOffset += dataLength
                guard runs.count <= maxTileRuns else { return nil }
            }
        }
        return runs.isEmpty ? nil : runs
    }

    static func tileRunCount(
        dirtyTiles: Set<Int>,
        width: Int,
        height: Int
    ) -> Int? {
        tileRuns(
            dirtyTiles: dirtyTiles,
            width: width,
            height: height
        )?.count
    }

    static func makePacket(
        y: Data,
        uv: Data,
        width: Int,
        height: Int,
        yStride: Int,
        uvStride: Int,
        checksumPolicy: TBNV12ChecksumPolicy = .disabled
    ) -> PacketResult? {
        guard width > 0, height > 0, width % 2 == 0, height % 2 == 0,
              y.count == yStride * height,
              uv.count == uvStride * (height / 2)
        else { return nil }
        let copyStarted = DispatchTime.now().uptimeNanoseconds
        var raw = Data(capacity: y.count + uv.count)
        raw.append(y)
        raw.append(uv)
        let copyFinished = DispatchTime.now().uptimeNanoseconds
        let capacity = raw.count + 64 * 1024
        var compressed = Data(count: capacity)
        let compressionStarted = copyFinished
        let size = raw.withUnsafeBytes { source in
            compressed.withUnsafeMutableBytes { destination in
                guard let src = source.baseAddress?
                    .assumingMemoryBound(to: UInt8.self),
                    let dst = destination.baseAddress?
                    .assumingMemoryBound(to: UInt8.self)
                else {
                    return 0
                }
                return compression_encode_buffer(
                    dst, capacity, src, raw.count, nil, COMPRESSION_LZ4
                )
            }
        }
        let compressionFinished = DispatchTime.now().uptimeNanoseconds
        guard size > 0 else { return nil }
        compressed.count = size
        let checksumStarted = DispatchTime.now().uptimeNanoseconds
        let checksumValue = checksumPolicy == .fnv64 ? checksum(raw) : 0
        let checksumFinished = DispatchTime.now().uptimeNanoseconds
        let packetStarted = checksumFinished
        var payload = Data(capacity: 38 + size)
        payload.append(2)
        payload.append(1)
        TBMonitorProtocol.appendBE32(&payload, UInt32(width))
        TBMonitorProtocol.appendBE32(&payload, UInt32(height))
        TBMonitorProtocol.appendBE32(&payload, UInt32(yStride))
        TBMonitorProtocol.appendBE32(&payload, UInt32(uvStride))
        TBMonitorProtocol.appendBE32(&payload, UInt32(y.count))
        TBMonitorProtocol.appendBE32(&payload, UInt32(uv.count))
        TBMonitorProtocol.appendBE32(&payload, UInt32(size))
        TBMonitorProtocol.appendBE64(&payload, checksumValue)
        payload.append(compressed)
        let packet = TBMonitorProtocol.makePacket(
            type: .rawFrame, payload: payload
        )
        let packetFinished = DispatchTime.now().uptimeNanoseconds
        guard raw.count + 17 - packet.count >= 4 * 1024 else { return nil }
        return PacketResult(
            packet: packet,
            rawBytes: raw.count,
            wireBytes: packet.count,
            copyNanoseconds: copyFinished - copyStarted,
            compressionNanoseconds: compressionFinished - compressionStarted,
            checksumNanoseconds: checksumFinished - checksumStarted,
            packetNanoseconds: packetFinished - packetStarted,
            regionPixels: width * height,
            runCount: 0
        )
    }

    static func makeRegionPacket(
        yBase: UnsafeRawPointer,
        uvBase: UnsafeRawPointer,
        width: Int,
        height: Int,
        yStride: Int,
        uvStride: Int,
        x: Int,
        y: Int,
        regionWidth: Int,
        regionHeight: Int,
        checksumPolicy: TBNV12ChecksumPolicy = .disabled
    ) -> PacketResult? {
        guard x >= 0, y >= 0, regionWidth > 0, regionHeight > 0,
              x % 2 == 0, y % 2 == 0, regionWidth % 2 == 0,
              regionHeight % 2 == 0, x + regionWidth <= width,
              y + regionHeight <= height
        else {
            return nil
        }
        let copyStarted = DispatchTime.now().uptimeNanoseconds
        var raw = Data(capacity: regionWidth * regionHeight * 3 / 2)
        for row in 0..<regionHeight {
            raw.append(
                yBase.advanced(by: (y + row) * yStride + x)
                    .assumingMemoryBound(to: UInt8.self),
                count: regionWidth
            )
        }
        for row in 0..<(regionHeight / 2) {
            raw.append(
                uvBase.advanced(by: (y / 2 + row) * uvStride + x)
                    .assumingMemoryBound(to: UInt8.self),
                count: regionWidth
            )
        }
        let copyFinished = DispatchTime.now().uptimeNanoseconds
        let capacity = raw.count + 64 * 1024
        var compressed = Data(count: capacity)
        let compressionStarted = copyFinished
        let size = raw.withUnsafeBytes { source in
            compressed.withUnsafeMutableBytes { destination in
                guard let src = source.baseAddress?
                    .assumingMemoryBound(to: UInt8.self),
                    let dst = destination.baseAddress?
                    .assumingMemoryBound(to: UInt8.self)
                else {
                    return 0
                }
                return compression_encode_buffer(
                    dst, capacity, src, raw.count, nil, COMPRESSION_LZ4
                )
            }
        }
        let compressionFinished = DispatchTime.now().uptimeNanoseconds
        guard size > 0 else { return nil }
        compressed.count = size
        let checksumStarted = DispatchTime.now().uptimeNanoseconds
        let checksumValue = checksumPolicy == .fnv64 ? checksum(raw) : 0
        let checksumFinished = DispatchTime.now().uptimeNanoseconds
        let packetStarted = checksumFinished
        var payload = Data(capacity: 54 + size)
        payload.append(3)
        payload.append(1)
        for value in [
            width, height, yStride, uvStride, x, y,
            regionWidth, regionHeight,
            regionWidth * regionHeight,
            regionWidth * regionHeight / 2,
            size
        ] {
            TBMonitorProtocol.appendBE32(&payload, UInt32(value))
        }
        TBMonitorProtocol.appendBE64(&payload, checksumValue)
        payload.append(compressed)
        let packet = TBMonitorProtocol.makePacket(
            type: .rawFrame, payload: payload
        )
        let packetFinished = DispatchTime.now().uptimeNanoseconds
        return PacketResult(
            packet: packet,
            rawBytes: raw.count,
            wireBytes: packet.count,
            copyNanoseconds: copyFinished - copyStarted,
            compressionNanoseconds: compressionFinished - compressionStarted,
            checksumNanoseconds: checksumFinished - checksumStarted,
            packetNanoseconds: packetFinished - packetStarted,
            regionPixels: regionWidth * regionHeight,
            runCount: 1
        )
    }

    static func makeTileRunPacket(
        yBase: UnsafeRawPointer,
        uvBase: UnsafeRawPointer,
        width: Int,
        height: Int,
        yStride: Int,
        uvStride: Int,
        dirtyTiles: Set<Int>,
        checksumPolicy: TBNV12ChecksumPolicy = .disabled
    ) -> PacketResult? {
        guard width > 0, height > 0,
              width % tileSize == 0, height % tileSize == 0,
              yStride >= width, uvStride >= width,
              !dirtyTiles.isEmpty
        else {
            return nil
        }

        let tilesWide = width / tileSize
        let tilesHigh = height / tileSize
        guard dirtyTiles.allSatisfy({
            $0 >= 0 && $0 < tilesWide * tilesHigh
        }) else {
            return nil
        }

        var raw = Data()
        var runs: [TileRun] = []
        let copyStarted = DispatchTime.now().uptimeNanoseconds
        for tileY in 0..<tilesHigh {
            var tileX = 0
            while tileX < tilesWide {
                let tileIndex = tileY * tilesWide + tileX
                guard dirtyTiles.contains(tileIndex) else {
                    tileX += 1
                    continue
                }
                let startX = tileX
                while tileX < tilesWide,
                      dirtyTiles.contains(tileY * tilesWide + tileX) {
                    tileX += 1
                }
                let tileCountX = tileX - startX
                let pixelWidth = tileCountX * tileSize
                let pixelHeight = tileSize
                let dataOffset = raw.count
                for row in 0..<pixelHeight {
                    raw.append(
                        yBase.advanced(
                            by: (tileY * tileSize + row) * yStride +
                                startX * tileSize
                        ).assumingMemoryBound(to: UInt8.self),
                        count: pixelWidth
                    )
                }
                for row in 0..<(pixelHeight / 2) {
                    raw.append(
                        uvBase.advanced(
                            by: (tileY * tileSize / 2 + row) * uvStride +
                                startX * tileSize
                        ).assumingMemoryBound(to: UInt8.self),
                        count: pixelWidth
                    )
                }
                runs.append(
                    TileRun(
                        tileX: startX,
                        tileY: tileY,
                        tileCountX: tileCountX,
                        pixelHeight: pixelHeight,
                        dataOffset: dataOffset,
                        dataLength: raw.count - dataOffset
                    )
                )
                guard runs.count <= maxTileRuns else { return nil }
            }
        }
        guard !runs.isEmpty else { return nil }
        let copyFinished = DispatchTime.now().uptimeNanoseconds

        let capacity = raw.count + 64 * 1024
        var compressed = Data(count: capacity)
        let compressionStarted = copyFinished
        let size = raw.withUnsafeBytes { source in
            compressed.withUnsafeMutableBytes { destination in
                guard let src = source.baseAddress?
                    .assumingMemoryBound(to: UInt8.self),
                    let dst = destination.baseAddress?
                    .assumingMemoryBound(to: UInt8.self)
                else {
                    return 0
                }
                return compression_encode_buffer(
                    dst, capacity, src, raw.count, nil, COMPRESSION_LZ4
                )
            }
        }
        let compressionFinished = DispatchTime.now().uptimeNanoseconds
        guard size > 0 else { return nil }
        compressed.count = size
        let checksumStarted = compressionFinished
        let checksumValue = checksumPolicy == .fnv64 ? checksum(raw) : 0
        let checksumFinished = DispatchTime.now().uptimeNanoseconds
        let packetStarted = checksumFinished
        var payload = Data(capacity: 32 + runs.count * 16 + size)
        payload.append(4)
        payload.append(1)
        TBMonitorProtocol.appendBE16(&payload, UInt16(tileSize))
        TBMonitorProtocol.appendBE32(&payload, UInt32(width))
        TBMonitorProtocol.appendBE32(&payload, UInt32(height))
        TBMonitorProtocol.appendBE32(&payload, UInt32(runs.count))
        TBMonitorProtocol.appendBE32(&payload, UInt32(raw.count))
        TBMonitorProtocol.appendBE32(&payload, UInt32(size))
        TBMonitorProtocol.appendBE64(&payload, checksumValue)
        for run in runs {
            TBMonitorProtocol.appendBE16(&payload, UInt16(run.tileX))
            TBMonitorProtocol.appendBE16(&payload, UInt16(run.tileY))
            TBMonitorProtocol.appendBE16(&payload, UInt16(run.tileCountX))
            TBMonitorProtocol.appendBE16(&payload, UInt16(run.pixelHeight))
            TBMonitorProtocol.appendBE32(&payload, UInt32(run.dataOffset))
            TBMonitorProtocol.appendBE32(&payload, UInt32(run.dataLength))
        }
        payload.append(compressed)
        let packet = TBMonitorProtocol.makePacket(
            type: .rawFrame, payload: payload
        )
        let packetFinished = DispatchTime.now().uptimeNanoseconds
        return PacketResult(
            packet: packet,
            rawBytes: raw.count,
            wireBytes: packet.count,
            copyNanoseconds: copyFinished - copyStarted,
            compressionNanoseconds: compressionFinished - compressionStarted,
            checksumNanoseconds: checksumFinished - checksumStarted,
            packetNanoseconds: packetFinished - packetStarted,
            regionPixels: dirtyTiles.count * tileSize * tileSize,
            runCount: runs.count
        )
    }

    static func makeTileRunPacket(
        packedBytes: UnsafeRawPointer,
        packedLength: Int,
        width: Int,
        height: Int,
        runs: [TileRun],
        packingNanoseconds: UInt64,
        checksumPolicy: TBNV12ChecksumPolicy = .disabled
    ) -> PacketResult? {
        guard packedLength > 0,
              packedLength == runs.reduce(0, { $0 + $1.dataLength }),
              !runs.isEmpty,
              runs.count <= maxTileRuns
        else {
            return nil
        }
        let capacity = packedLength + 64 * 1024
        var compressed = Data(count: capacity)
        let compressionStarted = DispatchTime.now().uptimeNanoseconds
        let size = compressed.withUnsafeMutableBytes { destination in
            guard let dst = destination.baseAddress?
                .assumingMemoryBound(to: UInt8.self)
            else {
                return 0
            }
            return compression_encode_buffer(
                dst,
                capacity,
                packedBytes.assumingMemoryBound(to: UInt8.self),
                packedLength,
                nil,
                COMPRESSION_LZ4
            )
        }
        let compressionFinished = DispatchTime.now().uptimeNanoseconds
        guard size > 0 else { return nil }
        compressed.count = size
        let checksumStarted = compressionFinished
        let checksumValue = checksumPolicy == .fnv64
            ? TBChecksum64(packedBytes, packedLength)
            : 0
        let checksumFinished = DispatchTime.now().uptimeNanoseconds
        let packetStarted = checksumFinished
        var payload = Data(capacity: 32 + runs.count * 16 + size)
        payload.append(4)
        payload.append(1)
        TBMonitorProtocol.appendBE16(&payload, UInt16(tileSize))
        TBMonitorProtocol.appendBE32(&payload, UInt32(width))
        TBMonitorProtocol.appendBE32(&payload, UInt32(height))
        TBMonitorProtocol.appendBE32(&payload, UInt32(runs.count))
        TBMonitorProtocol.appendBE32(&payload, UInt32(packedLength))
        TBMonitorProtocol.appendBE32(&payload, UInt32(size))
        TBMonitorProtocol.appendBE64(&payload, checksumValue)
        for run in runs {
            TBMonitorProtocol.appendBE16(&payload, UInt16(run.tileX))
            TBMonitorProtocol.appendBE16(&payload, UInt16(run.tileY))
            TBMonitorProtocol.appendBE16(&payload, UInt16(run.tileCountX))
            TBMonitorProtocol.appendBE16(&payload, UInt16(run.pixelHeight))
            TBMonitorProtocol.appendBE32(&payload, UInt32(run.dataOffset))
            TBMonitorProtocol.appendBE32(&payload, UInt32(run.dataLength))
        }
        payload.append(compressed)
        let packet = TBMonitorProtocol.makePacket(
            type: .rawFrame, payload: payload
        )
        let packetFinished = DispatchTime.now().uptimeNanoseconds
        let regionPixels = runs.reduce(0) {
            $0 + $1.pixelWidth * $1.pixelHeight
        }
        return PacketResult(
            packet: packet,
            rawBytes: packedLength,
            wireBytes: packet.count,
            copyNanoseconds: packingNanoseconds,
            compressionNanoseconds: compressionFinished - compressionStarted,
            checksumNanoseconds: checksumFinished - checksumStarted,
            packetNanoseconds: packetFinished - packetStarted,
            regionPixels: regionPixels,
            runCount: runs.count
        )
    }

    static func decodeRegionPacket(_ packet: Data) -> DecodedRegion? {
        guard packet.count >= 59,
              packet[4] == TBMonitorPacketType.rawFrame.rawValue,
              packet[5] == 3,
              packet[6] == 1
        else {
            return nil
        }
        let values = stride(from: 7, through: 47, by: 4).map {
            Int(TBMonitorProtocol.readBE32(packet, offset: $0))
        }
        let checksumValue = TBMonitorProtocol.readBE64(packet, offset: 51)
        let compressedStart = 59
        let rawLength = values[8] + values[9]
        guard values[6] > 0, values[7] > 0,
              values[8] == values[6] * values[7],
              values[9] == values[6] * values[7] / 2,
              compressedStart + values[10] == packet.count
        else {
            return nil
        }
        var raw = Data(count: rawLength)
        let decoded = packet.withUnsafeBytes { sourceBytes in
            raw.withUnsafeMutableBytes { destinationBytes in
                guard let source = sourceBytes.baseAddress?
                    .advanced(by: compressedStart)
                    .assumingMemoryBound(to: UInt8.self),
                    let destination = destinationBytes.baseAddress?
                    .assumingMemoryBound(to: UInt8.self)
                else {
                    return 0
                }
                return compression_decode_buffer(
                    destination,
                    rawLength,
                    source,
                    values[10],
                    nil,
                    COMPRESSION_LZ4
                )
            }
        }
        guard decoded == rawLength,
              checksumValue == 0 || checksum(raw) == checksumValue
        else {
            return nil
        }
        return DecodedRegion(
            raw: raw,
            width: values[0],
            height: values[1],
            yStride: values[2],
            uvStride: values[3],
            x: values[4],
            y: values[5],
            regionWidth: values[6],
            regionHeight: values[7]
        )
    }

    static func decodeTileRunPacket(_ packet: Data) -> DecodedTileRuns? {
        guard packet.count >= 37,
              packet[4] == TBMonitorPacketType.rawFrame.rawValue,
              packet[5] == 4,
              packet[6] == 1,
              TBMonitorProtocol.readBE16(packet, offset: 7) == tileSize
        else {
            return nil
        }
        let width = Int(TBMonitorProtocol.readBE32(packet, offset: 9))
        let height = Int(TBMonitorProtocol.readBE32(packet, offset: 13))
        let runCount = Int(TBMonitorProtocol.readBE32(packet, offset: 17))
        let rawLength = Int(TBMonitorProtocol.readBE32(packet, offset: 21))
        let compressedLength = Int(
            TBMonitorProtocol.readBE32(packet, offset: 25)
        )
        let expectedChecksum = TBMonitorProtocol.readBE64(packet, offset: 29)
        guard width > 0, height > 0,
              width % tileSize == 0, height % tileSize == 0,
              runCount > 0, runCount <= maxTileRuns,
              rawLength > 0
        else {
            return nil
        }
        let descriptorStart = 37
        let compressedStart = descriptorStart + runCount * 16
        guard compressedStart <= packet.count,
              compressedLength == packet.count - compressedStart
        else {
            return nil
        }
        let tilesWide = width / tileSize
        let tilesHigh = height / tileSize
        var runs: [TileRun] = []
        var expectedOffset = 0
        var previousTileY = -1
        var previousTileEndX = 0
        for index in 0..<runCount {
            let offset = descriptorStart + index * 16
            let tileX = Int(TBMonitorProtocol.readBE16(packet, offset: offset))
            let tileY = Int(
                TBMonitorProtocol.readBE16(packet, offset: offset + 2)
            )
            let tileCountX = Int(
                TBMonitorProtocol.readBE16(packet, offset: offset + 4)
            )
            let pixelHeight = Int(
                TBMonitorProtocol.readBE16(packet, offset: offset + 6)
            )
            let dataOffset = Int(
                TBMonitorProtocol.readBE32(packet, offset: offset + 8)
            )
            let dataLength = Int(
                TBMonitorProtocol.readBE32(packet, offset: offset + 12)
            )
            let expectedLength =
                tileCountX * tileSize * pixelHeight * 3 / 2
            guard tileCountX > 0,
                  tileY < tilesHigh,
                  tileX + tileCountX <= tilesWide,
                  pixelHeight == tileSize,
                  dataOffset == expectedOffset,
                  dataLength == expectedLength,
                  dataOffset <= rawLength,
                  dataLength <= rawLength - dataOffset,
                  tileY > previousTileY ||
                    (tileY == previousTileY && tileX >= previousTileEndX)
            else {
                return nil
            }
            runs.append(
                TileRun(
                    tileX: tileX,
                    tileY: tileY,
                    tileCountX: tileCountX,
                    pixelHeight: pixelHeight,
                    dataOffset: dataOffset,
                    dataLength: dataLength
                )
            )
            expectedOffset += dataLength
            previousTileY = tileY
            previousTileEndX = tileX + tileCountX
        }
        guard expectedOffset == rawLength else { return nil }
        var raw = Data(count: rawLength)
        let decoded = packet.withUnsafeBytes { sourceBytes in
            raw.withUnsafeMutableBytes { destinationBytes in
                guard let source = sourceBytes.baseAddress?
                    .advanced(by: compressedStart)
                    .assumingMemoryBound(to: UInt8.self),
                    let destination = destinationBytes.baseAddress?
                    .assumingMemoryBound(to: UInt8.self)
                else {
                    return 0
                }
                return compression_decode_buffer(
                    destination,
                    rawLength,
                    source,
                    compressedLength,
                    nil,
                    COMPRESSION_LZ4
                )
            }
        }
        guard decoded == rawLength,
              expectedChecksum == 0 || checksum(raw) == expectedChecksum
        else {
            return nil
        }
        return DecodedTileRuns(
            raw: raw,
            width: width,
            height: height,
            runs: runs
        )
    }

    static func decodePacket(_ packet: Data) -> Decoded? {
        guard packet.count >= 43,
              packet[4] == TBMonitorPacketType.rawFrame.rawValue,
              packet[5] == 2,
              packet[6] == 1
        else {
            return nil
        }
        let width = Int(TBMonitorProtocol.readBE32(packet, offset: 7))
        let height = Int(TBMonitorProtocol.readBE32(packet, offset: 11))
        let yStride = Int(TBMonitorProtocol.readBE32(packet, offset: 15))
        let uvStride = Int(TBMonitorProtocol.readBE32(packet, offset: 19))
        let ySize = Int(TBMonitorProtocol.readBE32(packet, offset: 23))
        let uvSize = Int(TBMonitorProtocol.readBE32(packet, offset: 27))
        let compressedSize = Int(TBMonitorProtocol.readBE32(packet, offset: 31))
        let expectedChecksum = TBMonitorProtocol.readBE64(packet, offset: 35)
        let compressedStart = 43
        guard width > 0, height > 0,
              ySize == yStride * height,
              uvSize == uvStride * (height / 2),
              compressedStart + compressedSize == packet.count
        else {
            return nil
        }
        let rawLength = ySize + uvSize
        var raw = Data(count: rawLength)
        let decoded = packet.withUnsafeBytes { packetBytes in
            raw.withUnsafeMutableBytes { rawBytes in
                guard let source = packetBytes.baseAddress?
                    .advanced(by: compressedStart)
                    .assumingMemoryBound(to: UInt8.self),
                    let destination = rawBytes.baseAddress?
                    .assumingMemoryBound(to: UInt8.self)
                else {
                    return 0
                }
                return compression_decode_buffer(
                    destination,
                    rawLength,
                    source,
                    compressedSize,
                    nil,
                    COMPRESSION_LZ4
                )
            }
        }
        guard decoded == rawLength,
              expectedChecksum == 0 || checksum(raw) == expectedChecksum
        else {
            return nil
        }
        return Decoded(
            y: raw.subdata(in: 0..<ySize),
            uv: raw.subdata(in: ySize..<raw.count),
            width: width,
            height: height,
            yStride: yStride,
            uvStride: uvStride
        )
    }

    static func checksum(_ data: Data) -> UInt64 {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else {
                return UInt64(14_695_981_039_346_656_037)
            }
            return TBChecksum64(base, data.count)
        }
    }
}
