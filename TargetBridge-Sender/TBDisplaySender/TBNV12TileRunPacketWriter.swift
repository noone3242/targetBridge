import Foundation

/// Zero-copy builder for NV12 tile-run packets (raw frame format 4).
///
/// Produces packets byte-identical to `TBNV12Compression.makeTileRunPacket`
/// with the same encoder, but avoids its per-frame allocations and copies:
/// - dirty rows are memcpy'd into one preallocated, prefaulted staging buffer;
/// - the LZ4 scratch buffer (or liblz4 state) is allocated once and reused;
/// - the frame header, run table and LZ4 output are written in place into a
///   packet slot that is handed to the network as `Data(bytesNoCopy:)`.
///
/// A slot stays reserved until the last reference to its `Data` is released,
/// so a packet still owned by `NWConnection` is never overwritten. When every
/// slot is busy, `makeTileRunPacket` returns nil and callers fall back to
/// `TBNV12Compression.makeTileRunPacket`.
///
/// Not thread-safe: call `makeTileRunPacket` from one queue. Slot release may
/// happen on any thread and is guarded by `lock`.
final class TBNV12TileRunPacketWriter: @unchecked Sendable {
    static let slotCount = 2

    // [BE32 length][type] + format header + checksum.
    private static let fixedHeaderBytes = 5 + 32
    private static let runDescriptorBytes = 16

    let width: Int
    let height: Int
    let encoder: TBNV12LZ4Encoder

    private let rawCapacity: Int
    private let slotCapacity: Int
    private let raw: UnsafeMutableRawPointer
    private let scratch: UnsafeMutableRawPointer
    private let slots: [UnsafeMutableRawPointer]
    private var runs: [TBNV12Compression.TileRun] = []

    private let lock = NSLock()
    private var slotInUse: [Bool]

    init?(width: Int, height: Int, encoder: TBNV12LZ4Encoder = .apple) {
        let tileSize = TBNV12Compression.tileSize
        guard width > 0, height > 0,
              width % tileSize == 0, height % tileSize == 0
        else {
            return nil
        }
        self.width = width
        self.height = height
        self.encoder = encoder
        rawCapacity = width * height * 3 / 2
        // Both encoders store incompressible input as raw blocks with a small
        // per-block header (64 KiB or 1 MiB blocks), so this bound is never
        // exceeded.
        let compressedBound = rawCapacity + rawCapacity / 256 + 64 * 1024
        slotCapacity = Self.fixedHeaderBytes +
            TBNV12Compression.maxTileRuns * Self.runDescriptorBytes +
            compressedBound
        let pageSize = Int(getpagesize())
        raw = .allocate(byteCount: rawCapacity, alignment: pageSize)
        let scratchSize = encoder.scratchSize
        scratch = .allocate(byteCount: scratchSize, alignment: 16)
        let slotCapacity = slotCapacity
        slots = (0..<Self.slotCount).map { _ in
            .allocate(byteCount: slotCapacity, alignment: pageSize)
        }
        slotInUse = Array(repeating: false, count: Self.slotCount)
        // Prefault once so the first frames do not pay for page faults.
        memset(raw, 0, rawCapacity)
        memset(scratch, 0, scratchSize)
        for slot in slots {
            memset(slot, 0, slotCapacity)
        }
        runs.reserveCapacity(TBNV12Compression.maxTileRuns)
    }

    deinit {
        raw.deallocate()
        scratch.deallocate()
        for slot in slots {
            slot.deallocate()
        }
    }

