import Compression
import Foundation

/// LZ4 encoder for NV12 raw-frame payloads.
///
/// Both encoders emit Apple `COMPRESSION_LZ4` framing ("bv41" blocks ending in
/// "bv4$"), so the Receiver's `compression_decode_buffer` path decodes either
/// without changes. liblz4 trades a slightly lower compression ratio for a
/// faster encode on the Sender and a faster decode on the Receiver.
enum TBNV12LZ4Encoder: Equatable {
    case apple
    case liblz4(acceleration: Int)

    static let defaultAcceleration = 32
    /// Independent liblz4 blocks: large enough to keep ratio and decode speed
    /// close to a single block, small enough to stay near the block sizes
    /// Apple's own encoder produces.
    static let liblz4BlockSize = 1 << 20

    /// liblz4 by default; `TB_NV12_LIBLZ4=0` selects Apple LZ4 and
    /// `TB_NV12_LIBLZ4_ACCELERATION=<n>` overrides the acceleration.
    static func fromEnvironment(
        _ environment: [String: String]
    ) -> TBNV12LZ4Encoder {
        if environment["TB_NV12_LIBLZ4"] == "0" {
            return .apple
        }
        let acceleration = environment["TB_NV12_LIBLZ4_ACCELERATION"]
            .flatMap { Int($0) }
            .flatMap { $0 > 0 ? $0 : nil }
            ?? defaultAcceleration
        return .liblz4(acceleration: acceleration)
    }

    var diagnosticName: String {
        switch self {
        case .apple:
            return "apple"
        case .liblz4(let acceleration):
            return "liblz4-a\(acceleration)"
        }
    }

    var scratchSize: Int {
        switch self {
        case .apple:
            return max(1, compression_encode_scratch_buffer_size(COMPRESSION_LZ4))
        case .liblz4:
            return TBLZ4AppleFrameStateSize()
        }
    }

    /// Encodes `length` bytes from `source` into `destination`. Returns the
    /// encoded size, or 0 on failure. `scratch` must hold `scratchSize` bytes;
    /// when nil, a temporary one is allocated.
    func encode(
        destination: UnsafeMutablePointer<UInt8>,
        capacity: Int,
        source: UnsafePointer<UInt8>,
        length: Int,
        scratch: UnsafeMutableRawPointer?
    ) -> Int {
        guard let scratch else {
            let temporary = UnsafeMutableRawPointer.allocate(
                byteCount: scratchSize, alignment: 16
            )
            defer { temporary.deallocate() }
            return encode(
                destination: destination,
                capacity: capacity,
                source: source,
                length: length,
                scratch: temporary
            )
        }
        switch self {
        case .apple:
            return compression_encode_buffer(
                destination, capacity, source, length, scratch, COMPRESSION_LZ4
            )
        case .liblz4(let acceleration):
            return TBLZ4EncodeAppleFrame(
                destination, capacity, source, length, scratch,
                Int32(clamping: acceleration), Self.liblz4BlockSize
            )
        }
    }
}
