import Foundation

/// Zero-copy builder for NV12 tile-run packets (raw frame format 4) and
/// copy-rect packets (raw frame format 5).
///
/// Format 4 packets are byte-identical to `TBNV12Compression.makeTileRunPacket`
/// with the same encoder and a single LZ4 thread, but avoid its per-frame
/// allocations and copies:
/// - dirty rows are memcpy'd into one preallocated, prefaulted staging buffer;
/// - the LZ4 state and parallel side buffers are allocated once and reused;
/// - the frame header, run table and LZ4 output are written in place into a
///   packet slot that is handed to the network as `Data(bytesNoCopy:)`.
///
/// A slot stays reserved until the last reference to its `Data` is released,
/// so a packet still owned by `NWConnection` is never overwritten. When every
/// slot is busy, the builders return nil and callers fall back to
/// `TBNV12Compression.makeTileRunPacket`.
///
/// Not thread-safe: call the builders from one queue. Slot release may happen
/// on any thread and is guarded by `lock`.
final class TBNV12TileRunPacketWriter: @unchecked Sendable {
    static let slotCount = 2

    // [BE32 length][type] + format header (checksum included).
    private static let tileRunHeaderBytes = 5 + 32
    private static let copyRectHeaderBytes = 5 + 40
    private static let runDescriptorBytes = 16
    private static let copyDescriptorBytes = 8

    let width: Int
    let height: Int
    let lz4: TBNV12ParallelLZ4Encoder
    var encoder: TBNV12LZ4Encoder { lz4.encoder }

    private let rawCapacity: Int
    private let slotCapacity: Int
    private let raw: UnsafeMutableRawPointer
    private let slots: [UnsafeMutableRawPointer]
    private var runs: [TBNV12Compression.TileRun] = []
    private var copyRuns: [TBNV12Compression.CopyRun] = []

    private let lock = NSLock()
    private var slotInUse: [Bool]

    convenience init?(
        width: Int, height: Int, encoder: TBNV12LZ4Encoder = .apple
    ) {
        self.init(
            width: width,
            height: height,
            lz4: TBNV12ParallelLZ4Encoder(encoder: encoder, threadCount: 1)
        )
    }

    init?(width: Int, height: Int, lz4: TBNV12ParallelLZ4Encoder) {
        let tileSize = TBNV12Compression.tileSize
        guard width > 0, height > 0,
              width % tileSize == 0, height % tileSize == 0
        else {
            return nil
        }
        self.width = width
        self.height = height
        self.lz4 = lz4
        rawCapacity = width * height * 3 / 2
        // Both encoders store incompressible input as raw blocks with a small
        // per-block header (64 KiB or 1 MiB blocks), so this bound is never
        // exceeded, even when the input is split across threads.
        let compressedBound = rawCapacity + rawCapacity / 256 + 64 * 1024
        slotCapacity = Self.copyRectHeaderBytes +
            TBNV12Compression.maxTileRuns *
                (Self.runDescriptorBytes + Self.copyDescriptorBytes) +
            compressedBound
        let pageSize = Int(getpagesize())
        raw = .allocate(byteCount: rawCapacity, alignment: pageSize)
        let slotCapacity = slotCapacity
        slots = (0..<Self.slotCount).map { _ in
            .allocate(byteCount: slotCapacity, alignment: pageSize)
        }
        slotInUse = Array(repeating: false, count: Self.slotCount)
        // Prefault once so the first frames do not pay for page faults.
        memset(raw, 0, rawCapacity)
        for slot in slots {
            memset(slot, 0, slotCapacity)
        }
        runs.reserveCapacity(TBNV12Compression.maxTileRuns)
        copyRuns.reserveCapacity(TBNV12Compression.maxTileRuns)
    }