    var availableSlotCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return slotInUse.filter { !$0 }.count
    }

    func makeTileRunPacket(
        yBase: UnsafeRawPointer,
        uvBase: UnsafeRawPointer,
        yStride: Int,
        uvStride: Int,
        dirtyTiles: Set<Int>,
        checksumPolicy: TBNV12ChecksumPolicy = .disabled
    ) -> TBNV12Compression.PacketResult? {
        let tileSize = TBNV12Compression.tileSize
        guard yStride >= width, uvStride >= width, !dirtyTiles.isEmpty else {
            return nil
        }
        let tilesWide = width / tileSize
        let tilesHigh = height / tileSize
        guard dirtyTiles.allSatisfy({
            $0 >= 0 && $0 < tilesWide * tilesHigh
        }) else {
            return nil
        }
        guard let slotIndex = acquireSlot() else { return nil }
        var handedOff = false
        defer {
            if !handedOff { releaseSlot(slotIndex) }
        }

        runs.removeAll(keepingCapacity: true)
        var rawLength = 0
        let copyStarted = DispatchTime.now().uptimeNanoseconds
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
                let pixelWidth = tileCountX * tileSize
                let pixelHeight = tileSize
                let dataOffset = rawLength
                for row in 0..<pixelHeight {
                    memcpy(
                        raw.advanced(by: rawLength),
                        yBase.advanced(
                            by: (tileY * tileSize + row) * yStride +
                                startX * tileSize
                        ),
                        pixelWidth
                    )
                    rawLength += pixelWidth
                }
                for row in 0..<(pixelHeight / 2) {
                    memcpy(
                        raw.advanced(by: rawLength),
                        uvBase.advanced(
                            by: (tileY * tileSize / 2 + row) * uvStride +
                                startX * tileSize
                        ),
                        pixelWidth
                    )
                    rawLength += pixelWidth
                }
                runs.append(
                    TBNV12Compression.TileRun(
                        tileX: startX,
                        tileY: tileY,
                        tileCountX: tileCountX,
                        pixelHeight: pixelHeight,
                        dataOffset: dataOffset,
                        dataLength: rawLength - dataOffset
                    )
                )
                guard runs.count <= TBNV12Compression.maxTileRuns else {
                    return nil
                }
            }
        }
        guard !runs.isEmpty else { return nil }
        let copyFinished = DispatchTime.now().uptimeNanoseconds

        let slot = slots[slotIndex]
        let headerBytes = Self.fixedHeaderBytes +
            runs.count * Self.runDescriptorBytes
        let compressionStarted = copyFinished
        let size = encoder.encode(
            destination: slot.advanced(by: headerBytes)
                .assumingMemoryBound(to: UInt8.self),
            capacity: slotCapacity - headerBytes,
            source: raw.assumingMemoryBound(to: UInt8.self),
            length: rawLength,
            scratch: scratch
        )
        let compressionFinished = DispatchTime.now().uptimeNanoseconds
        guard size > 0 else { return nil }

        let checksumStarted = compressionFinished
        let checksumValue = checksumPolicy == .fnv64
            ? TBChecksum64(raw, rawLength)
            : 0
        let checksumFinished = DispatchTime.now().uptimeNanoseconds

        let packetStarted = checksumFinished
        let packetLength = headerBytes + size
        var offset = 0
        func storeBE<T: FixedWidthInteger>(_ value: T) {
            slot.storeBytes(of: value.bigEndian, toByteOffset: offset, as: T.self)
            offset += MemoryLayout<T>.size
        }
        // Length counts the type byte plus payload.
        storeBE(UInt32(packetLength - 4))
        storeBE(TBMonitorPacketType.rawFrame.rawValue)
        storeBE(UInt8(4))
        storeBE(UInt8(1))
        storeBE(UInt16(tileSize))
        storeBE(UInt32(width))
        storeBE(UInt32(height))
        storeBE(UInt32(runs.count))
        storeBE(UInt32(rawLength))
        storeBE(UInt32(size))
        storeBE(checksumValue)
        for run in runs {
            storeBE(UInt16(run.tileX))
            storeBE(UInt16(run.tileY))
            storeBE(UInt16(run.tileCountX))
            storeBE(UInt16(run.pixelHeight))
            storeBE(UInt32(run.dataOffset))
            storeBE(UInt32(run.dataLength))
        }
        let packet = Data(
            bytesNoCopy: slot,
            count: packetLength,
            deallocator: .custom { [self] _, _ in
                releaseSlot(slotIndex)
            }
        )
        handedOff = true
        let packetFinished = DispatchTime.now().uptimeNanoseconds
        return TBNV12Compression.PacketResult(
            packet: packet,
            rawBytes: rawLength,
            wireBytes: packetLength,
            copyNanoseconds: copyFinished - copyStarted,
            compressionNanoseconds: compressionFinished - compressionStarted,
            checksumNanoseconds: checksumFinished - checksumStarted,
            packetNanoseconds: packetFinished - packetStarted,
            regionPixels: dirtyTiles.count * tileSize * tileSize,
            runCount: runs.count
        )
    }

    private func acquireSlot() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = slotInUse.firstIndex(of: false) else { return nil }
        slotInUse[index] = true
        return index
    }

    private func releaseSlot(_ index: Int) {
        lock.lock()
        slotInUse[index] = false
        lock.unlock()
    }
}
