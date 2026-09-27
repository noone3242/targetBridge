import Compression
import Foundation

enum TBNV12Compression {
    struct PacketResult {
        let packet: Data
        let rawBytes: Int
        let wireBytes: Int
        let copyNanoseconds: UInt64
        let compressionNanoseconds: UInt64
        let regionPixels: Int
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

    static func makePacket(
        y: Data,
        uv: Data,
        width: Int,
        height: Int,
        yStride: Int,
        uvStride: Int
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
                guard let src = source.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let dst = destination.baseAddress?.assumingMemoryBound(to: UInt8.self)
                else { return 0 }
                return compression_encode_buffer(
                    dst, capacity, src, raw.count, nil, COMPRESSION_LZ4
                )
            }
        }
        let compressionFinished = DispatchTime.now().uptimeNanoseconds
        guard size > 0 else { return nil }
        compressed.count = size
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
        TBMonitorProtocol.appendBE64(&payload, checksum(raw))
        payload.append(compressed)
        let packet = TBMonitorProtocol.makePacket(type: .rawFrame, payload: payload)
        guard raw.count + 17 - packet.count >= 4 * 1024 else { return nil }
        return PacketResult(
            packet: packet,
            rawBytes: raw.count,
            wireBytes: packet.count,
            copyNanoseconds: copyFinished - copyStarted,
            compressionNanoseconds: compressionFinished - compressionStarted,
            regionPixels: width * height
        )
    }

    static func makeRegionPacket(
        yBase: UnsafeRawPointer, uvBase: UnsafeRawPointer,
        width: Int, height: Int, yStride: Int, uvStride: Int,
        x: Int, y: Int, regionWidth: Int, regionHeight: Int
    ) -> PacketResult? {
        guard x >= 0, y >= 0, regionWidth > 0, regionHeight > 0,
              x % 2 == 0, y % 2 == 0, regionWidth % 2 == 0,
              regionHeight % 2 == 0, x + regionWidth <= width,
              y + regionHeight <= height else { return nil }
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
        let size = raw.withUnsafeBytes { src in
            compressed.withUnsafeMutableBytes { dst in
                guard let s = src.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let d = dst.baseAddress?.assumingMemoryBound(to: UInt8.self)
                else { return 0 }
                return compression_encode_buffer(
                    d, capacity, s, raw.count, nil, COMPRESSION_LZ4
                )
            }
        }
        let compressionFinished = DispatchTime.now().uptimeNanoseconds
        guard size > 0 else { return nil }
        compressed.count = size
        var payload = Data(capacity: 54 + size)
        payload.append(3); payload.append(1)
        for value in [width, height, yStride, uvStride, x, y,
                      regionWidth, regionHeight,
                      regionWidth * regionHeight,
                      regionWidth * regionHeight / 2, size] {
            TBMonitorProtocol.appendBE32(&payload, UInt32(value))
        }
        TBMonitorProtocol.appendBE64(&payload, checksum(raw))
        payload.append(compressed)
        let packet = TBMonitorProtocol.makePacket(type: .rawFrame, payload: payload)
        return PacketResult(
            packet: packet,
            rawBytes: raw.count,
            wireBytes: packet.count,
            copyNanoseconds: copyFinished - copyStarted,
            compressionNanoseconds: compressionFinished - compressionStarted,
            regionPixels: regionWidth * regionHeight
        )
    }

    static func decodeRegionPacket(_ packet: Data) -> DecodedRegion? {
        guard packet.count >= 59, packet[4] == TBMonitorPacketType.rawFrame.rawValue,
              packet[5] == 3, packet[6] == 1 else { return nil }
        let values = stride(from: 7, through: 47, by: 4).map {
            Int(TBMonitorProtocol.readBE32(packet, offset: $0))
        }
        let checksumValue = TBMonitorProtocol.readBE64(packet, offset: 51)
        let compressedStart = 59
        let rawLength = values[8] + values[9]
        guard values[6] > 0, values[7] > 0,
              values[8] == values[6] * values[7],
              values[9] == values[6] * values[7] / 2,
              compressedStart + values[10] == packet.count else { return nil }
        var raw = Data(count: rawLength)
        let decoded = packet.withUnsafeBytes { sourceBytes in
            raw.withUnsafeMutableBytes { destinationBytes in
                guard let source = sourceBytes.baseAddress?
                    .advanced(by: compressedStart).assumingMemoryBound(to: UInt8.self),
                      let destination = destinationBytes.baseAddress?
                    .assumingMemoryBound(to: UInt8.self) else { return 0 }
                return compression_decode_buffer(
                    destination, rawLength, source, values[10], nil, COMPRESSION_LZ4
                )
            }
        }
        guard decoded == rawLength, checksum(raw) == checksumValue else { return nil }
        return DecodedRegion(
            raw: raw, width: values[0], height: values[1],
            yStride: values[2], uvStride: values[3],
            x: values[4], y: values[5],
            regionWidth: values[6], regionHeight: values[7]
        )
    }

    static func decodePacket(_ packet: Data) -> Decoded? {
        guard packet.count >= 43,
              packet[4] == TBMonitorPacketType.rawFrame.rawValue,
              packet[5] == 2, packet[6] == 1
        else { return nil }
        let width = Int(TBMonitorProtocol.readBE32(packet, offset: 7))
        let height = Int(TBMonitorProtocol.readBE32(packet, offset: 11))
        let yStride = Int(TBMonitorProtocol.readBE32(packet, offset: 15))
        let uvStride = Int(TBMonitorProtocol.readBE32(packet, offset: 19))
        let ySize = Int(TBMonitorProtocol.readBE32(packet, offset: 23))
        let uvSize = Int(TBMonitorProtocol.readBE32(packet, offset: 27))
        let compressedSize = Int(TBMonitorProtocol.readBE32(packet, offset: 31))
        let expectedChecksum = TBMonitorProtocol.readBE64(packet, offset: 35)
        let compressedStart = 43
        guard width > 0, height > 0, ySize == yStride * height,
              uvSize == uvStride * (height / 2),
              compressedStart + compressedSize == packet.count
        else { return nil }
        let rawLength = ySize + uvSize
        var raw = Data(count: rawLength)
        let decoded = packet.withUnsafeBytes { packetBytes in
            raw.withUnsafeMutableBytes { rawBytes in
                guard let source = packetBytes.baseAddress?
                    .advanced(by: compressedStart)
                    .assumingMemoryBound(to: UInt8.self),
                    let destination = rawBytes.baseAddress?
                    .assumingMemoryBound(to: UInt8.self)
                else { return 0 }
                return compression_decode_buffer(
                    destination, rawLength, source, compressedSize, nil,
                    COMPRESSION_LZ4
                )
            }
        }
        guard decoded == rawLength, checksum(raw) == expectedChecksum else {
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
        var hash = UInt64(14_695_981_039_346_656_037)
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}
