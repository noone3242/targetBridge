import CoreVideo
import ScreenCaptureKit
import XCTest
@testable import TargetBridge

/// Wire-protocol unit tests. These run with no network, no Thunderbolt hardware,
/// and no receiver — they pin down the framing invariants both apps rely on:
/// `[4B BE length][1B type][payload]` where length counts type + payload.
final class TBMonitorProtocolTests: XCTestCase {

    func testAutomaticConnectionStateDoesNotChangeReceiverVolume() {
        XCTAssertEqual(
            TBReceiverStateUpdate.automaticOnConnect,
            [.hello, .inputControlMode, .brightness]
        )
        XCTAssertFalse(TBReceiverStateUpdate.automaticOnConnect.contains(.volume))
    }

    func testNative5KRenderMatchingUsesAReal5KFramebuffer() {
        let mode = TBDisplayCapturePreset.native5k60Experimental.renderMatchedDisplayMode

        XCTAssertEqual(mode.width, 2560)
        XCTAssertEqual(mode.height, 1440)
        XCTAssertEqual(mode.backingWidth, 5120)
        XCTAssertEqual(mode.backingHeight, 2880)
        XCTAssertTrue(
            tbVirtualDisplayModeMatches(
                logicalWidth: 2560,
                logicalHeight: 1440,
                pixelWidth: 5120,
                pixelHeight: 2880,
                target: mode,
                hiDPI: true
            )
        )
        XCTAssertFalse(
            tbVirtualDisplayModeMatches(
                logicalWidth: 2560,
                logicalHeight: 1440,
                pixelWidth: 2560,
                pixelHeight: 1440,
                target: mode,
                hiDPI: true
            )
        )
    }

    func testSessionLogIsBoundedAndSuppressesAdjacentDuplicates() {
        var entries: [TBSessionLogEntry] = []
        for index in 0..<85 {
            entries = tbAppendingSessionLogEntry(
                to: entries,
                message: "event-\(index)",
                timestamp: "12:00:\(index)",
                capacity: 80
            )
        }

        XCTAssertEqual(entries.count, 80)
        XCTAssertEqual(entries.first?.message, "event-5")
        XCTAssertEqual(entries.last?.message, "event-84")

        let duplicate = tbAppendingSessionLogEntry(
            to: entries,
            message: "event-84",
            timestamp: "12:01:00",
            capacity: 80
        )
        XCTAssertEqual(duplicate, entries)
    }

    // MARK: - BE32 primitives

    func testBE32RoundTrip() {
        let values: [UInt32] = [0, 1, 0xFF, 0x1234_5678, 0x7FFF_FFFF, 0xFFFF_FFFF]
        for value in values {
            var data = Data()
            TBMonitorProtocol.appendBE32(&data, value)
            XCTAssertEqual(data.count, 4)
            XCTAssertEqual(TBMonitorProtocol.readBE32(data, offset: 0), value, "round trip failed for \(value)")
        }
    }

    func testAppendBE32IsBigEndian() {
        var data = Data()
        TBMonitorProtocol.appendBE32(&data, 0x0102_0304)
        XCTAssertEqual([UInt8](data), [0x01, 0x02, 0x03, 0x04])
    }

    func testReadBE32HonorsOffset() {
        var data = Data()
        TBMonitorProtocol.appendBE32(&data, 0xAAAA_AAAA)
        TBMonitorProtocol.appendBE32(&data, 0x0000_BEEF)
        XCTAssertEqual(TBMonitorProtocol.readBE32(data, offset: 4), 0x0000_BEEF)
    }

    func testBE64RoundTrip() {
        let values: [UInt64] = [0, 1, 0x0123_4567_89AB_CDEF, UInt64.max]
        for value in values {
            var data = Data()
            TBMonitorProtocol.appendBE64(&data, value)
            XCTAssertEqual(data.count, 8)
            XCTAssertEqual(TBMonitorProtocol.readBE64(data, offset: 0), value)
        }
    }

    // MARK: - Packet framing

    func testMakePacketLayout() {
        let packet = TBMonitorProtocol.makePacket(type: .heartbeat, payload: Data([0xAA, 0xBB, 0xCC]))
        // length = 1 (type byte) + 3 (payload) = 4
        XCTAssertEqual([UInt8](packet), [0x00, 0x00, 0x00, 0x04, 0x30, 0xAA, 0xBB, 0xCC])
    }

    func testExperimentalPacketTypesAndOlderDisplayProfilesRemainCompatible() throws {
        XCTAssertEqual(TBMonitorPacketType.rawFrame.rawValue, 0x22)
        XCTAssertEqual(TBMonitorPacketType.bc7Frame.rawValue, 0x24)
        XCTAssertEqual(TBMonitorPacketType.bc7RenderAck.rawValue, 0x25)
        XCTAssertEqual(TBMonitorPacketType.bc7RenderAckRequest.rawValue, 0x26)
        XCTAssertEqual(TBMonitorPacketType.bc7TileDelta.rawValue, 0x27)
        XCTAssertEqual(TBMonitorPacketType.bc7KeyframeRequest.rawValue, 0x28)
        XCTAssertEqual(TBMonitorPacketType.bc7CompressedFrame.rawValue, 0x29)
        XCTAssertEqual(TBMonitorPacketType.bc7CompressedDelta.rawValue, 0x2A)
        XCTAssertEqual(
            TBMonitorPacketType.rawNV12KeyframeRequest.rawValue,
            0x2B
        )
        XCTAssertEqual(TBMonitorPacketType.receiverMetrics.rawValue, 0x14)

        let olderProfile = Data("""
        {
          "receiverName": "Older Receiver",
          "panelWidth": 5120,
          "panelHeight": 2880,
          "modeWidth": 2560,
          "modeHeight": 1440,
          "refreshRate": 60,
          "hiDPI": true,
          "captureWidth": 5120,
          "captureHeight": 2880
        }
        """.utf8)
        let profile = try JSONDecoder().decode(TBMonitorDisplayProfile.self, from: olderProfile)
        XCTAssertNil(profile.supportsRawNV12)
        XCTAssertNil(profile.supportsRawNV12LZ4)
        XCTAssertNil(profile.supportsBC7Mode6)
        XCTAssertNil(profile.supportsBC7TileDelta)
        XCTAssertNil(profile.supportsBC7LZFSE)
        XCTAssertNil(profile.supportsBC7LZ4)
        XCTAssertNil(profile.receiverVersion)
        XCTAssertNil(profile.receiverBuild)
        XCTAssertNil(profile.receiverCommit)

        let currentProfile = Data("""
        {
          "receiverName": "Intel iMac",
          "panelWidth": 5120,
          "panelHeight": 2880,
          "modeWidth": 2560,
          "modeHeight": 1440,
          "refreshRate": 60,
          "hiDPI": true,
          "captureWidth": 5120,
          "captureHeight": 2880,
          "supportsBC7LZFSE": true,
          "supportsBC7LZ4": true,
          "supportsRawNV12LZ4": true,
          "receiverVersion": "3.3.0",
          "receiverBuild": "dev-20260926163000",
          "receiverCommit": "9b6b092abcde"
        }
        """.utf8)
        let current = try JSONDecoder().decode(TBMonitorDisplayProfile.self, from: currentProfile)
        XCTAssertEqual(current.receiverVersion, "3.3.0")
        XCTAssertEqual(current.supportsBC7LZFSE, true)
        XCTAssertEqual(current.supportsBC7LZ4, true)
        XCTAssertEqual(current.supportsRawNV12LZ4, true)
        XCTAssertEqual(current.receiverBuild, "dev-20260926163000")
        XCTAssertEqual(current.receiverCommit, "9b6b092abcde")

        let metrics = try JSONDecoder().decode(
            TBMonitorReceiverMetrics.self,
            from: Data("""
            {
              "fps": 59.94,
              "networkGbps": 0.42,
              "packets": 1200,
              "bc7Frames": 1180,
              "bc7PayloadBytes": 9000000,
              "bc7Invalid": 0,
              "renderFailures": 0,
              "bc7Deltas": 1170,
              "appliedSequence": 1180,
              "keyframeRequests": 0
            }
            """.utf8)
        )
        XCTAssertEqual(metrics.fps, 59.94, accuracy: 0.001)
        XCTAssertEqual(metrics.appliedSequence, 1180)
    }