    deinit {
        raw.deallocate()
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
        guard yStride >= width, uvStride >= width, !dirtyTiles.isEmpty,
              tilesAreValid(dirtyTiles)
        else {
            return nil
        }
        guard let slotIndex = acquireSlot() else { return nil }
        var handedOff = false
        defer {
            if !handedOff { releaseSlot(slotIndex) }
        }

        let copyStarted = DispatchTime.now().uptimeNanoseconds
        guard let rawLength = gatherRuns(
            yBase: yBase, uvBase: uvBase,
            yStride: yStride, uvStride: uvStride,
            tiles: dirtyTiles
        ), !runs.isEmpty else {
            return nil
        }
        let copyFinished = DispatchTime.now().uptimeNanoseconds

        let slot = slots[slotIndex]
        let headerBytes = Self.tileRunHeaderBytes +
            runs.count * Self.runDescriptorBytes
        let compressionStarted = copyFinished
        let size = lz4.encode(
            destination: slot.advanced(by: headerBytes)
                .assumingMemoryBound(to: UInt8.self),
            capacity: slotCapacity - headerBytes,
            source: raw.assumingMemoryBound(to: UInt8.self),
            length: rawLength
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
        var writer = BEWriter(base: slot)
        // Length counts the type byte plus payload.
        writer.store(UInt32(packetLength - 4))
        writer.store(TBMonitorPacketType.rawFrame.rawValue)
        writer.store(UInt8(4))
        writer.store(UInt8(1))
        writer.store(UInt16(TBNV12Compression.tileSize))
        writer.store(UInt32(width))
        writer.store(UInt32(height))
        writer.store(UInt32(runs.count))
        writer.store(UInt32(rawLength))
        writer.store(UInt32(size))
        writer.store(checksumValue)
        storeRunDescriptors(&writer)
        let packet = handOff(slotIndex, count: packetLength)
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
            regionPixels: dirtyTiles.count * TBNV12Compression.tileSize *
                TBNV12Compression.tileSize,
            runCount: runs.count
        )
    }

