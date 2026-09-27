import Compression
import Foundation

enum TBNV12Compression {
    struct Decoded {
        let y: Data
        let uv: Data
        let width: Int
        let height: Int
        let yStride: Int
        let uvStride: Int
    }

    static func makePacket(
        y: Data,
        uv: Data,
        width: Int,
        height: Int,
        yStride: Int,
        uvStride: Int
    ) -> Data? {
        guard width > 0, height > 0, width % 2 == 0, height % 2 == 0,
              y.count == yStride * height,
              uv.count == uvStride * (height / 2)
        else { return nil }
        var raw = Data(capacity: y.count + uv.count)
        raw.append(y)
        raw.append(uv)
        let capacity = raw.count + 64 * 1024
        var compressed = Data(count: capacity)
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
        return raw.count + 17 - packet.count >= 4 * 1024 ? packet : nil
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