    func testBC7DeltaPlannerKeyframeDeltaAndRecovery() throws {
        let width = 128
        let height = 64
        let bytesPerRow = 512
        let frameBytes = bytesPerRow * (height / 4)
        let planner = TBBC7DeltaPlanner(keyframeIntervalFrames: 2)
        let initial = Data(repeating: 0x11, count: frameBytes)

        guard case .keyframe(let firstSequence, _, _) =
            try XCTUnwrap(planner.plan(
                current: initial, width: width, height: height, bytesPerRow: bytesPerRow
            )) else {
            return XCTFail("first frame must be a keyframe")
        }
        XCTAssertEqual(firstSequence, 1)

        guard case .delta(let secondSequence, let baseSequence, _, let runs, let dirty, let total) =
            try XCTUnwrap(planner.plan(
                current: initial, width: width, height: height, bytesPerRow: bytesPerRow
            )) else {
            return XCTFail("identical frame must be a zero-run delta")
        }
        XCTAssertEqual(secondSequence, 2)
        XCTAssertEqual(baseSequence, 1)
        XCTAssertTrue(runs.isEmpty)
        XCTAssertEqual(dirty, 0)
        XCTAssertEqual(total, 2)

        var oneTileChanged = initial
        oneTileChanged[256] ^= 0xFF
        guard case .delta(let thirdSequence, _, _, let changedRuns, let changedCount, _) =
            try XCTUnwrap(planner.plan(
                current: oneTileChanged, width: width, height: height, bytesPerRow: bytesPerRow
            )) else {
            return XCTFail("single changed tile must remain a delta")
        }
        XCTAssertEqual(thirdSequence, 3)
        XCTAssertEqual(changedCount, 1)
        XCTAssertEqual(changedRuns.count, 1)
        XCTAssertEqual(changedRuns[0].tileX, 1)

        planner.markSendFailure()
        guard case .keyframe(let recoverySequence, _, _) =
            try XCTUnwrap(planner.plan(
                current: oneTileChanged, width: width, height: height, bytesPerRow: bytesPerRow
            )) else {
            return XCTFail("send failure must force a recovery keyframe")
        }
        XCTAssertEqual(recoverySequence, 4)
    }

    func testBC7DeltaChecksumMatchesReceiverFixture() throws {
        let planner = TBBC7DeltaPlanner(keyframeIntervalFrames: 120)
        let frame = Data(repeating: 0x11, count: 4096)
        guard case .keyframe(_, let checksum, _) =
            try XCTUnwrap(planner.plan(
                current: frame, width: 64, height: 64, bytesPerRow: 256
            )) else {
            return XCTFail("first fixture frame must be a keyframe")
        }
        XCTAssertEqual(checksum, 0x2DA5_3169_9A69_7325)
    }

    func testBC7DirtyRegionsAlignToTilesAndClampToFramebuffer() {
        let plan = tbBC7DirtyRegionPlan(
            dirtyRects: [
                CGRect(x: 63, y: 65, width: 4, height: 2),
                CGRect(x: -20, y: -10, width: 30, height: 20)
            ],
            width: 128,
            height: 128
        )

        XCTAssertEqual(plan.tileIndices, Set([0, 2, 3]))
        XCTAssertEqual(plan.regions, [
            TBBC7DirtyRegionPlan.Region(blockX: 0, blockY: 16, blockWidth: 32, blockHeight: 16),
            TBBC7DirtyRegionPlan.Region(blockX: 0, blockY: 0, blockWidth: 16, blockHeight: 16)
        ])
    }

    func testBC7DirtyRectsStayInFramebufferPixelCoordinates() throws {
        let dirtyRects = [CGRect(x: 64, y: 128, width: 200, height: 100)]
        let validated = try XCTUnwrap(tbBC7PixelDirtyRects(
            dirtyRects: dirtyRects,
            outputWidth: 5120,
            outputHeight: 2880
        ))
        XCTAssertEqual(validated, dirtyRects)

        XCTAssertEqual(tbBC7PixelDirtyRects(
            dirtyRects: [CGRect(x: 5000, y: 0, width: 200, height: 10)],
            outputWidth: 5120,
            outputHeight: 2880
        ), [CGRect(x: 5000, y: 0, width: 120, height: 10)])
    }

    func testBC7DirtyRectAttachmentDictionariesDecode() throws {
        let contentRect = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let dirtyRect = CGRect(x: 64, y: 128, width: 200, height: 100)
        let frame: [SCStreamFrameInfo: Any] = [
            .contentRect: try XCTUnwrap(contentRect.dictionaryRepresentation),
            .contentScale: NSNumber(value: 2.0),
            .dirtyRects: [try XCTUnwrap(dirtyRect.dictionaryRepresentation)]
        ]

        XCTAssertEqual(
            tbBC7DirtyRects(from: frame, outputWidth: 5120, outputHeight: 2880),
            [dirtyRect]
        )
    }

