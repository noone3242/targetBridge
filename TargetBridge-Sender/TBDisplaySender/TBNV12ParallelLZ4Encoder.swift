import Darwin
import Foundation

/// Splits a liblz4 encode across a few performance cores.
///
/// Apple `COMPRESSION_LZ4` frames are a sequence of independent blocks whose
/// decoded sizes may differ, so the source is cut into `threadCount` equal
/// chunks, each chunk is encoded into its own run of blocks concurrently, and
/// the runs are concatenated before a single "bv4$" end marker. The result is
/// an ordinary frame that the Receiver decodes unchanged.
///
/// Chunk 0 is written straight into the destination; the others go to
/// preallocated side buffers and are copied in after the join, so the extra
/// copy only touches compressed bytes. `DispatchQueue.concurrentPerform` runs
/// one chunk on the calling thread and inherits its QoS, so the helpers stay
/// on performance cores alongside the pipeline queue.
///
/// Inputs below `parallelThreshold`, a thread count of 1 and the Apple encoder
/// take the serial path, which produces the same bytes as
/// `TBNV12LZ4Encoder.encode`.
///
/// Not thread-safe: call `encode` from one queue at a time.
final class TBNV12ParallelLZ4Encoder: @unchecked Sendable {
    static let parallelThreshold = 1 << 20
    static let defaultThreadCount = 2

    let encoder: TBNV12LZ4Encoder
    let threadCount: Int

    private let states: [UnsafeMutableRawPointer]
    private var sideBuffers: [UnsafeMutableRawPointer] = []
    private var sideCapacity = 0
    private let results: UnsafeMutablePointer<Int>

    /// Side buffers are allocated and prefaulted on the first large encode
    /// and grow when a larger input arrives.
    init(encoder: TBNV12LZ4Encoder, threadCount: Int) {
        self.encoder = encoder
        if case .liblz4 = encoder {
            self.threadCount = max(1, threadCount)
        } else {
            self.threadCount = 1
        }
        let scratchSize = encoder.scratchSize
        states = (0..<self.threadCount).map { _ in
            let state = UnsafeMutableRawPointer.allocate(
                byteCount: scratchSize, alignment: 16
            )
            memset(state, 0, scratchSize)
            return state
        }
        results = .allocate(capacity: self.threadCount)
        results.initialize(repeating: 0, count: self.threadCount)
    }

    deinit {
        for state in states {
            state.deallocate()
        }
        for buffer in sideBuffers {
            buffer.deallocate()
        }
        results.deallocate()
    }

    var diagnosticName: String {
        Self.diagnosticName(encoder: encoder, threadCount: threadCount)
    }

    /// For example "liblz4-a32-t2"; the thread suffix is omitted when the
    /// encode stays on one thread (always the case for Apple LZ4).
    static func diagnosticName(
        encoder: TBNV12LZ4Encoder, threadCount: Int
    ) -> String {
        guard case .liblz4 = encoder, threadCount > 1 else {
            return encoder.diagnosticName
        }
        return "\(encoder.diagnosticName)-t\(threadCount)"
    }

    /// Default thread count: `TB_NV12_LZ4_THREADS=<n>` when set (1 disables
    /// the split), otherwise 2 on machines with at least four performance
    /// cores and 1 elsewhere. Never more than the performance core count.
    static func threadCount(
        environment: [String: String],
        performanceCores: Int = performanceCoreCount()
    ) -> Int {
        let cores = max(1, performanceCores)
        if let value = environment["TB_NV12_LZ4_THREADS"].flatMap({ Int($0) }),
           value > 0 {
            return min(value, cores)
        }
        return cores >= 4 ? min(defaultThreadCount, cores) : 1
    }

    static func performanceCoreCount() -> Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &value, &size, nil, 0) == 0,
           value > 0 {
            return Int(value)
        }
        return ProcessInfo.processInfo.activeProcessorCount
    }

    /// Encodes `length` bytes from `source` into `destination`. Returns the
    /// encoded size, or 0 on failure.
    func encode(
        destination: UnsafeMutablePointer<UInt8>,
        capacity: Int,
        source: UnsafePointer<UInt8>,
        length: Int
    ) -> Int {
        guard threadCount > 1, length >= Self.parallelThreshold,
              case .liblz4(let acceleration) = encoder
        else {
            return encoder.encode(
                destination: destination,
                capacity: capacity,
                source: source,
                length: length,
                scratch: states[0]
            )
        }
        let chunkCount = threadCount
        let chunkLength = (length + chunkCount - 1) / chunkCount
        reserveSideBuffers(forChunkLength: chunkLength)
        let blockSize = TBNV12LZ4Encoder.liblz4BlockSize
        let accel = Int32(clamping: acceleration)
        let states = states
        let sideBuffers = sideBuffers
        let sideCapacity = sideCapacity
        let results = results
        DispatchQueue.concurrentPerform(iterations: chunkCount) { index in
            let start = index * chunkLength
            let count = min(chunkLength, length - start)
            guard count > 0 else {
                results[index] = 0
                return
            }
            let output = index == 0
                ? destination
                : sideBuffers[index - 1].assumingMemoryBound(to: UInt8.self)
            results[index] = TBLZ4EncodeAppleBlocks(
                output,
                index == 0 ? capacity : sideCapacity,
                source.advanced(by: start),
                count,
                states[index],
                accel,
                blockSize
            )
        }
        var size = results[0]
        guard size > 0 else { return 0 }
        for index in 1..<chunkCount {
            let chunkSize = results[index]
            guard index * chunkLength < length else { break }
            guard chunkSize > 0, capacity - size >= chunkSize else { return 0 }
            memcpy(destination.advanced(by: size), sideBuffers[index - 1], chunkSize)
            size += chunkSize
        }
        let end = TBLZ4WriteAppleFrameEnd(
            destination.advanced(by: size), capacity - size
        )
        return end == 0 ? 0 : size + end
    }

    private func reserveSideBuffers(forChunkLength chunkLength: Int) {
        let needed = TBLZ4AppleBlocksBound(
            chunkLength, TBNV12LZ4Encoder.liblz4BlockSize
        )
        guard needed > sideCapacity else { return }
        for buffer in sideBuffers {
            buffer.deallocate()
        }
        let pageSize = Int(getpagesize())
        sideBuffers = (1..<threadCount).map { _ in
            let buffer = UnsafeMutableRawPointer.allocate(
                byteCount: needed, alignment: pageSize
            )
            // Prefault so the first parallel frames do not pay page faults.
            memset(buffer, 0, needed)
            return buffer
        }
        sideCapacity = needed
    }
}