    /// Builds a format 5 packet: `copyTiles` are reproduced on the Receiver
    /// from its own previous frame shifted by (`dx`, `dy`), and `freshTiles`
    /// are sent as LZ4-compressed tile runs exactly like format 4. The two
    /// sets must be disjoint; `freshTiles` may be empty.
    ///
    /// The caller is responsible for having verified, on the committed
    /// baseline, that every copy tile equals the shifted source pixels, and
    /// that every source rectangle lies inside the frame.
    func makeCopyRectPacket(
        yBase: UnsafeRawPointer,
        uvBase: UnsafeRawPointer,
        yStride: Int,
        uvStride: Int,
        copyTiles: Set<Int>,
        dx: Int,
        dy: Int,
        freshTiles: Set<Int>,
        checksumPolicy: TBNV12ChecksumPolicy = .disabled
    ) -> TBNV12Compression.PacketResult? {
        guard yStride >= width, uvStride >= width,
              !copyTiles.isEmpty,
              dx % 2 == 0, dy % 2 == 0, dx != 0 || dy != 0,
              abs(dx) < width, abs(dy) < height,
              tilesAreValid(copyTiles), tilesAreValid(freshTiles),
              copyTiles.isDisjoint(with: freshTiles)
        else {
            return nil
        }
        let tileSize = TBNV12Compression.tileSize
        let tilesWide = width / tileSize
        copyRuns.removeAll(keepingCapacity: true)
        for run in TBNV12Compression.tileRuns(
            tiles: copyTiles, tilesWide: tilesWide, tilesHigh: height / tileSize
        ) {
            let x = run.tileX * tileSize
            let y = run.tileY * tileSize
            guard x - dx >= 0, y - dy >= 0,
                  x + run.tileCountX * tileSize - dx <= width,
                  y + tileSize - dy <= height
            else {
                return nil
            }
            copyRuns.append(run)
        }
        guard copyRuns.count <= TBNV12Compression.maxTileRuns,
              let slotIndex = acquireSlot()
        else {
            return nil
        }
        var handedOff = false
        defer {
            if !handedOff { releaseSlot(slotIndex) }
        }

        let copyStarted = DispatchTime.now().uptimeNanoseconds
        let rawLength: Int
        if freshTiles.isEmpty {
            runs.removeAll(keepingCapacity: true)
            rawLength = 0
        } else {
            guard let length = gatherRuns(
                yBase: yBase, uvBase: uvBase,
                yStride: yStride, uvStride: uvStride,
                tiles: freshTiles
            ) else {
                return nil
            }
            rawLength = length
        }
        let copyFinished = DispatchTime.now().uptimeNanoseconds

        let slot = slots[slotIndex]
        let headerBytes = Self.copyRectHeaderBytes +
            copyRuns.count * Self.copyDescriptorBytes +
            runs.count * Self.runDescriptorBytes
        let compressionStarted = copyFinished
        var size = 0
        if rawLength > 0 {
            size = lz4.encode(
                destination: slot.advanced(by: headerBytes)
                    .assumingMemoryBound(to: UInt8.self),
                capacity: slotCapacity - headerBytes,
                source: raw.assumingMemoryBound(to: UInt8.self),
                length: rawLength
            )
            guard size > 0 else { return nil }
        }
        let compressionFinished = DispatchTime.now().uptimeNanoseconds

        let checksumStarted = compressionFinished
        let checksumValue = checksumPolicy == .fnv64 && rawLength > 0
            ? TBChecksum64(raw, rawLength)
            : 0
        let checksumFinished = DispatchTime.now().uptimeNanoseconds

        let packetStarted = checksumFinished
        let packetLength = headerBytes + size
        var writer = BEWriter(base: slot)
        writer.store(UInt32(packetLength - 4))
        writer.store(TBMonitorPacketType.rawFrame.rawValue)
        writer.store(UInt8(5))
        writer.store(UInt8(1))
        writer.store(UInt16(tileSize))
        writer.store(UInt32(width))
        writer.store(UInt32(height))
        writer.store(UInt32(runs.count))
        writer.store(UInt32(rawLength))
        writer.store(UInt32(size))
        writer.store(checksumValue)
        writer.store(Int16(dx))
        writer.store(Int16(dy))
        writer.store(UInt32(copyRuns.count))
        for run in copyRuns {
            writer.store(UInt16(run.tileX))
            writer.store(UInt16(run.tileY))
            writer.store(UInt16(run.tileCountX))
            writer.store(UInt16(0))
        }
        storeRunDescriptors(&writer)
        let packet = handOff(slotIndex, count: packetLength)
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
            regionPixels: freshTiles.count * tileSize * tileSize,
            runCount: runs.count + copyRuns.count
        )
    }

    private struct BEWriter {
        let base: UnsafeMutableRawPointer
        var offset = 0

        mutating func store<T: FixedWidthInteger>(_ value: T) {
            base.storeBytes(
                of: value.bigEndian, toByteOffset: offset, as: T.self
            )
            offset += MemoryLayout<T>.size
        }
    }

    private func tilesAreValid(_ tiles: Set<Int>) -> Bool {
        let tileSize = TBNV12Compression.tileSize
        let tileCount = (width / tileSize) * (height / tileSize)
        return tiles.allSatisfy { $0 >= 0 && $0 < tileCount }
    }

    /// Copies the rows of every horizontal run of `tiles` into `raw` and
    /// records the runs in `runs`. Returns the staged length, or nil when
    /// there are more than `maxTileRuns` runs.
    private func gatherRuns(
        yBase: UnsafeRawPointer,
        uvBase: UnsafeRawPointer,
        yStride: Int,
        uvStride: Int,
        tiles: Set<Int>
    ) -> Int? {
        let tileSize = TBNV12Compression.tileSize
        let tilesWide = width / tileSize
        let tilesHigh = height / tileSize
        runs.removeAll(keepingCapacity: true)
        var rawLength = 0
        for tileY in 0..<tilesHigh {
            var tileX = 0
            while tileX < tilesWide {
                guard tiles.contains(tileY * tilesWide + tileX) else {
                    tileX += 1
                    continue
                }
                let startX = tileX
                while tileX < tilesWide,
                      tiles.contains(tileY * tilesWide + tileX) {
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
        return rawLength
    }

    private func storeRunDescriptors(_ writer: inout BEWriter) {
        for run in runs {
            writer.store(UInt16(run.tileX))
            writer.store(UInt16(run.tileY))
            writer.store(UInt16(run.tileCountX))
            writer.store(UInt16(run.pixelHeight))
            writer.store(UInt32(run.dataOffset))
            writer.store(UInt32(run.dataLength))
        }
    }

    private func handOff(_ slotIndex: Int, count: Int) -> Data {
        Data(
            bytesNoCopy: slots[slotIndex],
            count: count,
            deallocator: .custom { [self] _, _ in
                releaseSlot(slotIndex)
            }
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