    func testBC7DeltaPlannerOnlyScansCandidateDirtyTiles() throws {
        let width = 128
        let height = 64
        let bytesPerRow = 512
        let planner = TBBC7DeltaPlanner(keyframeIntervalFrames: 120)
        let initial = Data(repeating: 0, count: bytesPerRow * (height / 4))
        _ = planner.plan(
            current: initial,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow
        )

        var next = initial
        next[0] = 1
        next[256] = 2
        guard case .delta(_, _, _, let runs, let dirtyTiles, _) = try XCTUnwrap(
            planner.plan(
                current: next,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                candidateDirtyTiles: [1]
            )
        ) else {
            return XCTFail("candidate-limited update must remain a delta")
        }

        XCTAssertEqual(dirtyTiles, 1)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].tileX, 1)
    }

    func testBC7DeltaPlannerUsesMetalTileAnalysis() throws {
        let width = 128
        let height = 64
        let bytesPerRow = 512
        let planner = TBBC7DeltaPlanner(keyframeIntervalFrames: 120)
        let initial = Data(repeating: 0, count: bytesPerRow * (height / 4))
        _ = planner.plan(
            current: initial,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            analyzedDirtyTiles: [0, 1],
            analyzedChecksums: [10, 20]
        )

        var changed = initial
        changed[256] = 1
        guard case .delta(_, _, let checksum, let runs, let dirtyTiles, _) =
            try XCTUnwrap(planner.plan(
                current: changed,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                candidateDirtyTiles: [],
                analyzedDirtyTiles: [1],
                analyzedChecksums: [10, 30]
            )) else {
            return XCTFail("Metal-analyzed frame must remain a delta")
        }

        XCTAssertEqual(checksum, 10 ^ 30)
        XCTAssertEqual(dirtyTiles, 1)
        XCTAssertEqual(runs, [
            TBBC7DeltaRun(tileX: 1, tileY: 0, tileCountX: 1, pixelHeight: 64)
        ])
    }

    func testBC7RecoveryRequiresAFullFrame() throws {
        let planner = TBBC7DeltaPlanner(keyframeIntervalFrames: 120)
        XCTAssertTrue(planner.requiresFullFrame)
        _ = planner.plan(
            current: Data(repeating: 0, count: 4096),
            width: 64,
            height: 64,
            bytesPerRow: 256
        )
        XCTAssertFalse(planner.requiresFullFrame)
        planner.markSendFailure()
        XCTAssertTrue(planner.requiresFullFrame)
    }

    func testBC7DeltaPlannerPeriodicKeyframesAndRunCoalescing() throws {
        let periodic = TBBC7DeltaPlanner(keyframeIntervalFrames: 1)
        let frame = Data(repeating: 0, count: 4096)
        _ = periodic.plan(current: frame, width: 64, height: 64, bytesPerRow: 256)
        guard case .delta = try XCTUnwrap(periodic.plan(
            current: frame, width: 64, height: 64, bytesPerRow: 256
        )) else {
            return XCTFail("one interval frame should remain a delta")
        }
        guard case .keyframe = try XCTUnwrap(periodic.plan(
            current: frame, width: 64, height: 64, bytesPerRow: 256
        )) else {
            return XCTFail("periodic recovery must force a keyframe")
        }

        let width = 5120
        let height = 512
        let bytesPerRow = width * 4
        let runLimited = TBBC7DeltaPlanner(keyframeIntervalFrames: 120)
        let initial = Data(repeating: 0, count: bytesPerRow * height / 4)
        _ = runLimited.plan(
            current: initial, width: width, height: height, bytesPerRow: bytesPerRow
        )
        var checkerboard = initial
        let tileRowBytes = 256
        let tilesWide = width / 64
        for tileY in 0..<(height / 64) {
            for tileX in stride(from: 0, to: tilesWide, by: 2) {
                let offset = tileY * 16 * bytesPerRow + tileX * tileRowBytes
                checkerboard[offset] = 1
            }
        }
        guard case .delta(_, _, _, let runs, _, _) = try XCTUnwrap(runLimited.plan(
            current: checkerboard,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow
        )) else {
            return XCTFail("fragmented changes should remain a bounded delta")
        }
        XCTAssertLessThanOrEqual(runs.count, height / 64)
    }

    func testBC7DeltaPlannerCoalescesRunsWithoutPayloadKeyframeFallback() throws {
        let width = 128
        let height = 64
        let bytesPerRow = 512
        let initial = Data(repeating: 0, count: bytesPerRow * (height / 4))
        let planner = TBBC7DeltaPlanner(keyframeIntervalFrames: 120)
        _ = planner.plan(current: initial, width: width, height: height, bytesPerRow: bytesPerRow)

        var bothTilesChanged = initial
        bothTilesChanged[0] = 1
        bothTilesChanged[256] = 2
        guard case .delta(let sequence, _, _, let fullRowRuns, _, _) =
            try XCTUnwrap(planner.plan(
                current: bothTilesChanged, width: width, height: height, bytesPerRow: bytesPerRow
            )) else {
            return XCTFail("large delta should not inject a latency-heavy keyframe")
        }
        XCTAssertEqual(sequence, 2)
        XCTAssertEqual(fullRowRuns.count, 1)
        XCTAssertEqual(fullRowRuns[0].tileCountX, 2)

        let widePlanner = TBBC7DeltaPlanner(keyframeIntervalFrames: 120)
        let wideWidth = 192
        let wideBytesPerRow = 768
        let wideInitial = Data(repeating: 0, count: wideBytesPerRow * (height / 4))
        _ = widePlanner.plan(
            current: wideInitial, width: wideWidth, height: height, bytesPerRow: wideBytesPerRow
        )
        var adjacentTilesChanged = wideInitial
        adjacentTilesChanged[0] = 1
        adjacentTilesChanged[256] = 2
        guard case .delta(_, _, _, let runs, let dirty, _) =
            try XCTUnwrap(widePlanner.plan(
                current: adjacentTilesChanged,
                width: wideWidth,
                height: height,
                bytesPerRow: wideBytesPerRow
            )) else {
            return XCTFail("two adjacent tiles in a three-tile row should remain a delta")
        }
        XCTAssertEqual(dirty, 2)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].tileCountX, 2)
    }

    func testBC7DeltaPlannerDefersWithinBudgetAndConverges() throws {
        let width = 256
        let height = 64
        let bytesPerRow = 1024
        let planner = TBBC7DeltaPlanner(keyframeIntervalFrames: 120)
        let initial = Data(repeating: 0, count: bytesPerRow * (height / 4))
        _ = planner.plan(
            current: initial,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow
        )

        let changed = Data(repeating: 1, count: initial.count)
        for expectedDeferred in stride(from: 3, through: 0, by: -1) {
            guard case .delta(_, _, _, let runs, _, _) = try XCTUnwrap(
                planner.plan(
                    current: changed,
                    width: width,
                    height: height,
                    bytesPerRow: bytesPerRow,
                    maxTilesPerDelta: 1
                )
            ) else {
                return XCTFail("budgeted update must remain a delta")
            }
            XCTAssertEqual(runs.reduce(0) { $0 + $1.tileCountX }, 1)
            XCTAssertEqual(planner.lastStats.deferredTiles, expectedDeferred)
            XCTAssertLessThanOrEqual(
                planner.lastStats.worstDeferredAge,
                TBBC7TileBudgetController.maxTileAge
            )
        }

        guard case .delta(_, _, _, let finalRuns, let dirtyTiles, _) =
            try XCTUnwrap(planner.plan(
                current: changed,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                maxTilesPerDelta: 1
            )) else {
            return XCTFail("converged frame must remain a delta")
        }
        XCTAssertTrue(finalRuns.isEmpty)
        XCTAssertEqual(dirtyTiles, 0)
        XCTAssertEqual(planner.lastStats.deferredTiles, 0)
    }

    func testBC7TileBudgetControllerUsesHysteresisAndAgeFloor() {
        var controller = TBBC7TileBudgetController()
        XCTAssertEqual(controller.budget(totalTiles: 3600), 3600)

        controller.recordSend(durationNanoseconds: 13_000_000, totalTiles: 3600)
        XCTAssertEqual(controller.budget(totalTiles: 3600), 3600)
        controller.recordSend(durationNanoseconds: 13_000_000, totalTiles: 3600)
        XCTAssertEqual(controller.budget(totalTiles: 3600), 2700)

        for _ in 0..<12 {
            controller.recordSend(durationNanoseconds: 7_000_000, totalTiles: 3600)
        }
        XCTAssertGreaterThan(controller.budget(totalTiles: 3600), 2700)

        for _ in 0..<40 {
            controller.recordSend(durationNanoseconds: 20_000_000, totalTiles: 3600)
        }
        XCTAssertGreaterThanOrEqual(controller.budget(totalTiles: 3600), 900)
    }

    func testRollingMetricWindowReportsTailPercentiles() {
        var window = TBRollingMetricWindow(capacity: 5)
        [1, 2, 3, 4, 100].forEach { window.record(UInt64($0)) }
        let summary = window.summary()
        XCTAssertEqual(summary.count, 5)
        XCTAssertEqual(summary.p50, 3)
        XCTAssertEqual(summary.p95, 100)
        XCTAssertEqual(summary.p99, 100)
        XCTAssertEqual(summary.max, 100)
    }

    func testBC7DeltaPacketWritesRunsDirectlyFromFrameBuffer() throws {
        let width = 192
        let height = 64
        let bytesPerRow = 768
        let current = Data((0..<(bytesPerRow * 16)).map {
            UInt8(truncatingIfNeeded: $0 &+ ($0 / 256) &* 17)
        })
        let runs = [
            TBBC7DeltaRun(tileX: 1, tileY: 0, tileCountX: 2, pixelHeight: 64)
        ]

        let packet = try XCTUnwrap(tbMakeBC7DeltaPacket(
            current: current,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            sequence: 9,
            baseSequence: 8,
            checksum: 0x1122_3344_5566_7788,
            runs: runs
        ))

        XCTAssertEqual(TBMonitorProtocol.readBE32(packet, offset: 0), UInt32(packet.count - 4))
        XCTAssertEqual(packet[4], TBMonitorPacketType.bc7TileDelta.rawValue)
        XCTAssertEqual(packet[5], 1)
        XCTAssertEqual(TBMonitorProtocol.readBE64(packet, offset: 6), 9)
        XCTAssertEqual(TBMonitorProtocol.readBE64(packet, offset: 14), 8)
        XCTAssertEqual(
            TBMonitorProtocol.readBE64(packet, offset: 22),
            0x1122_3344_5566_7788
        )
        XCTAssertEqual(TBMonitorProtocol.readBE32(packet, offset: 30), UInt32(width))
        XCTAssertEqual(TBMonitorProtocol.readBE32(packet, offset: 34), UInt32(height))
        XCTAssertEqual(TBMonitorProtocol.readBE16(packet, offset: 38), 64)
        XCTAssertEqual(TBMonitorProtocol.readBE16(packet, offset: 40), 1)
        XCTAssertEqual(TBMonitorProtocol.readBE16(packet, offset: 42), 1)
        XCTAssertEqual(TBMonitorProtocol.readBE16(packet, offset: 44), 0)
        XCTAssertEqual(TBMonitorProtocol.readBE16(packet, offset: 46), 2)
        XCTAssertEqual(TBMonitorProtocol.readBE16(packet, offset: 48), 64)
        XCTAssertEqual(TBMonitorProtocol.readBE32(packet, offset: 50), 8192)

        var expected = Data(capacity: 8192)
        for row in 0..<16 {
            let start = row * bytesPerRow + 256
            expected.append(current[start..<(start + 512)])
        }
        XCTAssertEqual(packet.subdata(in: 54..<packet.count), expected)
    }

    func testBC7BytePlaneTransformRoundTripsExactly() throws {
        let blocks = Data((0..<(16 * 257)).map {
            UInt8(truncatingIfNeeded: $0 &* 37 &+ $0 / 16)
        })
        let planes = try XCTUnwrap(TBBC7Supercompression.planeSplit(blocks))
        XCTAssertNotEqual(planes, blocks)
        XCTAssertEqual(
            try XCTUnwrap(TBBC7Supercompression.inversePlaneSplit(planes)),
            blocks
        )
        XCTAssertNil(TBBC7Supercompression.planeSplit(Data(repeating: 0, count: 17)))
    }

    func testBC7LZFSEFramePacketReconstructsLegacyPayload() throws {
        let width = 256
        let height = 256
        let bytesPerRow = 1024
        let blocks = Data(repeating: 0x6D, count: bytesPerRow * height / 4)
        var payload = Data(capacity: 29 + blocks.count)
        payload.append(2)
        TBMonitorProtocol.appendBE64(&payload, 7)
        TBMonitorProtocol.appendBE64(&payload, 0x1122_3344_5566_7788)
        TBMonitorProtocol.appendBE32(&payload, UInt32(width))
        TBMonitorProtocol.appendBE32(&payload, UInt32(height))
        TBMonitorProtocol.appendBE32(&payload, UInt32(bytesPerRow))
        payload.append(blocks)
        let raw = TBMonitorProtocol.makePacket(type: .bc7Frame, payload: payload)

        let unsupported = tbSelectBC7WirePacket(
            rawPacket: raw,
            compressionMode: .off
        )
        XCTAssertEqual(unsupported.packet, raw)
        XCTAssertFalse(unsupported.compressionAttempted)
        XCTAssertNil(unsupported.compressedResult)

        let selection = tbSelectBC7WirePacket(
            rawPacket: raw,
            compressionMode: .lzfse
        )
        XCTAssertTrue(selection.compressionAttempted)
        let result = try XCTUnwrap(selection.compressedResult)
        XCTAssertEqual(selection.packet, result.packet)
        XCTAssertEqual(result.packet[4], TBMonitorPacketType.bc7CompressedFrame.rawValue)
        XCTAssertLessThan(result.packet.count, raw.count)
        XCTAssertEqual(result.rawBlockBytes, blocks.count)
        XCTAssertEqual(
            try XCTUnwrap(TBBC7Supercompression.decodeCompressedPacket(result.packet)),
            raw
        )

        func writeBE32(_ value: UInt32, into data: inout Data, at offset: Int) {
            data[offset] = UInt8((value >> 24) & 0xff)
            data[offset + 1] = UInt8((value >> 16) & 0xff)
            data[offset + 2] = UInt8((value >> 8) & 0xff)
            data[offset + 3] = UInt8(value & 0xff)
        }

        func writeBE64(_ value: UInt64, into data: inout Data, at offset: Int) {
            for index in 0..<8 {
                data[offset + index] = UInt8(
                    (value >> UInt64((7 - index) * 8)) & 0xff
                )
            }
        }
        func checksum(_ data: Data) -> UInt64 {
            var hash = UInt64(14_695_981_039_346_656_037)
            for byte in data {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            return hash
        }
        var trailing = result.packet
        let compressedLength = TBMonitorProtocol.readBE32(trailing, offset: 17)
        let metadataLength = Int(
            TBMonitorProtocol.readBE32(trailing, offset: 9)
        )
        trailing.append(0xA5)
        writeBE32(UInt32(trailing.count - 4), into: &trailing, at: 0)
        writeBE32(compressedLength + 1, into: &trailing, at: 17)
        XCTAssertNil(TBBC7Supercompression.decodeCompressedPacket(trailing))
        let compressedStart = 5 + 24 + metadataLength
        writeBE64(
            checksum(trailing.subdata(in: compressedStart..<trailing.count)),
            into: &trailing,
            at: 21
        )
        XCTAssertNil(TBBC7Supercompression.decodeCompressedPacket(trailing))

        var invalidChecksum = result.packet
        invalidChecksum[21] ^= 1
        XCTAssertNil(
            TBBC7Supercompression.decodeCompressedPacket(invalidChecksum)
        )

        var invalidBlockLength = result.packet
        writeBE32(
            UInt32(blocks.count - 16),
            into: &invalidBlockLength,
            at: 13
        )
        XCTAssertNil(
            TBBC7Supercompression.decodeCompressedPacket(invalidBlockLength)
        )
    }

    func testRawBC7LZ4FramePacketReconstructsLegacyPayload() throws {
        let width = 256
        let height = 256
        let bytesPerRow = 1024
        let blocks = Data(repeating: 0x4C, count: bytesPerRow * height / 4)
        var payload = Data()
        payload.append(1)
        TBMonitorProtocol.appendBE32(&payload, UInt32(width))
        TBMonitorProtocol.appendBE32(&payload, UInt32(height))
        TBMonitorProtocol.appendBE32(&payload, UInt32(bytesPerRow))
        payload.append(blocks)
        let raw = TBMonitorProtocol.makePacket(type: .bc7Frame, payload: payload)

        let selection = tbSelectBC7WirePacket(
            rawPacket: raw,
            compressionMode: .lz4
        )
        let result = try XCTUnwrap(selection.compressedResult)
        XCTAssertEqual(result.mode, .lz4)
        XCTAssertEqual(result.planeSplitNanoseconds, 0)
        XCTAssertLessThan(result.packet.count, raw.count)
        XCTAssertEqual(
            try XCTUnwrap(
                TBBC7Supercompression.decodeCompressedPacket(result.packet)
            ),
            raw
        )
    }

    func testNV12LZ4PacketRoundTripsExactly() throws {
        let width = 256
        let height = 256
        let yStride = 256
        let uvStride = 256
        let y = Data(repeating: 0x40, count: yStride * height)
        let uv = Data(repeating: 0x80, count: uvStride * height / 2)
        let packet = try XCTUnwrap(TBNV12Compression.makePacket(
            y: y,
            uv: uv,
            width: width,
            height: height,
            yStride: yStride,
            uvStride: uvStride
        ))
        let decoded = try XCTUnwrap(
            TBNV12Compression.decodePacket(packet.packet)
        )
        XCTAssertEqual(
            TBMonitorProtocol.readBE64(packet.packet, offset: 35),
            0
        )
        XCTAssertEqual(decoded.width, width)
        XCTAssertEqual(decoded.height, height)
        XCTAssertEqual(decoded.yStride, yStride)
        XCTAssertEqual(decoded.uvStride, uvStride)
        XCTAssertEqual(decoded.y, y)
        XCTAssertEqual(decoded.uv, uv)
    }

    func testNV12LZ4ChecksumRejectsCorruptChecksumWhenEnabled() throws {
        let width = 256
        let height = 256
        let yStride = 256
        let uvStride = 256
        let y = Data(repeating: 0x40, count: yStride * height)
        let uv = Data(repeating: 0x80, count: uvStride * height / 2)
        var packet = try XCTUnwrap(TBNV12Compression.makePacket(
            y: y,
            uv: uv,
            width: width,
            height: height,
            yStride: yStride,
            uvStride: uvStride,
            checksumPolicy: .fnv64
        )).packet
        XCTAssertNotEqual(TBMonitorProtocol.readBE64(packet, offset: 35), 0)
        packet[42] ^= 1
        XCTAssertNil(TBNV12Compression.decodePacket(packet))
    }

    func testNV12LZ4RegionPacketCopiesOnlyAlignedRegion() throws {
        let width = 128, height = 64
        let yStride = 128, uvStride = 128
        let y = Data((0..<(yStride * height)).map {
            UInt8(truncatingIfNeeded: $0)
        })
        let uv = Data((0..<(uvStride * height / 2)).map {
            UInt8(truncatingIfNeeded: $0 &* 3)
        })
        let packet = try y.withUnsafeBytes { yBytes in
            try uv.withUnsafeBytes { uvBytes in
                try XCTUnwrap(TBNV12Compression.makeRegionPacket(
                    yBase: try XCTUnwrap(yBytes.baseAddress),
                    uvBase: try XCTUnwrap(uvBytes.baseAddress),
                    width: width, height: height,
                    yStride: yStride, uvStride: uvStride,
                    x: 32, y: 16, regionWidth: 64, regionHeight: 32
                ))
            }
        }
        let decoded = try XCTUnwrap(
            TBNV12Compression.decodeRegionPacket(packet.packet)
        )
        XCTAssertEqual(
            TBMonitorProtocol.readBE64(packet.packet, offset: 51),
            0
        )
        XCTAssertEqual(decoded.x, 32)
        XCTAssertEqual(decoded.y, 16)
        XCTAssertEqual(decoded.regionWidth, 64)
        XCTAssertEqual(decoded.regionHeight, 32)
        var expected = Data()
        for row in 16..<48 {
            expected.append(y[(row * yStride + 32)..<(row * yStride + 96)])
        }
        for row in 8..<24 {
            expected.append(uv[(row * uvStride + 32)..<(row * uvStride + 96)])
        }
        XCTAssertEqual(decoded.raw, expected)
    }

    func testNV12LZ4RegionChecksumRejectsCorruptChecksumWhenEnabled() throws {
        let width = 128, height = 64
        let yStride = 128, uvStride = 128
        let y = Data(repeating: 0x40, count: yStride * height)
        let uv = Data(repeating: 0x80, count: uvStride * height / 2)
        var packet = try y.withUnsafeBytes { yBytes in
            try uv.withUnsafeBytes { uvBytes in
                try XCTUnwrap(TBNV12Compression.makeRegionPacket(
                    yBase: try XCTUnwrap(yBytes.baseAddress),
                    uvBase: try XCTUnwrap(uvBytes.baseAddress),
                    width: width, height: height,
                    yStride: yStride, uvStride: uvStride,
                    x: 32, y: 16, regionWidth: 64, regionHeight: 32,
                    checksumPolicy: .fnv64
                )).packet
            }
        }
        XCTAssertNotEqual(TBMonitorProtocol.readBE64(packet, offset: 51), 0)
        packet[58] ^= 1
        XCTAssertNil(TBNV12Compression.decodeRegionPacket(packet))
    }

    func testBC7CompressionModeCapabilityResolution() {
        XCTAssertEqual(
            tbResolveBC7CompressionMode(
                requested: .off,
                supportsLZ4: true,
                supportsLZFSE: true
            ),
            .off
        )
        XCTAssertEqual(
            tbResolveBC7CompressionMode(
                requested: .lz4,
                supportsLZ4: true,
                supportsLZFSE: false
            ),
            .lz4
        )
        XCTAssertEqual(
            tbResolveBC7CompressionMode(
                requested: .lz4,
                supportsLZ4: false,
                supportsLZFSE: true
            ),
            .off
        )
        XCTAssertEqual(
            tbResolveBC7CompressionMode(
                requested: .lzfse,
                supportsLZ4: true,
                supportsLZFSE: true
            ),
            .lzfse
        )
        XCTAssertEqual(
            tbResolveBC7CompressionMode(
                requested: .lzfse,
                supportsLZ4: true,
                supportsLZFSE: false
            ),
            .off
        )
    }

    func testBC7LZFSEDeltaPacketReconstructsLegacyPayload() throws {
        let width = 1024
        let height = 256
        let bytesPerRow = 4096
        let current = Data(repeating: 0x22, count: bytesPerRow * height / 4)
        let raw = try XCTUnwrap(tbMakeBC7DeltaPacket(
            current: current,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            sequence: 2,
            baseSequence: 1,
            checksum: 0xAABB_CCDD_EEFF_0011,
            runs: [
                TBBC7DeltaRun(
                    tileX: 0,
                    tileY: 0,
                    tileCountX: 16,
                    pixelHeight: 64
                )
            ]
        ))

        let result = try XCTUnwrap(
            TBBC7Supercompression.makeCompressedPacket(from: raw)
        )
        XCTAssertEqual(result.packet[4], TBMonitorPacketType.bc7CompressedDelta.rawValue)
        XCTAssertEqual(
            try XCTUnwrap(TBBC7Supercompression.decodeCompressedPacket(result.packet)),
            raw
        )
        let lz4 = try XCTUnwrap(
            TBBC7Supercompression.makeCompressedPacket(from: raw, mode: .lz4)
        )
        XCTAssertEqual(lz4.mode, .lz4)
        XCTAssertEqual(
            try XCTUnwrap(
                TBBC7Supercompression.decodeCompressedPacket(lz4.packet)
            ),
            raw
        )
    }

    func testBC7LZFSEFallsBackWhenPacketHasNoNetSavings() {
        var state = UInt64(0x0123_4567_89AB_CDEF)
        let bytes = (0..<(64 * 1024)).map { _ -> UInt8 in
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return UInt8(truncatingIfNeeded: state)
        }
        var payload = Data()
        payload.append(1)
        TBMonitorProtocol.appendBE32(&payload, 256)
        TBMonitorProtocol.appendBE32(&payload, 256)
        TBMonitorProtocol.appendBE32(&payload, 1024)
        payload.append(contentsOf: bytes)
        let raw = TBMonitorProtocol.makePacket(type: .bc7Frame, payload: payload)
        XCTAssertNil(TBBC7Supercompression.makeCompressedPacket(from: raw))
        XCTAssertNil(
            TBBC7Supercompression.makeCompressedPacket(from: raw, mode: .lz4)
        )
    }

    func testBC7LZFSECompressesRealMode6OutputLosslessly() throws {
        let width = 512
        let height = 512
        let pixelBuffer = try makeBGRAPixelBuffer(
            width: width,
            height: height
        ) { x, y in
            let stripe = UInt8((x / 32 + y / 32) % 4)
            let base = UInt8(truncatingIfNeeded: x / 2 + y / 3)
            return (
                base,
                UInt8(truncatingIfNeeded: Int(base) + Int(stripe) * 24),
                UInt8(truncatingIfNeeded: 220 - Int(base) / 2),
                255
            )
        }
        let encoder = try XCTUnwrap(TBBC7Mode6Encoder())
        let encoded = try XCTUnwrap(encoder.encode(pixelBuffer: pixelBuffer))
        var payload = Data()
        payload.append(1)
        TBMonitorProtocol.appendBE32(&payload, UInt32(width))
        TBMonitorProtocol.appendBE32(&payload, UInt32(height))
        TBMonitorProtocol.appendBE32(&payload, UInt32(encoded.bytesPerRow))
        payload.append(encoded.data)
        let raw = TBMonitorProtocol.makePacket(type: .bc7Frame, payload: payload)
        let compressed = try XCTUnwrap(
            TBBC7Supercompression.makeCompressedPacket(from: raw)
        )
        XCTAssertLessThan(compressed.packet.count, raw.count)
        XCTAssertEqual(
            try XCTUnwrap(
                TBBC7Supercompression.decodeCompressedPacket(compressed.packet)
            ),
            raw
        )
        let lz4 = try XCTUnwrap(
            TBBC7Supercompression.makeCompressedPacket(
                from: raw,
                mode: .lz4
            )
        )
        XCTAssertEqual(lz4.mode, .lz4)
        XCTAssertEqual(lz4.planeSplitNanoseconds, 0)
        XCTAssertLessThan(lz4.packet.count, raw.count)
        XCTAssertEqual(
            try XCTUnwrap(
                TBBC7Supercompression.decodeCompressedPacket(lz4.packet)
            ),
            raw
        )
    }

    func testNative5KRequiresNativeSourceFramebuffer() {
        XCTAssertFalse(tbSourceFramebufferSupportsNativeCapture(
            preset: .native5k, pixelWidth: 2560, pixelHeight: 1440
        ))
        XCTAssertTrue(tbSourceFramebufferSupportsNativeCapture(
            preset: .native5k, pixelWidth: 5120, pixelHeight: 2880
        ))
        XCTAssertFalse(tbSourceFramebufferSupportsNativeCapture(
            preset: .native5k60Experimental, pixelWidth: 5120, pixelHeight: 2160
        ))
        XCTAssertFalse(tbSourceFramebufferSupportsNativeCapture(
            preset: .native5k, pixelWidth: 5120, pixelHeight: 3200
        ))
        XCTAssertTrue(tbSourceFramebufferSupportsNativeCapture(
            preset: .native5k, pixelWidth: 6016, pixelHeight: 3384
        ))
        XCTAssertTrue(tbSourceFramebufferSupportsNativeCapture(
            preset: .standard1440p, pixelWidth: 1920, pixelHeight: 1080
        ))
    }

    func testBC7RenderAckCarriesRenderedDimensions() throws {
        var payload = Data()
        TBMonitorProtocol.appendBE32(&payload, 7)
        TBMonitorProtocol.appendBE32(&payload, 2560)
        TBMonitorProtocol.appendBE32(&payload, 1440)
        var stream = TBMonitorProtocol.makePacket(type: .bc7RenderAck, payload: payload)

        let (type, decodedPayload) = try XCTUnwrap(TBMonitorProtocol.drainPacket(from: &stream))
        XCTAssertEqual(type, .bc7RenderAck)
        XCTAssertEqual(TBMonitorProtocol.readBE32(decodedPayload, offset: 0), 7)
        XCTAssertEqual(TBMonitorProtocol.readBE32(decodedPayload, offset: 4), 2560)
        XCTAssertEqual(TBMonitorProtocol.readBE32(decodedPayload, offset: 8), 1440)
        XCTAssertTrue(stream.isEmpty)
    }

    func testExplicitVideoTransportRequiresMatchingReceiverCapability() throws {
        let unsupported = try JSONDecoder().decode(
            TBMonitorDisplayProfile.self,
            from: Data("""
            {
              "receiverName": "Older Receiver",
              "panelWidth": 5120,
              "panelHeight": 2880,
              "modeWidth": 2560,
              "modeHeight": 1440,
              "refreshRate": 60,
              "hiDPI": true,
              "captureWidth": 5120,
              "captureHeight": 2880
            }
            """.utf8)
        )
        XCTAssertTrue(TBVideoTransportMode.automatic.isSupported(by: unsupported))
        XCTAssertFalse(TBVideoTransportMode.bc7Mode6.isSupported(by: unsupported))
        XCTAssertFalse(TBVideoTransportMode.rawNV12.isSupported(by: unsupported))

        var supported = unsupported
        supported.supportsBC7Mode6 = true
        supported.supportsRawNV12 = true
        XCTAssertTrue(TBVideoTransportMode.bc7Mode6.isSupported(by: supported))
        XCTAssertTrue(TBVideoTransportMode.rawNV12.isSupported(by: supported))
    }

    func testMetalBC7Mode6EncoderProducesDecodableBlock() throws {
        let pixelBuffer = try makeBGRAPixelBuffer(width: 4, height: 4) { x, y in
            let value = UInt8((y * 4 + x) * 17)
            return (value, value, value, 255)
        }

        let encoder = try XCTUnwrap(TBBC7Mode6Encoder())
        let encoded = try XCTUnwrap(encoder.encode(pixelBuffer: pixelBuffer))
        XCTAssertEqual(encoded.bytesPerRow, 16)
        XCTAssertEqual(encoded.data.count, 16)

        let decoded = try decodeBC7Mode6Block(encoded.data)
        for index in 0..<16 {
            let expected = index * 17
            XCTAssertLessThanOrEqual(abs(decoded[index][0] - expected), 10)
            XCTAssertLessThanOrEqual(abs(decoded[index][1] - expected), 10)
            XCTAssertLessThanOrEqual(abs(decoded[index][2] - expected), 10)
            XCTAssertLessThanOrEqual(abs(decoded[index][3] - 255), 1)
        }
    }

    func testMetalBC7Mode6EncoderPreservesMultiBlockOrdering() throws {
        let colors: [(UInt8, UInt8, UInt8, UInt8)] = [
            (255, 0, 0, 255),
            (0, 255, 0, 255),
            (0, 0, 255, 255),
            (255, 255, 255, 255)
        ]
        let pixelBuffer = try makeBGRAPixelBuffer(width: 8, height: 8) { x, y in
            colors[(y / 4) * 2 + (x / 4)]
        }

        let encoder = try XCTUnwrap(TBBC7Mode6Encoder())
        let encoded = try XCTUnwrap(encoder.encode(pixelBuffer: pixelBuffer))
        XCTAssertEqual(encoded.bytesPerRow, 32)
        XCTAssertEqual(encoded.data.count, 64)

        for blockIndex in 0..<4 {
            let start = blockIndex * 16
            let decoded = try decodeBC7Mode6Block(encoded.data.subdata(in: start..<(start + 16)))
            let expected = colors[blockIndex]
            for pixel in decoded {
                XCTAssertLessThanOrEqual(abs(pixel[0] - Int(expected.0)), 1)
                XCTAssertLessThanOrEqual(abs(pixel[1] - Int(expected.1)), 1)
                XCTAssertLessThanOrEqual(abs(pixel[2] - Int(expected.2)), 1)
                XCTAssertLessThanOrEqual(abs(pixel[3] - Int(expected.3)), 1)
            }
        }
    }

    func testMetalBC7Mode6EncoderIsDeterministicAcrossBufferReuse() throws {
        let pixelBuffer = try makeBGRAPixelBuffer(width: 8, height: 8) { x, y in
            let value = UInt8(truncatingIfNeeded: x &* 73 &+ y &* 151 &+ x &* y &* 19)
            return (value, value, value, 255)
        }
        let encoder = try XCTUnwrap(TBBC7Mode6Encoder())
        let first = try XCTUnwrap(encoder.encode(pixelBuffer: pixelBuffer))
        let second = try XCTUnwrap(encoder.encode(pixelBuffer: pixelBuffer))
        XCTAssertEqual(first.bytesPerRow, 32)
        XCTAssertEqual(first.data, second.data)

        for blockIndex in 0..<4 {
            let start = blockIndex * 16
            let decoded = try decodeBC7Mode6Block(first.data.subdata(in: start..<(start + 16)))
            for localIndex in 0..<16 {
                let blockX = blockIndex % 2
                let blockY = blockIndex / 2
                let x = blockX * 4 + localIndex % 4
                let y = blockY * 4 + localIndex / 4
                let expected = Int(UInt8(truncatingIfNeeded: x &* 73 &+ y &* 151 &+ x &* y &* 19))
                XCTAssertLessThanOrEqual(abs(decoded[localIndex][0] - expected), 10)
                XCTAssertLessThanOrEqual(abs(decoded[localIndex][1] - expected), 10)
                XCTAssertLessThanOrEqual(abs(decoded[localIndex][2] - expected), 10)
            }
        }
    }

    func testMetalBC7Mode6EncoderUpdatesOnlyDirtyTiles() throws {
        let width = 128
        let height = 64
        let initial = try makeBGRAPixelBuffer(width: width, height: height) { _, _ in
            (0, 0, 0, 255)
        }
        let updated = try makeBGRAPixelBuffer(width: width, height: height) { x, y in
            if x < 4 && y < 4 {
                return (0, 0, 255, 255)
            }
            return x < 64 ? (0, 0, 0, 255) : (255, 255, 255, 255)
        }
        let encoder = try XCTUnwrap(TBBC7Mode6Encoder())
        let first = try XCTUnwrap(encoder.encode(pixelBuffer: initial))
        let second = try XCTUnwrap(encoder.encode(
            pixelBuffer: updated,
            dirtyRects: [CGRect(x: 64, y: 0, width: 64, height: 64)]
        ))

        XCTAssertEqual(second.candidateDirtyTiles, Set([1]))
        XCTAssertEqual(try XCTUnwrap(second.tileAnalysis).dirtyTiles, Set([1]))
        XCTAssertEqual(try XCTUnwrap(second.tileAnalysis).checksums.count, 2)
        XCTAssertEqual(first.data.subdata(in: 0..<16), second.data.subdata(in: 0..<16))
        XCTAssertNotEqual(first.data.subdata(in: 256..<272), second.data.subdata(in: 256..<272))
        XCTAssertNil(encoder.encode(pixelBuffer: updated, dirtyRects: []))
        let deferredPass = try XCTUnwrap(encoder.encode(
            pixelBuffer: updated,
            dirtyRects: [],
            allowEmptyDirtyPlan: true
        ))
        XCTAssertEqual(deferredPass.data, second.data)
        XCTAssertNotNil(deferredPass.tileAnalysis)
    }

    func testMetalTileAnalysisMatchesCPUPlannerChecksum() throws {
        let width = 128
        let height = 64
        let pixelBuffer = try makeBGRAPixelBuffer(width: width, height: height) { x, y in
            let value = UInt8(truncatingIfNeeded: x &* 17 &+ y &* 29)
            return (value, 255 &- value, value / 2, 255)
        }
        let encoder = try XCTUnwrap(TBBC7Mode6Encoder())
        let encoded = try XCTUnwrap(encoder.encode(pixelBuffer: pixelBuffer))
        let analysis = try XCTUnwrap(encoded.tileAnalysis)

        let cpuPlanner = TBBC7DeltaPlanner(keyframeIntervalFrames: 120)
        let gpuPlanner = TBBC7DeltaPlanner(keyframeIntervalFrames: 120)
        guard case .keyframe(_, let cpuChecksum, _) = try XCTUnwrap(cpuPlanner.plan(
            current: encoded.data,
            width: width,
            height: height,
            bytesPerRow: encoded.bytesPerRow
        )), case .keyframe(_, let gpuChecksum, _) = try XCTUnwrap(gpuPlanner.plan(
            current: encoded.data,
            width: width,
            height: height,
            bytesPerRow: encoded.bytesPerRow,
            candidateDirtyTiles: encoded.candidateDirtyTiles,
            analyzedDirtyTiles: analysis.dirtyTiles,
            analyzedChecksums: analysis.checksums
        )) else {
            return XCTFail("first analyzed frame must be a keyframe")
        }
        XCTAssertEqual(gpuChecksum, cpuChecksum)

        let updatedPixelBuffer = try makeBGRAPixelBuffer(
            width: width,
            height: height
        ) { x, y in
            if x >= 64 {
                return (UInt8(20), UInt8(40), UInt8(220), UInt8(255))
            }
            let value = UInt8(truncatingIfNeeded: x &* 17 &+ y &* 29)
            return (value, 255 &- value, value / 2, 255)
        }
        let updated = try XCTUnwrap(encoder.encode(
            pixelBuffer: updatedPixelBuffer,
            dirtyRects: [CGRect(x: 64, y: 0, width: 64, height: 64)]
        ))
        let updatedAnalysis = try XCTUnwrap(updated.tileAnalysis)
        guard case .delta(_, _, let cpuDeltaChecksum, let cpuRuns, _, _) =
            try XCTUnwrap(cpuPlanner.plan(
                current: updated.data,
                width: width,
                height: height,
                bytesPerRow: updated.bytesPerRow,
                candidateDirtyTiles: updated.candidateDirtyTiles
            )), case .delta(_, _, let gpuDeltaChecksum, let gpuRuns, _, _) =
            try XCTUnwrap(gpuPlanner.plan(
                current: updated.data,
                width: width,
                height: height,
                bytesPerRow: updated.bytesPerRow,
                candidateDirtyTiles: updated.candidateDirtyTiles,
                analyzedDirtyTiles: updatedAnalysis.dirtyTiles,
                analyzedChecksums: updatedAnalysis.checksums
            )) else {
            return XCTFail("updated analyzed frame must remain a delta")
        }
        XCTAssertEqual(updatedAnalysis.dirtyTiles, Set([1]))
        XCTAssertEqual(gpuDeltaChecksum, cpuDeltaChecksum)
        XCTAssertEqual(gpuRuns, cpuRuns)
    }

    func testMetalBC7Mode6EncoderRejectsUnsupportedPixelBuffers() throws {
        let encoder = try XCTUnwrap(TBBC7Mode6Encoder())
        let unaligned = try makeBGRAPixelBuffer(width: 5, height: 4) { _, _ in
            (0, 0, 0, 255)
        }
        XCTAssertNil(encoder.encode(pixelBuffer: unaligned))

        var nv12: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                4,
                4,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                nil,
                &nv12
            ),
            kCVReturnSuccess
        )
        XCTAssertNil(encoder.encode(pixelBuffer: try XCTUnwrap(nv12)))
    }

    func testMetalBC7Mode6FiveKBenchmarkWhenEnabled() throws {
        guard ProcessInfo.processInfo.environment["RUN_BC7_BENCHMARK"] == "1" else {
            throw XCTSkip("Set RUN_BC7_BENCHMARK=1 to run the 5K Metal benchmark")
        }

        let width = 5120
        let height = 2880
        let pixelBuffer = try makeBGRAPixelBuffer(width: width, height: height) { x, y in
            let value = UInt8(truncatingIfNeeded: x &+ y)
            return (value, value, value, 255)
        }
        let encoder = try XCTUnwrap(TBBC7Mode6Encoder())
        let initial = try XCTUnwrap(encoder.encode(pixelBuffer: pixelBuffer))
        XCTAssertEqual(initial.data.count, 14_745_600)

        let fullFrameIterations = 3
        let fullFrameStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<fullFrameIterations {
            _ = try XCTUnwrap(encoder.encode(pixelBuffer: pixelBuffer))
        }
        let fullFrameSeconds =
            Double(DispatchTime.now().uptimeNanoseconds - fullFrameStart) / 1_000_000_000

        let dirtyIterations = 30
        let dirtyStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<dirtyIterations {
            _ = try XCTUnwrap(encoder.encode(
                pixelBuffer: pixelBuffer,
                dirtyRects: [CGRect(x: 0, y: 0, width: 64, height: 64)]
            ))
        }
        let dirtySeconds = Double(DispatchTime.now().uptimeNanoseconds - dirtyStart) / 1_000_000_000
        print(
            String(
                format: "BC7 5K benchmark: full %.3f ms/frame, one-tile %.3f ms/frame",
                fullFrameSeconds * 1_000 / Double(fullFrameIterations),
                dirtySeconds * 1_000 / Double(dirtyIterations)
            )
        )
    }

    func testLatestFrameSlotCoalescesQueuedFrames() {
        let slot = TBLatestFrameSlot<Int>()

        XCTAssertTrue(slot.submit(1))
        XCTAssertFalse(slot.submit(2))
        XCTAssertFalse(slot.submit(3))
        XCTAssertEqual(slot.droppedCount, 2)
        XCTAssertEqual(slot.take(), 3)
        XCTAssertFalse(slot.finishProcessing())

        XCTAssertTrue(slot.submit(4))
        XCTAssertEqual(slot.take(), 4)
        XCTAssertFalse(slot.finishProcessing())
    }

    func testLatestFrameSlotAtomicallyReturnsDropGeneration() {
        let slot = TBLatestFrameSlot<Int>()
        XCTAssertTrue(slot.submit(1))
        XCTAssertFalse(slot.submit(2))
        XCTAssertFalse(slot.submit(3))
        let taken = slot.takeWithDroppedCount()
        XCTAssertEqual(taken.value, 3)
        XCTAssertEqual(taken.droppedCount, 2)
        XCTAssertFalse(slot.finishProcessing())
    }

    func testLatestFrameSlotRecoveryDoesNotReplaceNewerPendingFrame() {
        let slot = TBLatestFrameSlot<Int>()
        XCTAssertTrue(slot.submit(1))
        XCTAssertEqual(slot.take(), 1)
        XCTAssertFalse(slot.submit(2))
        let recovery = slot.submitIfEmpty(1)
        XCTAssertFalse(recovery.inserted)
        XCTAssertFalse(recovery.shouldSchedule)
        XCTAssertEqual(slot.take(), 2)
        XCTAssertFalse(slot.finishProcessing())
    }

    private func makeBGRAPixelBuffer(
        width: Int,
        height: Int,
        pixel: (_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8)
    ) throws -> CVPixelBuffer {
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        var optionalPixelBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                attributes as CFDictionary,
                &optionalPixelBuffer
            ),
            kCVReturnSuccess
        )
        let pixelBuffer = try XCTUnwrap(optionalPixelBuffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer))
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let value = pixel(x, y)
                row[x * 4 + 0] = value.2
                row[x * 4 + 1] = value.1
                row[x * 4 + 2] = value.0
                row[x * 4 + 3] = value.3
            }
        }
        return pixelBuffer
    }

    private func decodeBC7Mode6Block(_ data: Data) throws -> [[Int]] {
        XCTAssertEqual(data.count, 16)
        let bytes = [UInt8](data)
        var bitPosition = 0

        func readBits(_ count: Int) -> Int {
            var value = 0
            for bit in 0..<count {
                let source = bitPosition + bit
                value |= Int((bytes[source / 8] >> UInt8(source % 8)) & 1) << bit
            }
            bitPosition += count
            return value
        }

        XCTAssertEqual(readBits(7), 1 << 6)
        var endpoint0 = [Int](repeating: 0, count: 4)
        var endpoint1 = [Int](repeating: 0, count: 4)
        for channel in 0..<4 {
            endpoint0[channel] = readBits(7)
            endpoint1[channel] = readBits(7)
        }
        let pbit0 = readBits(1)
        let pbit1 = readBits(1)
        for channel in 0..<4 {
            endpoint0[channel] = endpoint0[channel] * 2 + pbit0
            endpoint1[channel] = endpoint1[channel] * 2 + pbit1
        }

        var indices = [readBits(3)]
        for _ in 1..<16 {
            indices.append(readBits(4))
        }
        XCTAssertEqual(bitPosition, 128)

        let weights = [0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64]
        return indices.map { index in
            let weight = weights[index]
            return (0..<4).map { channel in
                (endpoint0[channel] * (64 - weight) + endpoint1[channel] * weight + 32) >> 6
            }
        }
    }

    func testDrainPacketRoundTrip() throws {
        let payload = Data("hello receiver".utf8)
        var buffer = TBMonitorProtocol.makePacket(type: .helloReceiver, payload: payload)

        let drained = try TBMonitorProtocol.drainPacket(from: &buffer)
        XCTAssertNotNil(drained)
        XCTAssertEqual(drained?.0, .helloReceiver)
        XCTAssertEqual(drained?.1, payload)
        XCTAssertTrue(buffer.isEmpty, "drain must consume the packet")
    }

    func testDrainPacketEmptyPayload() throws {
        var buffer = TBMonitorProtocol.makePacket(type: .teardown, payload: Data())
        let drained = try TBMonitorProtocol.drainPacket(from: &buffer)
        XCTAssertEqual(drained?.0, .teardown)
        XCTAssertEqual(drained?.1, Data())
        XCTAssertTrue(buffer.isEmpty)
    }

    func testDrainPacketWaitsForCompleteHeader() {
        var buffer = Data([0x00, 0x00, 0x00, 0x04]) // header missing its 5th byte
        XCTAssertNil(try TBMonitorProtocol.drainPacket(from: &buffer))
        XCTAssertEqual(buffer.count, 4, "incomplete data must not be consumed")
    }

    func testDrainPacketWaitsForCompletePayload() {
        let full = TBMonitorProtocol.makePacket(type: .frame, payload: Data(repeating: 0x42, count: 100))
        var buffer = full.prefix(50) as Data
        XCTAssertNil(try TBMonitorProtocol.drainPacket(from: &buffer))
        XCTAssertEqual(buffer.count, 50, "incomplete data must not be consumed")
    }

    func testDrainTwoContiguousPackets() throws {
        var buffer = TBMonitorProtocol.makePacket(type: .cursor, payload: Data([0x01]))
        buffer.append(TBMonitorProtocol.makePacket(type: .brightness, payload: Data([0x02, 0x03])))

        let first = try TBMonitorProtocol.drainPacket(from: &buffer)
        XCTAssertEqual(first?.0, .cursor)
        XCTAssertEqual(first?.1, Data([0x01]))

        let second = try TBMonitorProtocol.drainPacket(from: &buffer)
        XCTAssertEqual(second?.0, .brightness)
        XCTAssertEqual(second?.1, Data([0x02, 0x03]))

        XCTAssertTrue(buffer.isEmpty)
    }

    /// Simulates TCP fragmentation: the packet arrives one byte at a time and
    /// must only drain once the final byte lands.
    func testDrainPacketAcrossSplitFeeds() throws {
        let packet = TBMonitorProtocol.makePacket(type: .clipboard, payload: Data("copy me".utf8))
        var buffer = Data()

        for (index, byte) in packet.enumerated() {
            buffer.append(byte)
            let drained = try TBMonitorProtocol.drainPacket(from: &buffer)
            if index < packet.count - 1 {
                XCTAssertNil(drained, "must not drain before byte \(packet.count - 1), drained at \(index)")
            } else {
                XCTAssertEqual(drained?.0, .clipboard)
                XCTAssertEqual(drained?.1, Data("copy me".utf8))
            }
        }
    }

    // MARK: - Corrupt and unknown framing

    func testDrainPacketThrowsOnZeroLength() {
        var buffer = Data([0x00, 0x00, 0x00, 0x00, 0x30])
        XCTAssertThrowsError(try TBMonitorProtocol.drainPacket(from: &buffer)) { error in
            XCTAssertEqual(error as? TBMonitorProtocolError, .invalidPacketLength(0))
        }
    }

    func testDrainPacketThrowsOnOversizedLength() {
        var buffer = Data()
        TBMonitorProtocol.appendBE32(&buffer, TBMonitorProtocol.maxPacketLength + 1)
        buffer.append(0x21)
        XCTAssertThrowsError(try TBMonitorProtocol.drainPacket(from: &buffer)) { error in
            XCTAssertEqual(error as? TBMonitorProtocolError, .invalidPacketLength(TBMonitorProtocol.maxPacketLength + 1))
        }
    }

    /// A corrupted length like 0xFFFFFFFF must fail fast instead of making the
    /// drain loop buffer inbound data forever for a packet that never completes.
    func testDrainPacketThrowsOnAllOnesLength() {
        var buffer = Data([0xFF, 0xFF, 0xFF, 0xFF, 0x21, 0x00])
        XCTAssertThrowsError(try TBMonitorProtocol.drainPacket(from: &buffer)) { error in
            XCTAssertEqual(error as? TBMonitorProtocolError, .invalidPacketLength(0xFFFF_FFFF))
        }
    }

    func testDrainPacketAcceptsLengthAtCapWhileWaitingForPayload() {
        var buffer = Data()
        TBMonitorProtocol.appendBE32(&buffer, TBMonitorProtocol.maxPacketLength)
        buffer.append(0x21)
        // Length is legal but the payload has not arrived: need more data, no throw.
        XCTAssertNil(try TBMonitorProtocol.drainPacket(from: &buffer))
        XCTAssertEqual(buffer.count, 5)
    }

    func testDrainPacketThrowsOnCorruptLengthBehindValidPacket() throws {
        var buffer = TBMonitorProtocol.makePacket(type: .heartbeat, payload: Data([0x01]))
        buffer.append(Data([0xFF, 0xFF, 0xFF, 0xFF, 0x21]))

        let first = try TBMonitorProtocol.drainPacket(from: &buffer)
        XCTAssertEqual(first?.0, .heartbeat)

        XCTAssertThrowsError(try TBMonitorProtocol.drainPacket(from: &buffer))
    }

    /// An unrecognized type byte (e.g. a packet from a newer peer) must be
    /// skipped so it cannot stall valid packets queued behind it.
    func testDrainPacketSkipsUnknownTypeAndReturnsNextPacket() throws {
        var buffer = Data()
        TBMonitorProtocol.appendBE32(&buffer, 3)
        buffer.append(contentsOf: [0xEE, 0x00, 0x00]) // unknown type 0xEE + 2 payload bytes
        buffer.append(TBMonitorProtocol.makePacket(type: .heartbeat, payload: Data([0x07])))

        let drained = try TBMonitorProtocol.drainPacket(from: &buffer)
        XCTAssertEqual(drained?.0, .heartbeat)
        XCTAssertEqual(drained?.1, Data([0x07]))
        XCTAssertTrue(buffer.isEmpty)
    }

    func testDrainPacketConsumesLoneUnknownType() throws {
        var buffer = Data()
        TBMonitorProtocol.appendBE32(&buffer, 1)
        buffer.append(0xEE)

        XCTAssertNil(try TBMonitorProtocol.drainPacket(from: &buffer))
        XCTAssertTrue(buffer.isEmpty, "unknown packet must be consumed, not left to stall the stream")
    }

    // MARK: - JSON payloads

    func testJSONPacketRoundTrip() throws {
        let heartbeat = TBMonitorHeartbeat(sequence: 42)
        guard var buffer = TBMonitorProtocol.makeJSONPacket(type: .heartbeat, value: heartbeat) else {
            XCTFail("encode failed"); return
        }
        guard let (type, payload) = try TBMonitorProtocol.drainPacket(from: &buffer) else {
            XCTFail("drain failed"); return
        }
        XCTAssertEqual(type, .heartbeat)
        XCTAssertEqual(TBMonitorProtocol.decodeJSON(TBMonitorHeartbeat.self, from: payload)?.sequence, 42)
    }

    // MARK: - Hand-rolled input-event encoder parity
    //
    // `makeInputEventPacket` documents this invariant: "emits the same JSON shape
    // `JSONDecoder` reconstructs into a `TBMonitorInputEvent` (omitted fields
    // decode as nil)". These tests guard it, since the receiver's snprintf-based
    // emitter mirrors the same shape.

    private func makeEvent(
        kind: String,
        dx: Int? = nil,
        dy: Int? = nil,
        scrollX: Int? = nil,
        scrollY: Int? = nil,
        keyCode: UInt16? = nil
    ) -> TBMonitorInputEvent {
        TBMonitorInputEvent(kind: kind, dx: dx, dy: dy, scrollX: scrollX, scrollY: scrollY, keyCode: keyCode)
    }

    private func assertEncoderParity(
        _ event: TBMonitorInputEvent,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var buffer = TBMonitorProtocol.makeInputEventPacket(event)
        guard let (type, payload) = try? TBMonitorProtocol.drainPacket(from: &buffer) ?? nil else {
            XCTFail("packet did not drain", file: file, line: line)
            return
        }
        XCTAssertEqual(type, .inputEvent, file: file, line: line)
        guard let decoded = TBMonitorProtocol.decodeJSON(TBMonitorInputEvent.self, from: payload) else {
            XCTFail("payload did not decode as TBMonitorInputEvent: \(String(decoding: payload, as: UTF8.self))",
                    file: file, line: line)
            return
        }
        XCTAssertEqual(decoded.kind, event.kind, file: file, line: line)
        XCTAssertEqual(decoded.dx, event.dx, file: file, line: line)
        XCTAssertEqual(decoded.dy, event.dy, file: file, line: line)
        XCTAssertEqual(decoded.scrollX, event.scrollX, file: file, line: line)
        XCTAssertEqual(decoded.scrollY, event.scrollY, file: file, line: line)
        XCTAssertEqual(decoded.keyCode, event.keyCode, file: file, line: line)
    }

    func testInputEventEncoderParityMouseMove() {
        assertEncoderParity(makeEvent(kind: "move", dx: 5, dy: -3))
    }

    func testInputEventEncoderParityScroll() {
        assertEncoderParity(makeEvent(kind: "scroll", scrollX: -120, scrollY: 42))
    }

    func testInputEventEncoderParityKeyDown() {
        assertEncoderParity(makeEvent(kind: "keyDown", keyCode: 0x24))
    }

    func testInputEventEncoderParityAllFields() {
        assertEncoderParity(makeEvent(kind: "drag", dx: 1, dy: 2, scrollX: 3, scrollY: 4, keyCode: UInt16.max))
    }

    func testInputEventEncoderParityNoOptionalFields() {
        assertEncoderParity(makeEvent(kind: "leftUp"))
    }

    func testInputEventEncoderParityExtremeValues() {
        assertEncoderParity(makeEvent(kind: "move", dx: Int.min, dy: Int.max))
    }
}
