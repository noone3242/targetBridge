import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import AVFoundation
import IOSurface
import Metal
import Network
@preconcurrency import ScreenCaptureKit
import VideoToolbox

enum TBReceiverStateUpdate: Equatable {
    case hello
    case inputControlMode
    case brightness
    case volume

    static let automaticOnConnect: [Self] = [
        .hello,
        .inputControlMode,
        .brightness
    ]
}

func tbShouldReleaseSessionOnNetworkWait(
    isConnected: Bool,
    transportKind: TBTransportKind
) -> Bool {
    isConnected && transportKind == .thunderboltBridge
}

func tbConnectionStartedTimestamp(
    _ date: Date?,
    calendar: Calendar = .current
) -> String {
    guard let date else { return "—" }
    let components = calendar.dateComponents(
        [.year, .month, .day, .hour, .minute, .second],
        from: date
    )
    return String(
        format: "%04d-%02d-%02d %02d:%02d:%02d",
        components.year ?? 0,
        components.month ?? 0,
        components.day ?? 0,
        components.hour ?? 0,
        components.minute ?? 0,
        components.second ?? 0
    )
}

func tbConnectionStartedClockTime(
    _ date: Date?,
    calendar: Calendar = .current
) -> String {
    guard let date else { return "—" }
    let components = calendar.dateComponents(
        [.hour, .minute, .second],
        from: date
    )
    return String(
        format: "%02d:%02d:%02d",
        components.hour ?? 0,
        components.minute ?? 0,
        components.second ?? 0
    )
}

struct TBSessionCloseContext: Equatable, Sendable {
    let reason: String
    let category: String
    let detail: String?
    let notifyPeer: Bool

    static let userStop = TBSessionCloseContext(
        reason: "user_stop",
        category: "user",
        detail: "Stop requested by user",
        notifyPeer: true
    )

    static let appQuit = TBSessionCloseContext(
        reason: "app_quit",
        category: "shutdown",
        detail: "Sender application terminating",
        notifyPeer: true
    )

    static let remoteSignal = TBSessionCloseContext(
        reason: "remote_teardown",
        category: "transport",
        detail: "Receiver sent teardown",
        notifyPeer: false
    )

    static func appError(_ reason: String, detail: String) -> Self {
        TBSessionCloseContext(
            reason: reason,
            category: "app_error",
            detail: detail,
            notifyPeer: true
        )
    }

    static func transport(
        _ reason: String,
        detail: String,
        notifyPeer: Bool = false
    ) -> Self {
        TBSessionCloseContext(
            reason: reason,
            category: "transport",
            detail: detail,
            notifyPeer: notifyPeer
        )
    }

    static func liveness(
        _ reason: String,
        detail: String,
        notifyPeer: Bool = true
    ) -> Self {
        TBSessionCloseContext(
            reason: reason,
            category: "liveness",
            detail: detail,
            notifyPeer: notifyPeer
        )
    }

    static func test(_ reason: String, detail: String) -> Self {
        TBSessionCloseContext(
            reason: reason,
            category: "test",
            detail: detail,
            notifyPeer: true
        )
    }
}

struct TBSessionLogEntry: Identifiable, Equatable {
    let id: UUID
    let timestamp: String
    let message: String
}

func tbAppendingSessionLogEntry(
    to entries: [TBSessionLogEntry],
    message: String,
    timestamp: String,
    capacity: Int = 80
) -> [TBSessionLogEntry] {
    guard entries.last?.message != message else { return entries }
    let appended = entries + [
        TBSessionLogEntry(id: UUID(), timestamp: timestamp, message: message)
    ]
    return Array(appended.suffix(max(1, capacity)))
}

enum TBVideoTransportMode: String, CaseIterable, Identifiable {
    case automatic
    case bc7Mode6
    case rawNV12

    var id: String { rawValue }

    func title(_ language: TBDisplaySenderLanguage) -> String {
        switch (self, language) {
        case (.automatic, .italian): return "Automatico (H.264 / HEVC)"
        case (.automatic, .english): return "Automatic (H.264 / HEVC)"
        case (.automatic, .german): return "Automatisch (H.264 / HEVC)"
        case (.automatic, .french): return "Automatique (H.264 / HEVC)"
        case (.automatic, .chinese): return "自动（H.264 / HEVC）"
        case (.bc7Mode6, _): return "BC7 Mode 6 (Experimental)"
        case (.rawNV12, .italian): return "NV12 raw (diagnostica)"
        case (.rawNV12, .english): return "Raw NV12 (diagnostic)"
        case (.rawNV12, .german): return "Raw NV12 (Diagnose)"
        case (.rawNV12, .french): return "NV12 brut (diagnostic)"
        case (.rawNV12, .chinese): return "Raw NV12（诊断）"
        }
    }

    func codecName(for preset: TBDisplayCapturePreset) -> String {
        switch self {
        case .automatic: return preset.codecName
        case .bc7Mode6: return "BC7 Mode 6"
        case .rawNV12: return "NV12 RAW"
        }
    }

    func isSupported(by profile: TBMonitorDisplayProfile) -> Bool {
        switch self {
        case .automatic: return true
        case .bc7Mode6: return profile.supportsBC7Mode6 == true
        case .rawNV12: return profile.supportsRawNV12 == true
        }
    }
}

enum TBDisplayCapturePreset: String, CaseIterable, Identifiable {
    case standard1440p
    case smooth1440p60
    case smooth1800p60
    case crisp2160p60
    case native5k
    case native5k60Experimental

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard1440p:
            return "Standard"
        case .smooth1440p60:
            return "Smooth"
        case .smooth1800p60:
            return "Smooth+"
        case .crisp2160p60:
            return "Crisp"
        case .native5k:
            return "5K"
        case .native5k60Experimental:
            return "5K 60 Experimental"
        }
    }

    var description: String {
        switch self {
        case .standard1440p:
            return "2560 × 1440"
        case .smooth1440p60:
            return "2560 × 1440 @ 60"
        case .smooth1800p60:
            return "3200 × 1800 @ 60"
        case .crisp2160p60:
            return "3840 × 2160 @ 60"
        case .native5k:
            return "5120 × 2880 @ 48"
        case .native5k60Experimental:
            return "5120 × 2880 @ 60"
        }
    }

    var width: Int {
        switch self {
        case .standard1440p, .smooth1440p60:
            return 2560
        case .smooth1800p60:
            return 3200
        case .crisp2160p60:
            return 3840
        case .native5k, .native5k60Experimental:
            return 5120
        }
    }

    var height: Int {
        switch self {
        case .standard1440p, .smooth1440p60:
            return 1440
        case .smooth1800p60:
            return 1800
        case .crisp2160p60:
            return 2160
        case .native5k, .native5k60Experimental:
            return 2880
        }
    }

    var averageBitRate: Int {
        switch self {
        case .standard1440p:
            return 36_000_000
        case .smooth1440p60:
            return 52_000_000
        case .smooth1800p60:
            return 78_000_000
        case .crisp2160p60:
            return 105_000_000
        case .native5k:
            return 120_000_000
        case .native5k60Experimental:
            return 150_000_000
        }
    }

    var codecName: String {
        switch self {
        case .standard1440p, .smooth1440p60, .smooth1800p60:
            return "H.264"
        case .crisp2160p60, .native5k, .native5k60Experimental:
            return "HEVC"
        }
    }

    var codecType: CMVideoCodecType {
        switch self {
        case .standard1440p, .smooth1440p60, .smooth1800p60:
            return kCMVideoCodecType_H264
        case .crisp2160p60, .native5k, .native5k60Experimental:
            return kCMVideoCodecType_HEVC
        }
    }

    var queueDepth: Int {
        if let envVal = ProcessInfo.processInfo.environment["QD"], let parsed = Int(envVal) {
            return parsed
        }
        return 2
    }

    var expectedFrameRate: Int {
        switch self {
        case .standard1440p:
            return 30
        case .smooth1440p60:
            return 60
        case .smooth1800p60:
            return 60
        case .crisp2160p60:
            return 60
        case .native5k:
            return 48
        case .native5k60Experimental:
            return 60
        }
    }

    var maxKeyFrameInterval: Int {
        switch self {
        case .standard1440p:
            return 60
        case .smooth1440p60:
            return 60
        case .smooth1800p60:
            return 60
        case .crisp2160p60:
            return 60
        case .native5k:
            return 48
        case .native5k60Experimental:
            return 60
        }
    }

    var maxKeyFrameIntervalDuration: Int {
        switch self {
        case .standard1440p:
            return 2
        case .smooth1440p60:
            return 1
        case .smooth1800p60, .crisp2160p60:
            return 1
        case .native5k, .native5k60Experimental:
            return 1
        }
    }

    var prioritizeSpeed: Bool {
        switch self {
        case .standard1440p:
            return false
        case .smooth1440p60, .smooth1800p60, .crisp2160p60, .native5k, .native5k60Experimental:
            return true
        }
    }

    var maxPendingVideoPackets: Int {
        if let envVal = ProcessInfo.processInfo.environment["MPVP"], let parsed = Int(envVal) {
            return parsed
        }
        return 3
    }

    var maxFrameDelayCount: Int {
        switch self {
        case .standard1440p:
            return 1
        case .smooth1440p60, .smooth1800p60, .crisp2160p60, .native5k, .native5k60Experimental:
            return 0
        }
    }

    var dropsBeforeEncodeWhenBacklogged: Bool {
        switch self {
        case .standard1440p:
            return false
        case .smooth1440p60, .smooth1800p60, .crisp2160p60, .native5k, .native5k60Experimental:
            return true
        }
    }

    var maxInFlightEncodeFrames: Int {
        if let envVal = ProcessInfo.processInfo.environment["MIFEF"], let parsed = Int(envVal) {
            return parsed
        }
        return 5
    }

    var captureResolution: SCCaptureResolutionType {
        switch self {
        case .standard1440p, .smooth1440p60, .smooth1800p60:
            return .nominal
        case .crisp2160p60, .native5k, .native5k60Experimental:
            return .best
        }
    }

    var virtualDisplayRefreshRate: Double {
        switch self {
        case .standard1440p:
            return 60
        case .smooth1440p60, .smooth1800p60:
            return 60
        case .crisp2160p60:
            return 60
        case .native5k:
            return 48
        case .native5k60Experimental:
            return 60
        }
    }

    /// Virtual display mode that makes the HiDPI backing framebuffer equal the
    /// stream resolution.
    ///
    /// Costs screen real estate: the desktop reports "looks like w/2 x h/2" rather
    /// than the receiver's default 2560 x 1440.
    var renderMatchedDisplayMode: TBVirtualDisplayModeSize {
        TBVirtualDisplayModeSize(width: width / 2, height: height / 2)
    }

    /// Logical desktop size the user ends up with under render matching.
    var renderMatchedDesktopDescription: String {
        "\(width / 2) × \(height / 2)"
    }
}

func tbSourceFramebufferSupportsNativeCapture(
    preset: TBDisplayCapturePreset,
    pixelWidth: Int,
    pixelHeight: Int
) -> Bool {
    guard preset == .native5k || preset == .native5k60Experimental else { return true }
    return pixelWidth >= preset.width &&
        pixelHeight >= preset.height &&
        pixelWidth * preset.height == pixelHeight * preset.width
}

enum TBDisplayCaptureSource: String, CaseIterable, Identifiable {
    case desktopMirror
    case extendedDesktop

    var id: String { rawValue }

    func title(_ language: TBDisplaySenderLanguage) -> String {
        switch self {
        case .desktopMirror:
            return TBDisplaySenderL10n.text("sender.source.desktop_mirror", language)
        case .extendedDesktop:
            return TBDisplaySenderL10n.text("sender.source.extended_desktop", language)
        }
    }

    func virtualDisplayIdentity(receiverKey: String) -> TBVirtualDisplayIdentity {
        switch self {
        case .desktopMirror:
            return .desktopMirror
        case .extendedDesktop:
            return .extendedDesktop(receiverKey: receiverKey)
        }
    }
}

enum TBInputControlRole: String, CaseIterable, Identifiable {
    case off
    case senderMaster
    case receiverMaster

    var id: String { rawValue }
}

enum TBInputGestureMode: String, CaseIterable, Identifiable {
    case native
    case relayToSlave

    var id: String { rawValue }
}

private final class TBDirectDisplayStreamCapture {
    // Strong reference so the pipeline (and its delivery queue) outlives every
    // frame callback — a stray frame must never deref a freed pipeline.
    private let pipeline: TBVideoPipeline
    private let queue: DispatchQueue
    private var stream: CGDisplayStream?
    // CGDisplayStreamStop is asynchronous: frames already in flight keep arriving
    // until the stream delivers a final `.stopped` frame, and releasing the
    // CGDisplayStream before then crashes inside SkyLight's
    // `_CGYDisplayStreamFrameAvailable`. This self-reference keeps the capture
    // object (and the stream) alive from stop() until that `.stopped` frame.
    private var pendingStopRetain: TBDirectDisplayStreamCapture?

    init(pipeline: TBVideoPipeline, queue: DispatchQueue) {
        self.pipeline = pipeline
        self.queue = queue
    }

    func start(displayID: CGDirectDisplayID, preset: TBDisplayCapturePreset, showCursor: Bool) -> Bool {
        let properties: NSDictionary = [
            CGDisplayStream.showCursor: showCursor,
            CGDisplayStream.queueDepth: preset.queueDepth,
            CGDisplayStream.minimumFrameTime: 1.0 / Double(preset.expectedFrameRate)
        ]

        let displayStream = CGDisplayStream(
            dispatchQueueDisplay: displayID,
            outputWidth: preset.width,
            outputHeight: preset.height,
            pixelFormat: Int32(kCVPixelFormatType_32BGRA),
            properties: properties,
            queue: queue
        ) { [weak self] status, displayTime, surface, _ in
            // Delivered on `queue` — the pipeline's own serial queue — so encode
            // runs here, off the main thread, with no extra hop.
            guard let self else { return }
            if status == .stopped {
                // The stream has fully drained; no further frames will arrive, so
                // it is now safe to release the stream and drop the self-retain.
                self.stream = nil
                self.pendingStopRetain = nil
                return
            }
            guard status == .frameComplete, let surface else { return }
            // After pipeline.stop(), encodeDisplaySurface() no-ops on its `running`
            // guard, so a late in-flight frame here is harmless.
            self.pipeline.encodeDisplaySurface(surface, displayTime: displayTime)
        }

        guard let displayStream, displayStream.start() == .success else {
            return false
        }

        stream = displayStream
        return true
    }

    func stop() {
        guard stream != nil else { return }
        // Stay alive until the `.stopped` frame arrives (see pendingStopRetain);
        // the stream is released in the handler, never here, so it is never freed
        // with frame events still queued on `queue`.
        pendingStopRetain = self
        stream?.stop()
    }

    deinit {
        stop()
    }
}

/// Owns the capture→encode→send video pipeline and runs it entirely on a
/// dedicated serial queue, off the main thread. SwiftUI layout (or any other
/// main-thread work) therefore cannot stall frame delivery. All mutable encode
/// state is confined to `queue`; the two values the main thread polls
/// (`sentFrames`, `lastCaptureFrameAt`) are guarded by a small lock instead of
/// a per-frame hop back to main.
struct TBBC7DirtyRegionPlan: Equatable {
    struct Region: Equatable {
        let blockX: Int
        let blockY: Int
        let blockWidth: Int
        let blockHeight: Int
    }

    let regions: [Region]
    let tileIndices: Set<Int>
}

func tbBC7DirtyRegionPlan(
    dirtyRects: [CGRect],
    width: Int,
    height: Int,
    tileSize: Int = TBBC7DeltaPlanner.tileSize
) -> TBBC7DirtyRegionPlan {
    guard width > 0, height > 0, tileSize > 0 else {
        return TBBC7DirtyRegionPlan(regions: [], tileIndices: [])
    }

    let tilesWide = (width + tileSize - 1) / tileSize
    let tilesHigh = (height + tileSize - 1) / tileSize
    var regions: [TBBC7DirtyRegionPlan.Region] = []
    var tileIndices = Set<Int>()

    for rect in dirtyRects where !rect.isNull && !rect.isEmpty {
        let minX = max(0, min(width, Int(floor(rect.minX))))
        let minY = max(0, min(height, Int(floor(rect.minY))))
        let maxX = max(0, min(width, Int(ceil(rect.maxX))))
        let maxY = max(0, min(height, Int(ceil(rect.maxY))))
        guard minX < maxX, minY < maxY else { continue }

        let firstTileX = minX / tileSize
        let firstTileY = minY / tileSize
        let lastTileX = min(tilesWide, (maxX + tileSize - 1) / tileSize)
        let lastTileY = min(tilesHigh, (maxY + tileSize - 1) / tileSize)
        guard firstTileX < lastTileX, firstTileY < lastTileY else { continue }

        for tileY in firstTileY..<lastTileY {
            for tileX in firstTileX..<lastTileX {
                tileIndices.insert(tileY * tilesWide + tileX)
            }
        }

        let pixelX = firstTileX * tileSize
        let pixelY = firstTileY * tileSize
        let pixelMaxX = min(width, lastTileX * tileSize)
        let pixelMaxY = min(height, lastTileY * tileSize)
        regions.append(TBBC7DirtyRegionPlan.Region(
            blockX: pixelX / 4,
            blockY: pixelY / 4,
            blockWidth: (pixelMaxX - pixelX) / 4,
            blockHeight: (pixelMaxY - pixelY) / 4
        ))
    }

    return TBBC7DirtyRegionPlan(regions: regions, tileIndices: tileIndices)
}

func tbBC7PixelDirtyRects(
    dirtyRects: [CGRect],
    outputWidth: Int,
    outputHeight: Int
) -> [CGRect]? {
    let framebuffer = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
    var result: [CGRect] = []
    result.reserveCapacity(dirtyRects.count)
    for rect in dirtyRects {
        guard !rect.isNull else { return nil }
        let clipped = rect.intersection(framebuffer)
        if !clipped.isNull && !clipped.isEmpty {
            result.append(clipped)
        }
    }
    return result
}

func tbCGRect(from value: Any?) -> CGRect? {
    if let rect = value as? CGRect {
        return rect
    }
    if let value = value as? NSValue {
        return value.rectValue
    }
    if let dictionary = value as? NSDictionary {
        return CGRect(dictionaryRepresentation: dictionary)
    }
    return nil
}

func tbBC7DirtyRects(
    from frame: [SCStreamFrameInfo: Any],
    outputWidth: Int,
    outputHeight: Int
) -> [CGRect]? {
    guard let rawRects = frame[.dirtyRects] as? [Any]
    else {
        return nil
    }
    let dirtyRects = rawRects.compactMap(tbCGRect(from:))
    guard dirtyRects.count == rawRects.count else { return nil }
    return tbBC7PixelDirtyRects(
        dirtyRects: dirtyRects,
        outputWidth: outputWidth,
        outputHeight: outputHeight
    )
}

struct TBBC7TileAnalysis {
    let dirtyTiles: Set<Int>
    let checksums: [UInt64]
}

struct TBMetricSummary {
    let count: Int
    let p50: UInt64
    let p95: UInt64
    let p99: UInt64
    let max: UInt64

    static let empty = TBMetricSummary(count: 0, p50: 0, p95: 0, p99: 0, max: 0)
}

struct TBRollingMetricWindow {
    private let capacity: Int
    private var values: [UInt64] = []
    private var nextIndex = 0

    init(capacity: Int = 600) {
        self.capacity = max(1, capacity)
        values.reserveCapacity(self.capacity)
    }

    mutating func record(_ value: UInt64) {
        if values.count < capacity {
            values.append(value)
        } else {
            values[nextIndex] = value
            nextIndex = (nextIndex + 1) % capacity
        }
    }

    func summary() -> TBMetricSummary {
        guard !values.isEmpty else { return .empty }
        let sorted = values.sorted()
        func percentile(_ value: Double) -> UInt64 {
            let index = min(
                sorted.count - 1,
                Int((Double(sorted.count - 1) * value).rounded(.up))
            )
            return sorted[index]
        }
        return TBMetricSummary(
            count: sorted.count,
            p50: percentile(0.50),
            p95: percentile(0.95),
            p99: percentile(0.99),
            max: sorted[sorted.count - 1]
        )
    }
}

final class TBBC7Mode6Encoder {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let tileAnalysisPipeline: MTLComputePipelineState
    private var textureCache: CVMetalTextureCache?
    private var outputBuffer: MTLBuffer?
    private var tileBaselineBuffer: MTLBuffer?
    private var tileChecksumBuffer: MTLBuffer?
    private var tileDirtyBuffer: MTLBuffer?
    private var tileIndexBuffer: MTLBuffer?
    private var outputBufferLength = 0
    private var tileBufferCount = 0
    private var tileIndexCapacity = 0
    private var hasCompleteFrame = false
    private var outputWidth = 0
    private var outputHeight = 0

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    constant uint kWeights[16] = {
        0, 4, 9, 13, 17, 21, 26, 30,
        34, 38, 43, 47, 51, 55, 60, 64
    };

    inline void write_bits(thread uint4 &words, thread uint &bit_pos, uint value, uint count) {
        for (uint bit = 0; bit < count; ++bit) {
            uint dst = bit_pos + bit;
            uint word = dst >> 5;
            uint shift = dst & 31;
            words[word] |= ((value >> bit) & 1u) << shift;
        }
        bit_pos += count;
    }

    inline uint quantize_component(uint value, uint pbit) {
        int quantized = int(round((float(value) - float(pbit)) * 0.5f));
        return uint(clamp(quantized, 0, 127));
    }

    inline uint endpoint_error(uint4 value, uint pbit, thread uint4 &quantized) {
        uint error = 0;
        for (uint channel = 0; channel < 4; ++channel) {
            uint q = quantize_component(value[channel], pbit);
            uint reconstructed = q * 2u + pbit;
            int delta = int(value[channel]) - int(reconstructed);
            error += uint(delta * delta);
            quantized[channel] = q;
        }
        return error;
    }

    inline uint4 choose_quantized_endpoint(uint4 value, thread uint &pbit) {
        uint4 even_quantized;
        uint4 odd_quantized;
        uint even_error = endpoint_error(value, 0u, even_quantized);
        uint odd_error = endpoint_error(value, 1u, odd_quantized);
        if (odd_error < even_error) {
            pbit = 1u;
            return odd_quantized;
        }
        pbit = 0u;
        return even_quantized;
    }

    inline uint4 reconstruct_endpoint(uint4 quantized, uint pbit) {
        return quantized * 2u + pbit;
    }

    inline uint squared_error(uint4 lhs, uint4 rhs) {
        int4 delta = int4(lhs) - int4(rhs);
        return uint(delta.x * delta.x + delta.y * delta.y +
                    delta.z * delta.z + delta.w * delta.w);
    }

    kernel void bc7_mode6_encode(
        texture2d<float, access::read> source [[texture(0)]],
        device uint4 *blocks [[buffer(0)]],
        constant uint2 &image_size [[buffer(1)]],
        constant uint2 &block_origin [[buffer(2)]],
        uint2 thread_position [[thread_position_in_grid]]
    ) {
        uint2 block_position = thread_position + block_origin;
        uint blocks_wide = (image_size.x + 3u) / 4u;
        uint blocks_high = (image_size.y + 3u) / 4u;
        if (block_position.x >= blocks_wide || block_position.y >= blocks_high) {
            return;
        }

        uint4 pixels[16];
        uint4 endpoint0 = uint4(255u);
        uint4 endpoint1 = uint4(0u);

        for (uint local_y = 0; local_y < 4; ++local_y) {
            for (uint local_x = 0; local_x < 4; ++local_x) {
                uint x = min(block_position.x * 4u + local_x, image_size.x - 1u);
                uint y = min(block_position.y * 4u + local_y, image_size.y - 1u);
                float4 sample = source.read(uint2(x, y));
                uint4 pixel = uint4(clamp(round(sample * 255.0f), 0.0f, 255.0f));
                uint index = local_y * 4u + local_x;
                pixels[index] = pixel;
                endpoint0 = min(endpoint0, pixel);
                endpoint1 = max(endpoint1, pixel);
            }
        }

        uint pbit0 = 0u;
        uint pbit1 = 0u;
        uint4 quantized0 = choose_quantized_endpoint(endpoint0, pbit0);
        uint4 quantized1 = choose_quantized_endpoint(endpoint1, pbit1);
        uint4 reconstructed0 = reconstruct_endpoint(quantized0, pbit0);
        uint4 reconstructed1 = reconstruct_endpoint(quantized1, pbit1);

        uint indices[16];
        for (uint pixel_index = 0; pixel_index < 16; ++pixel_index) {
            uint best_index = 0u;
            uint best_error = 0xffffffffu;
            for (uint candidate = 0; candidate < 16; ++candidate) {
                uint weight = kWeights[candidate];
                uint4 interpolated = (reconstructed0 * (64u - weight) +
                                      reconstructed1 * weight + 32u) >> 6;
                uint error = squared_error(pixels[pixel_index], interpolated);
                if (error < best_error) {
                    best_error = error;
                    best_index = candidate;
                }
            }
            indices[pixel_index] = best_index;
        }

        if (indices[0] >= 8u) {
            uint4 tmp_endpoint = quantized0;
            quantized0 = quantized1;
            quantized1 = tmp_endpoint;
            uint tmp_pbit = pbit0;
            pbit0 = pbit1;
            pbit1 = tmp_pbit;
            for (uint pixel_index = 0; pixel_index < 16; ++pixel_index) {
                indices[pixel_index] = 15u - indices[pixel_index];
            }
        }

        uint4 encoded = uint4(0u);
        uint bit_position = 0u;
        write_bits(encoded, bit_position, 1u << 6, 7u);
        for (uint channel = 0; channel < 4; ++channel) {
            write_bits(encoded, bit_position, quantized0[channel], 7u);
            write_bits(encoded, bit_position, quantized1[channel], 7u);
        }
        write_bits(encoded, bit_position, pbit0, 1u);
        write_bits(encoded, bit_position, pbit1, 1u);
        write_bits(encoded, bit_position, indices[0], 3u);
        for (uint pixel_index = 1; pixel_index < 16; ++pixel_index) {
            write_bits(encoded, bit_position, indices[pixel_index], 4u);
        }

        blocks[block_position.y * blocks_wide + block_position.x] = encoded;
    }

    kernel void bc7_tile_analyze(
        device const uchar *blocks [[buffer(0)]],
        device uchar *baseline [[buffer(1)]],
        device ulong *checksums [[buffer(2)]],
        device uchar *dirty_flags [[buffer(3)]],
        device const uint *tile_indices [[buffer(4)]],
        constant uint2 &image_size [[buffer(5)]],
        constant uint &compare_previous [[buffer(6)]],
        uint candidate_position [[thread_position_in_grid]]
    ) {
        uint tiles_wide = image_size.x / 64u;
        uint tile_index = tile_indices[candidate_position];
        uint tile_x = tile_index % tiles_wide;
        uint tile_y = tile_index / tiles_wide;
        uint bytes_per_row = (image_size.x / 4u) * 16u;
        uint tile_row_bytes = 256u;
        uint tile_byte_offset = tile_x * tile_row_bytes;
        uint pixel_height = min(64u, image_size.y - tile_y * 64u);
        uint block_rows = pixel_height / 4u;
        ulong hash = 14695981039346656037ul ^ ulong(tile_index);
        bool differs = compare_previous == 0u;
        for (uint row = 0; row < block_rows; ++row) {
            uint offset = (tile_y * 16u + row) * bytes_per_row + tile_byte_offset;
            for (uint byte_index = 0; byte_index < tile_row_bytes; ++byte_index) {
                uint byte_offset = offset + byte_index;
                uchar value = blocks[byte_offset];
                if (compare_previous != 0u && baseline[byte_offset] != value) {
                    differs = true;
                }
                baseline[byte_offset] = value;
                hash ^= ulong(value);
                hash *= 1099511628211ul;
            }
        }
        dirty_flags[tile_index] = differs ? 1u : 0u;
        checksums[tile_index] = hash;
    }
    """

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue()
        else {
            return nil
        }

        do {
            let library = try device.makeLibrary(source: Self.source, options: nil)
            guard let function = library.makeFunction(name: "bc7_mode6_encode"),
                  let tileAnalysisFunction = library.makeFunction(name: "bc7_tile_analyze")
            else {
                return nil
            }
            pipeline = try device.makeComputePipelineState(function: function)
            tileAnalysisPipeline = try device.makeComputePipelineState(
                function: tileAnalysisFunction
            )
        } catch {
            NSLog("TargetBridge: unable to compile BC7 Mode 6 Metal encoder: %@", error.localizedDescription)
            return nil
        }

        self.device = device
        self.commandQueue = commandQueue
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess else {
            return nil
        }
        textureCache = cache
    }

    func encode(
        pixelBuffer: CVPixelBuffer,
        dirtyRects: [CGRect]? = nil,
        allowEmptyDirtyPlan: Bool = false
    ) -> (
        data: Data,
        bytesPerRow: Int,
        candidateDirtyTiles: Set<Int>?,
        tileAnalysis: TBBC7TileAnalysis?
    )? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0, width % 4 == 0, height % 4 == 0,
              CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              let textureCache
        else {
            return nil
        }

        var cvTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        ) == kCVReturnSuccess,
        let cvTexture,
        let sourceTexture = CVMetalTextureGetTexture(cvTexture)
        else {
            return nil
        }

        let blocksWide = width / 4
        let blocksHigh = height / 4
        let bytesPerRow = blocksWide * 16
        let requiredLength = bytesPerRow * blocksHigh
        let tilesWide = width / TBBC7DeltaPlanner.tileSize
        let tilesHigh = (height + TBBC7DeltaPlanner.tileSize - 1) /
            TBBC7DeltaPlanner.tileSize
        let tileCount = tilesWide * tilesHigh
        let canAnalyzeTiles = width >= TBBC7DeltaPlanner.tileSize &&
            width % TBBC7DeltaPlanner.tileSize == 0
        if outputBuffer == nil || outputBufferLength != requiredLength ||
            outputWidth != width || outputHeight != height {
            outputBuffer = device.makeBuffer(length: requiredLength, options: .storageModeShared)
            tileBaselineBuffer = canAnalyzeTiles
                ? device.makeBuffer(length: requiredLength, options: .storageModePrivate)
                : nil
            tileChecksumBuffer = canAnalyzeTiles
                ? device.makeBuffer(
                    length: tileCount * MemoryLayout<UInt64>.stride,
                    options: .storageModeShared
                )
                : nil
            tileDirtyBuffer = canAnalyzeTiles
                ? device.makeBuffer(
                    length: tileCount * MemoryLayout<UInt8>.stride,
                    options: .storageModeShared
                )
                : nil
            outputBufferLength = requiredLength
            tileBufferCount = tileCount
            tileIndexCapacity = 0
            outputWidth = width
            outputHeight = height
            hasCompleteFrame = false
            if let tileChecksumBuffer {
                memset(tileChecksumBuffer.contents(), 0, tileChecksumBuffer.length)
            }
            if let tileDirtyBuffer {
                memset(tileDirtyBuffer.contents(), 0, tileDirtyBuffer.length)
            }
        }
        let dirtyPlan = hasCompleteFrame
            ? dirtyRects.map {
                tbBC7DirtyRegionPlan(dirtyRects: $0, width: width, height: height)
            }
            : nil
        if let dirtyPlan, dirtyPlan.regions.isEmpty, !allowEmptyDirtyPlan {
            return nil
        }
        let candidateIndices = canAnalyzeTiles
            ? Array(dirtyPlan?.tileIndices ?? Set(0..<tileCount)).sorted()
            : []
        if canAnalyzeTiles &&
            (tileIndexBuffer == nil || tileIndexCapacity < candidateIndices.count) {
            tileIndexBuffer = device.makeBuffer(
                length: max(1, candidateIndices.count) * MemoryLayout<UInt32>.stride,
                options: .storageModeShared
            )
            tileIndexCapacity = candidateIndices.count
        }
        guard let outputBuffer,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            return nil
        }

        var imageSize = SIMD2<UInt32>(UInt32(width), UInt32(height))
        let regions = dirtyPlan?.regions ?? [
            TBBC7DirtyRegionPlan.Region(
                blockX: 0,
                blockY: 0,
                blockWidth: blocksWide,
                blockHeight: blocksHigh
            )
        ]
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(sourceTexture, index: 0)
        encoder.setBuffer(outputBuffer, offset: 0, index: 0)
        encoder.setBytes(&imageSize, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 1)
        let threadsPerGroup = MTLSize(width: 8, height: 8, depth: 1)
        for region in regions {
            var blockOrigin = SIMD2<UInt32>(UInt32(region.blockX), UInt32(region.blockY))
            encoder.setBytes(&blockOrigin, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 2)
            encoder.dispatchThreads(
                MTLSize(width: region.blockWidth, height: region.blockHeight, depth: 1),
                threadsPerThreadgroup: threadsPerGroup
            )
        }
        encoder.endEncoding()
        var didEncodeTileAnalysis = false
        if canAnalyzeTiles,
           let tileBaselineBuffer,
           let tileChecksumBuffer,
           let tileDirtyBuffer,
           let tileIndexBuffer {
            if !candidateIndices.isEmpty {
                candidateIndices.withUnsafeBufferPointer { indices in
                    let destination = tileIndexBuffer.contents()
                        .assumingMemoryBound(to: UInt32.self)
                    for index in indices.indices {
                        destination[index] = UInt32(indices[index])
                    }
                }
                guard let analysisEncoder = commandBuffer.makeComputeCommandEncoder() else {
                    return nil
                }
                analysisEncoder.setComputePipelineState(tileAnalysisPipeline)
                analysisEncoder.setBuffer(outputBuffer, offset: 0, index: 0)
                analysisEncoder.setBuffer(tileBaselineBuffer, offset: 0, index: 1)
                analysisEncoder.setBuffer(tileChecksumBuffer, offset: 0, index: 2)
                analysisEncoder.setBuffer(tileDirtyBuffer, offset: 0, index: 3)
                analysisEncoder.setBuffer(tileIndexBuffer, offset: 0, index: 4)
                analysisEncoder.setBytes(
                    &imageSize,
                    length: MemoryLayout<SIMD2<UInt32>>.stride,
                    index: 5
                )
                var comparePrevious: UInt32 = hasCompleteFrame ? 1 : 0
                analysisEncoder.setBytes(
                    &comparePrevious,
                    length: MemoryLayout<UInt32>.stride,
                    index: 6
                )
                analysisEncoder.dispatchThreads(
                    MTLSize(width: candidateIndices.count, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(
                        width: min(tileAnalysisPipeline.maxTotalThreadsPerThreadgroup, 64),
                        height: 1,
                        depth: 1
                    )
                )
                analysisEncoder.endEncoding()
            }
            didEncodeTileAnalysis = true
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            if let error = commandBuffer.error {
                NSLog("TargetBridge: BC7 Mode 6 command failed: %@", error.localizedDescription)
            }
            return nil
        }
        hasCompleteFrame = true
        let tileAnalysis: TBBC7TileAnalysis?
        if didEncodeTileAnalysis,
           let tileChecksumBuffer,
           let tileDirtyBuffer {
            let dirtyFlags = tileDirtyBuffer.contents()
                .assumingMemoryBound(to: UInt8.self)
            let dirtyTiles = Set(candidateIndices.filter { dirtyFlags[$0] != 0 })
            let checksumValues = tileChecksumBuffer.contents()
                .assumingMemoryBound(to: UInt64.self)
            let checksums = Array(
                UnsafeBufferPointer(start: checksumValues, count: tileBufferCount)
            )
            tileAnalysis = TBBC7TileAnalysis(
                dirtyTiles: dirtyTiles,
                checksums: checksums
            )
        } else {
            tileAnalysis = nil
        }

        return (
            Data(bytes: outputBuffer.contents(), count: requiredLength),
            bytesPerRow,
            dirtyPlan?.tileIndices,
            tileAnalysis
        )
    }
}

struct TBBC7DeltaRun: Equatable {
    let tileX: Int
    let tileY: Int
    let tileCountX: Int
    let pixelHeight: Int

    var dataLength: Int {
        tileCountX * (TBBC7DeltaPlanner.tileSize / 4) * 16 * (pixelHeight / 4)
    }
}

enum TBBC7DeltaPlan {
    case keyframe(sequence: UInt64, checksum: UInt64, data: Data)
    case delta(sequence: UInt64, baseSequence: UInt64, checksum: UInt64, runs: [TBBC7DeltaRun], dirtyTiles: Int, totalTiles: Int)
}

struct TBBC7DeltaPlanningStats: Equatable {
    let dirtyTiles: Int
    let transmittedTiles: Int
    let deferredTiles: Int
    let worstDeferredAge: Int

    static let empty = TBBC7DeltaPlanningStats(
        dirtyTiles: 0,
        transmittedTiles: 0,
        deferredTiles: 0,
        worstDeferredAge: 0
    )
}

struct TBBC7TileBudgetController {
    static let maxTileAge = 4
    static let badSendNanoseconds: UInt64 = 12_000_000
    static let goodSendNanoseconds: UInt64 = 8_000_000

    private(set) var currentBudget: Int?
    private var badWindows = 0
    private var goodWindows = 0
    private var settlingWindows = 0

    mutating func budget(totalTiles: Int) -> Int {
        let normalizedTotal = max(1, totalTiles)
        if currentBudget == nil {
            currentBudget = normalizedTotal
        }
        return min(normalizedTotal, max(minimumBudget(totalTiles: normalizedTotal), currentBudget!))
    }

    mutating func recordSend(durationNanoseconds: UInt64, totalTiles: Int) {
        guard totalTiles > 0 else { return }
        let budget = self.budget(totalTiles: totalTiles)
        if settlingWindows > 0 {
            settlingWindows -= 1
            return
        }
        if durationNanoseconds >= Self.badSendNanoseconds {
            badWindows += 1
            goodWindows = 0
            if badWindows >= 2 {
                currentBudget = max(
                    minimumBudget(totalTiles: totalTiles),
                    budget * 3 / 4
                )
                badWindows = 0
                settlingWindows = 4
            }
        } else if durationNanoseconds <= Self.goodSendNanoseconds {
            goodWindows += 1
            badWindows = 0
            if goodWindows >= 8 {
                currentBudget = min(totalTiles, budget + max(128, totalTiles / 10))
                goodWindows = 0
                settlingWindows = 4
            }
        } else {
            badWindows = 0
            goodWindows = 0
        }
    }

    private func minimumBudget(totalTiles: Int) -> Int {
        (totalTiles + Self.maxTileAge - 1) / Self.maxTileAge
    }
}

final class TBBC7DeltaPlanner {
    static let tileSize = 64
    static let maxDeltaRuns = 256

    private var baseline: Data?
    private var tileChecksums: [UInt64] = []
    private var sequence: UInt64 = 0
    private var framesSinceKeyframe = 0
    private var forceKeyframe = true
    private var deferredAges: [UInt16] = []
    private let keyframeIntervalFrames: Int
    private(set) var lastStats = TBBC7DeltaPlanningStats.empty

    init(keyframeIntervalFrames: Int) {
        self.keyframeIntervalFrames = max(1, keyframeIntervalFrames)
    }

    var requiresFullFrame: Bool {
        forceKeyframe || baseline == nil || framesSinceKeyframe >= keyframeIntervalFrames
    }

    var hasDeferredTiles: Bool {
        deferredAges.contains { $0 > 0 }
    }

    func reset() {
        baseline = nil
        tileChecksums = []
        sequence = 0
        framesSinceKeyframe = 0
        forceKeyframe = true
        deferredAges = []
        lastStats = .empty
    }

    func markSendFailure() {
        forceKeyframe = true
    }

    func plan(
        current: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        candidateDirtyTiles: Set<Int>? = nil,
        analyzedDirtyTiles: Set<Int>? = nil,
        analyzedChecksums: [UInt64]? = nil,
        maxTilesPerDelta: Int? = nil
    ) -> TBBC7DeltaPlan? {
        guard width > 0, height > 0, width % Self.tileSize == 0, height % 4 == 0,
              bytesPerRow == (width / 4) * 16,
              current.count == bytesPerRow * (height / 4)
        else {
            return nil
        }

        let tilesWide = width / Self.tileSize
        let tilesHigh = (height + Self.tileSize - 1) / Self.tileSize
        let totalTiles = tilesWide * tilesHigh
        let nextSequence = sequence &+ 1
        let hasGPUAnalysis =
            analyzedDirtyTiles != nil && analyzedChecksums?.count == totalTiles

        guard !forceKeyframe,
              let baseline,
              baseline.count == current.count,
              tileChecksums.count == totalTiles,
              framesSinceKeyframe < keyframeIntervalFrames
        else {
            let checksums = hasGPUAnalysis
                ? analyzedChecksums!
                : computeTileChecksums(
                    data: current,
                    width: width,
                    height: height,
                    bytesPerRow: bytesPerRow
                )
            self.baseline = current
            tileChecksums = checksums
            deferredAges = [UInt16](repeating: 0, count: totalTiles)
            sequence = nextSequence
            framesSinceKeyframe = 0
            forceKeyframe = false
            lastStats = .empty
            return .keyframe(
                sequence: nextSequence,
                checksum: checksums.reduce(0, ^),
                data: current
            )
        }

        var dirty = [Bool](repeating: false, count: totalTiles)
        if hasGPUAnalysis {
            for tileIndex in 0..<totalTiles {
                dirty[tileIndex] = analyzedChecksums![tileIndex] != tileChecksums[tileIndex]
            }
        } else {
            current.withUnsafeBytes { currentBytes in
                baseline.withUnsafeBytes { baselineBytes in
                    guard let currentBase = currentBytes.baseAddress,
                          let baselineBase = baselineBytes.baseAddress else { return }
                    let deferred = Set(
                        deferredAges.indices.filter { deferredAges[$0] > 0 }
                    )
                    let candidates = (candidateDirtyTiles ?? Set(0..<totalTiles))
                        .union(deferred)
                    for tileIndex in candidates where tileIndex >= 0 && tileIndex < totalTiles {
                        let tileY = tileIndex / tilesWide
                        let tileX = tileIndex % tilesWide
                        let pixelHeight = min(Self.tileSize, height - tileY * Self.tileSize)
                        let blockRows = pixelHeight / 4
                        let tileByteOffset = tileX * (Self.tileSize / 4) * 16
                        let tileRowBytes = (Self.tileSize / 4) * 16
                        var differs = false
                        for blockRow in 0..<blockRows {
                            let offset = (tileY * (Self.tileSize / 4) + blockRow) * bytesPerRow + tileByteOffset
                            if memcmp(
                                currentBase.advanced(by: offset),
                                baselineBase.advanced(by: offset),
                                tileRowBytes
                            ) != 0 {
                                differs = true
                                break
                            }
                        }
                        dirty[tileIndex] = differs
                    }
                }
            }
        }

        if deferredAges.count != totalTiles {
            deferredAges = [UInt16](repeating: 0, count: totalTiles)
        }
        for tileIndex in 0..<totalTiles {
            if dirty[tileIndex] {
                if deferredAges[tileIndex] < UInt16.max {
                    deferredAges[tileIndex] += 1
                }
            } else {
                deferredAges[tileIndex] = 0
            }
        }

        let dirtyIndices = dirty.indices.filter { dirty[$0] }
        let tileBudget = min(
            totalTiles,
            max(1, maxTilesPerDelta ?? totalTiles)
        )
        let selectedIndices = dirtyIndices
            .sorted {
                if deferredAges[$0] != deferredAges[$1] {
                    return deferredAges[$0] > deferredAges[$1]
                }
                return $0 < $1
            }
            .prefix(tileBudget)
        var selected = [Bool](repeating: false, count: totalTiles)
        for tileIndex in selectedIndices {
            selected[tileIndex] = true
        }

        var runs: [TBBC7DeltaRun] = []
        var transmittedTiles = 0
        for tileY in 0..<tilesHigh {
            var tileX = 0
            while tileX < tilesWide {
                if !selected[tileY * tilesWide + tileX] {
                    tileX += 1
                    continue
                }
                let startX = tileX
                var lastSelectedX = tileX
                tileX += 1
                while tileX < tilesWide {
                    if selected[tileY * tilesWide + tileX] {
                        lastSelectedX = tileX
                    } else if tileX - lastSelectedX > 1 {
                        break
                    }
                    tileX += 1
                }
                let countX = lastSelectedX - startX + 1
                tileX = lastSelectedX + 1
                transmittedTiles += countX
                let pixelHeight = min(Self.tileSize, height - tileY * Self.tileSize)
                runs.append(TBBC7DeltaRun(
                    tileX: startX,
                    tileY: tileY,
                    tileCountX: countX,
                    pixelHeight: pixelHeight
                ))
            }
        }

        guard runs.count <= Self.maxDeltaRuns else {
            forceKeyframe = true
            return plan(
                current: current,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                candidateDirtyTiles: candidateDirtyTiles,
                analyzedDirtyTiles: analyzedDirtyTiles,
                analyzedChecksums: analyzedChecksums,
                maxTilesPerDelta: maxTilesPerDelta
            )
        }

        var updatedChecksums = tileChecksums
        var updatedBaseline = baseline
        for run in runs {
            for tileX in run.tileX..<(run.tileX + run.tileCountX) {
                let tileIndex = run.tileY * tilesWide + tileX
                updatedChecksums[tileIndex] = hasGPUAnalysis
                    ? analyzedChecksums![tileIndex]
                    : Self.tileChecksum(
                        data: current,
                        width: width,
                        height: height,
                        bytesPerRow: bytesPerRow,
                        tileX: tileX,
                        tileY: run.tileY
                    )
                deferredAges[tileIndex] = 0
            }
            Self.copyRun(
                run,
                from: current,
                to: &updatedBaseline,
                bytesPerRow: bytesPerRow
            )
        }
        self.baseline = updatedBaseline
        tileChecksums = updatedChecksums
        let deferredTiles = deferredAges.reduce(into: 0) { count, age in
            if age > 0 { count += 1 }
        }
        let worstDeferredAge = deferredAges.max().map(Int.init) ?? 0
        lastStats = TBBC7DeltaPlanningStats(
            dirtyTiles: dirtyIndices.count,
            transmittedTiles: transmittedTiles,
            deferredTiles: deferredTiles,
            worstDeferredAge: worstDeferredAge
        )
        let baseSequence = sequence
        sequence = nextSequence
        framesSinceKeyframe += 1
        return .delta(
            sequence: nextSequence,
            baseSequence: baseSequence,
            checksum: updatedChecksums.reduce(0, ^),
            runs: runs,
            dirtyTiles: transmittedTiles,
            totalTiles: totalTiles
        )
    }

    private static func copyRun(
        _ run: TBBC7DeltaRun,
        from current: Data,
        to baseline: inout Data,
        bytesPerRow: Int
    ) {
        let blockRows = run.pixelHeight / 4
        let runRowBytes = run.tileCountX * (tileSize / 4) * 16
        let sourceX = run.tileX * (tileSize / 4) * 16
        current.withUnsafeBytes { currentBytes in
            baseline.withUnsafeMutableBytes { baselineBytes in
                guard let source = currentBytes.baseAddress,
                      let destination = baselineBytes.baseAddress else { return }
                for row in 0..<blockRows {
                    let offset =
                        (run.tileY * (tileSize / 4) + row) * bytesPerRow + sourceX
                    memcpy(
                        destination.advanced(by: offset),
                        source.advanced(by: offset),
                        runRowBytes
                    )
                }
            }
        }
    }

    private func computeTileChecksums(
        data: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) -> [UInt64] {
        let tilesWide = width / Self.tileSize
        let tilesHigh = (height + Self.tileSize - 1) / Self.tileSize
        return (0..<(tilesWide * tilesHigh)).map { index in
            Self.tileChecksum(
                data: data,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                tileX: index % tilesWide,
                tileY: index / tilesWide
            )
        }
    }

    private static func tileChecksum(
        data: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        tileX: Int,
        tileY: Int
    ) -> UInt64 {
        let pixelHeight = min(tileSize, height - tileY * tileSize)
        let blockRows = pixelHeight / 4
        let tileRowBytes = (tileSize / 4) * 16
        let tileByteOffset = tileX * tileRowBytes
        var hash = UInt64(14_695_981_039_346_656_037) ^ UInt64(tileY * (width / tileSize) + tileX)
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            for row in 0..<blockRows {
                let offset = (tileY * (tileSize / 4) + row) * bytesPerRow + tileByteOffset
                let rowBytes = base.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
                for index in 0..<tileRowBytes {
                    hash ^= UInt64(rowBytes[index])
                    hash &*= 1_099_511_628_211
                }
            }
        }
        return hash
    }
}

func tbMakeBC7DeltaPacket(
    current: Data,
    width: Int,
    height: Int,
    bytesPerRow: Int,
    sequence: UInt64,
    baseSequence: UInt64,
    checksum: UInt64,
    runs: [TBBC7DeltaRun]
) -> Data? {
    guard width > 0, height > 0, width % TBBC7DeltaPlanner.tileSize == 0,
          height % 4 == 0,
          bytesPerRow == (width / 4) * 16,
          current.count == bytesPerRow * (height / 4),
          width <= Int(UInt32.max), height <= Int(UInt32.max),
          runs.count <= Int(UInt16.max)
    else {
        return nil
    }
    let payloadLength = 37 + runs.reduce(0) { $0 + 12 + $1.dataLength }
    let declaredLength = 1 + payloadLength
    guard declaredLength <= Int(TBMonitorProtocol.maxPacketLength) else {
        return nil
    }

    let packetLength = 4 + declaredLength
    var packet = Data(count: packetLength)
    let completed = packet.withUnsafeMutableBytes { packetBytes -> Bool in
        guard let destination = packetBytes.baseAddress?
            .assumingMemoryBound(to: UInt8.self)
        else {
            return false
        }

        func writeBE16(_ value: UInt16, at offset: Int) {
            destination[offset] = UInt8((value >> 8) & 0xff)
            destination[offset + 1] = UInt8(value & 0xff)
        }
        func writeBE32(_ value: UInt32, at offset: Int) {
            destination[offset] = UInt8((value >> 24) & 0xff)
            destination[offset + 1] = UInt8((value >> 16) & 0xff)
            destination[offset + 2] = UInt8((value >> 8) & 0xff)
            destination[offset + 3] = UInt8(value & 0xff)
        }
        func writeBE64(_ value: UInt64, at offset: Int) {
            for index in 0..<8 {
                destination[offset + index] = UInt8(
                    (value >> UInt64((7 - index) * 8)) & 0xff
                )
            }
        }

        writeBE32(UInt32(declaredLength), at: 0)
        destination[4] = TBMonitorPacketType.bc7TileDelta.rawValue
        destination[5] = 1
        writeBE64(sequence, at: 6)
        writeBE64(baseSequence, at: 14)
        writeBE64(checksum, at: 22)
        writeBE32(UInt32(width), at: 30)
        writeBE32(UInt32(height), at: 34)
        writeBE16(UInt16(TBBC7DeltaPlanner.tileSize), at: 38)
        writeBE16(UInt16(runs.count), at: 40)

        return current.withUnsafeBytes { currentBytes -> Bool in
            guard let source = currentBytes.baseAddress?
                .assumingMemoryBound(to: UInt8.self)
            else {
                return false
            }
            var packetOffset = 42
            let tilesWide = width / TBBC7DeltaPlanner.tileSize
            let tilesHigh =
                (height + TBBC7DeltaPlanner.tileSize - 1) /
                TBBC7DeltaPlanner.tileSize
            for run in runs {
                guard run.tileX >= 0, run.tileX <= Int(UInt16.max),
                      run.tileY >= 0, run.tileY <= Int(UInt16.max),
                      run.tileCountX > 0, run.tileCountX <= Int(UInt16.max),
                      run.pixelHeight > 0, run.pixelHeight <= Int(UInt16.max),
                      run.tileX + run.tileCountX <= tilesWide,
                      run.tileY < tilesHigh,
                      run.pixelHeight == min(
                        TBBC7DeltaPlanner.tileSize,
                        height - run.tileY * TBBC7DeltaPlanner.tileSize
                      ),
                      run.dataLength <= Int(UInt32.max)
                else {
                    return false
                }
                writeBE16(UInt16(run.tileX), at: packetOffset)
                writeBE16(UInt16(run.tileY), at: packetOffset + 2)
                writeBE16(UInt16(run.tileCountX), at: packetOffset + 4)
                writeBE16(UInt16(run.pixelHeight), at: packetOffset + 6)
                writeBE32(UInt32(run.dataLength), at: packetOffset + 8)
                packetOffset += 12

                let blockRows = run.pixelHeight / 4
                let runRowBytes =
                    run.tileCountX * (TBBC7DeltaPlanner.tileSize / 4) * 16
                let sourceX =
                    run.tileX * (TBBC7DeltaPlanner.tileSize / 4) * 16
                for row in 0..<blockRows {
                    let sourceOffset =
                        (run.tileY * (TBBC7DeltaPlanner.tileSize / 4) + row) *
                        bytesPerRow + sourceX
                    guard sourceOffset >= 0,
                          sourceOffset + runRowBytes <= current.count
                    else {
                        return false
                    }
                    memcpy(
                        destination.advanced(by: packetOffset),
                        source.advanced(by: sourceOffset),
                        runRowBytes
                    )
                    packetOffset += runRowBytes
                }
            }
            return packetOffset == packetLength
        }
    }
    return completed ? packet : nil
}

final class TBLatestFrameSlot<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingValue: Value?
    private var drainScheduled = false
    private var dropped = 0

    func submit(_ value: Value) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if pendingValue != nil {
            dropped += 1
        }
        pendingValue = value
        guard !drainScheduled else { return false }
        drainScheduled = true
        return true
    }

    func take() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        let value = pendingValue
        pendingValue = nil
        return value
    }

    func takeWithDroppedCount() -> (value: Value?, droppedCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        let value = pendingValue
        pendingValue = nil
        return (value, dropped)
    }

    func submitIfEmpty(
        _ value: Value
    ) -> (inserted: Bool, shouldSchedule: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard pendingValue == nil else {
            return (false, false)
        }
        pendingValue = value
        guard !drainScheduled else {
            return (true, false)
        }
        drainScheduled = true
        return (true, true)
    }

    func finishProcessing() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if pendingValue != nil {
            return true
        }
        drainScheduled = false
        return false
    }

    func cancel() {
        lock.lock()
        pendingValue = nil
        drainScheduled = false
        lock.unlock()
    }

    var droppedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return dropped
    }
}

struct TBCapturedFrame: @unchecked Sendable {
    let sampleBuffer: CMSampleBuffer
    let receivedAtNanoseconds: UInt64
}

struct TBPipelineDiagnosticsSnapshot {
    let pending: Int
    let inFlight: Int
    let dropped: Int
    let ptsSeq: CMTimeValue
    let bc7Keyframes: Int
    let bc7DeltaFrames: Int
    let bc7DirtyTiles: Int
    let bc7FullEncodeFallbacks: Int
    let bc7ProcessedFrames: Int
    let bc7EncodeNanoseconds: UInt64
    let bc7PlanNanoseconds: UInt64
    let bc7PacketNanoseconds: UInt64
    let bc7GPUAnalyzedFrames: Int
    let bc7SendCompletedFrames: Int
    let bc7SendNanoseconds: UInt64
    let bc7SendErrors: Int
    let bc7CompressedPackets: Int
    let bc7CompressionFallbacks: Int
    let bc7RawPacketBytes: UInt64
    let bc7WirePacketBytes: UInt64
    let bc7CompressionMode: String
    let captureComplete: Int
    let captureStarted: Int
    let captureIdle: Int
    let captureBlank: Int
    let captureSuspended: Int
    let captureStopped: Int
    let captureUnknown: Int
    let tileBudget: Int
    let deferredTiles: Int
    let worstDeferredAge: Int
    let captureInterval: TBMetricSummary
    let queueAge: TBMetricSummary
    let encodeTime: TBMetricSummary
    let planTime: TBMetricSummary
    let packetTime: TBMetricSummary
    let sendTime: TBMetricSummary
    let packetBytes: TBMetricSummary
    let dirtyTiles: TBMetricSummary
    let planeSplitTime: TBMetricSummary
    let compressionTime: TBMetricSummary
    let nv12FullFrames: Int
    let nv12RegionFrames: Int
    let nv12RawBytes: UInt64
    let nv12WireBytes: UInt64
    let nv12CopyTime: TBMetricSummary
    let nv12CompressionTime: TBMetricSummary
    let nv12ChecksumTime: TBMetricSummary
    let nv12PacketTime: TBMetricSummary
    let nv12RegionPixels: TBMetricSummary
    let nv12DirtyPixels: TBMetricSummary
    let nv12DirtyRectCount: TBMetricSummary
    let nv12OverfetchPermille: TBMetricSummary
    let nv12TileDetectionTime: TBMetricSummary
    let nv12RunCount: TBMetricSummary
    let nv12ZeroCopyPackets: Int
    let nv12ZeroCopyFallbacks: Int
    let nv12LZ4Encoder: String
    let nv12CopyRectFrames: Int
    let nv12CopyRectTiles: Int
    let nv12CopyRectRejects: Int
    let nv12CopyRectWriterFailures: Int
    let nv12CopyRectSkippedSearches: Int
    let nv12CopyRectSearchTime: TBMetricSummary
    let nv12CopyRectLastVector: String
    let nv12CopyRectStats: TBNV12CopyRectStats

    static let empty = TBPipelineDiagnosticsSnapshot(
        pending: 0, inFlight: 0, dropped: 0, ptsSeq: 0,
        bc7Keyframes: 0, bc7DeltaFrames: 0, bc7DirtyTiles: 0,
        bc7FullEncodeFallbacks: 0, bc7ProcessedFrames: 0,
        bc7EncodeNanoseconds: 0, bc7PlanNanoseconds: 0,
        bc7PacketNanoseconds: 0, bc7GPUAnalyzedFrames: 0,
        bc7SendCompletedFrames: 0, bc7SendNanoseconds: 0,
        bc7SendErrors: 0, bc7CompressedPackets: 0,
        bc7CompressionFallbacks: 0, bc7RawPacketBytes: 0,
        bc7WirePacketBytes: 0, bc7CompressionMode: "off",
        captureComplete: 0, captureStarted: 0,
        captureIdle: 0, captureBlank: 0, captureSuspended: 0,
        captureStopped: 0, captureUnknown: 0, tileBudget: 0,
        deferredTiles: 0, worstDeferredAge: 0,
        captureInterval: .empty, queueAge: .empty, encodeTime: .empty,
        planTime: .empty, packetTime: .empty, sendTime: .empty,
        packetBytes: .empty, dirtyTiles: .empty,
        planeSplitTime: .empty, compressionTime: .empty,
        nv12FullFrames: 0, nv12RegionFrames: 0,
        nv12RawBytes: 0, nv12WireBytes: 0,
        nv12CopyTime: .empty, nv12CompressionTime: .empty,
        nv12ChecksumTime: .empty, nv12PacketTime: .empty,
        nv12RegionPixels: .empty, nv12DirtyPixels: .empty,
        nv12DirtyRectCount: .empty, nv12OverfetchPermille: .empty,
        nv12TileDetectionTime: .empty, nv12RunCount: .empty,
        nv12ZeroCopyPackets: 0, nv12ZeroCopyFallbacks: 0,
        nv12LZ4Encoder: "off",
        nv12CopyRectFrames: 0, nv12CopyRectTiles: 0, nv12CopyRectRejects: 0,
        nv12CopyRectWriterFailures: 0, nv12CopyRectSkippedSearches: 0,
        nv12CopyRectSearchTime: .empty, nv12CopyRectLastVector: "none",
        nv12CopyRectStats: TBNV12CopyRectStats()
    )
}

private final class TBVideoPipeline: @unchecked Sendable {
    let queue = DispatchQueue(label: "fd.tbmonitor.sender.pipeline", qos: .userInteractive)

    private let preset: TBDisplayCapturePreset
    private let codecType: CMVideoCodecType
    private let connection: NWConnection
    private let displayName: String
    private let displayID: CGDirectDisplayID
    private let usesRawNV12: Bool
    private let usesRawNV12LZ4: Bool
    private let usesRawNV12TileRuns: Bool
    private let usesRawNV12CopyRect: Bool
    private let rawNV12ChecksumPolicy: TBNV12ChecksumPolicy
    private let usesRawNV12ZeroCopy: Bool
    private let rawNV12LZ4Encoder: TBNV12LZ4Encoder
    private let rawNV12LZ4Threads: Int
    private let usesBC7Mode6: Bool
    private let usesBC7TileDelta: Bool
    private let bc7CompressionMode: TBBC7CompressionMode
    private let onFirstFrame: @Sendable (Int, Int) -> Void

    // Confined to `queue`.
    private var vtEncoder: VTCompressionSession?
    private var vtEncoderRef: Unmanaged<TBVideoPipeline>?
    private var bc7Encoder: TBBC7Mode6Encoder?
    private var bc7DeltaPlanner: TBBC7DeltaPlanner?
    private var pendingVideoPackets = 0
    private var inFlightEncodeFrames = 0
    private var droppedVideoFrames = 0
    private var bc7Keyframes = 0
    private var bc7DeltaFrames = 0
    private var bc7DirtyTiles = 0
    private var bc7FullEncodeFallbacks = 0
    private var bc7TileBudgetController = TBBC7TileBudgetController()
    private var bc7LastTotalTiles = 0
    private var bc7DeferredTiles = 0
    private var bc7WorstDeferredAge = 0
    private var displayStreamFrameSequence: CMTimeValue = 0
    private var lastEncodedDisplayPTS: CMTime?
    private var ackSent: Bool
    private var firstFrameNotified = false
    private var running = false
    private var rawNV12HasBaseline = false
    private var rawNV12Width = 0
    private var rawNV12Height = 0
    private var rawNV12ObservedDropped = 0
    private var lastRawNV12Frame: TBCapturedFrame?
    private var rawNV12TileDetector: TBNV12TileDetector?
    private var rawNV12PacketWriter: TBNV12TileRunPacketWriter?
    private var rawNV12ParallelLZ4: TBNV12ParallelLZ4Encoder?
    private var rawNV12LastCopyVector: SIMD2<Int>?
    private var rawNV12CopyRectBackoff = TBNV12CopyRectBackoff()
    private var rawNV12LastPointer: CGPoint?
    /// Pointer move since the previous frame, in captured pixels.
    private var rawNV12PointerDelta: SIMD2<Int>?
    private let latestBC7Frame = TBLatestFrameSlot<TBCapturedFrame>()
    private let latestRawNV12Frame = TBLatestFrameSlot<TBCapturedFrame>()

    // Read from the main thread (fps timer / watchdog); guarded by `lock`.
    private let lock = NSLock()
    private var _sentFrames = 0
    private var _sentBytes = 0
    private var _capturedFrames = 0
    private var _bc7ProcessedFrames = 0
    private var _bc7EncodeNanoseconds: UInt64 = 0
    private var _bc7PlanNanoseconds: UInt64 = 0
    private var _bc7PacketNanoseconds: UInt64 = 0
    private var _bc7GPUAnalyzedFrames = 0
    private var _bc7SendCompletedFrames = 0
    private var _bc7SendNanoseconds: UInt64 = 0
    private var _bc7SendErrors = 0
    private var _bc7CompressedPackets = 0
    private var _bc7CompressionFallbacks = 0
    private var _bc7RawPacketBytes: UInt64 = 0
    private var _bc7WirePacketBytes: UInt64 = 0
    private var _captureComplete = 0
    private var _captureStarted = 0
    private var _captureIdle = 0
    private var _captureBlank = 0
    private var _captureSuspended = 0
    private var _captureStopped = 0
    private var _captureUnknown = 0
    private var _lastCaptureCallbackNanoseconds: UInt64?
    private var _captureIntervalWindow = TBRollingMetricWindow()
    private var _queueAgeWindow = TBRollingMetricWindow()
    private var _encodeTimeWindow = TBRollingMetricWindow()
    private var _planTimeWindow = TBRollingMetricWindow()
    private var _packetTimeWindow = TBRollingMetricWindow()
    private var _sendTimeWindow = TBRollingMetricWindow()
    private var _packetBytesWindow = TBRollingMetricWindow()
    private var _dirtyTilesWindow = TBRollingMetricWindow()
    private var _planeSplitTimeWindow = TBRollingMetricWindow()
    private var _compressionTimeWindow = TBRollingMetricWindow()
    private var _nv12FullFrames = 0
    private var _nv12RegionFrames = 0
    private var _nv12RawBytes: UInt64 = 0
    private var _nv12WireBytes: UInt64 = 0
    private var _nv12CopyTimeWindow = TBRollingMetricWindow()
    private var _nv12CompressionTimeWindow = TBRollingMetricWindow()
    private var _nv12ChecksumTimeWindow = TBRollingMetricWindow()
    private var _nv12PacketTimeWindow = TBRollingMetricWindow()
    private var _nv12RegionPixelsWindow = TBRollingMetricWindow()
    private var _nv12DirtyPixelsWindow = TBRollingMetricWindow()
    private var _nv12DirtyRectCountWindow = TBRollingMetricWindow()
    private var _nv12OverfetchPermilleWindow = TBRollingMetricWindow()
    private var _nv12TileDetectionTimeWindow = TBRollingMetricWindow()
    private var _nv12RunCountWindow = TBRollingMetricWindow()
    private var _nv12ZeroCopyPackets = 0
    private var _nv12ZeroCopyFallbacks = 0
    private var _nv12CopyRectFrames = 0
    private var _nv12CopyRectTiles = 0
    private var _nv12CopyRectRejects = 0
    private var _nv12CopyRectWriterFailures = 0
    private var _nv12CopyRectSkippedSearches = 0
    private var _nv12CopyRectSearchTimeWindow = TBRollingMetricWindow()
    private var _nv12CopyRectLastVector: SIMD2<Int>?
    private var _nv12CopyRectStats = TBNV12CopyRectStats()
    private var _lastCaptureFrameAt = Date()

    init(preset: TBDisplayCapturePreset,
         codecType: CMVideoCodecType,
         connection: NWConnection,
         displayName: String,
         displayID: CGDirectDisplayID,
         usesRawNV12: Bool,
         usesRawNV12LZ4: Bool,
         usesRawNV12TileRuns: Bool,
         usesRawNV12CopyRect: Bool,
         usesBC7Mode6: Bool,
         usesBC7TileDelta: Bool,
         bc7CompressionMode: TBBC7CompressionMode,
         ackAlreadySent: Bool,
         onFirstFrame: @escaping @Sendable (Int, Int) -> Void) {
        self.preset = preset
        self.codecType = codecType
        self.connection = connection
        self.displayName = displayName
        self.displayID = displayID
        self.usesRawNV12 = usesRawNV12
        self.usesRawNV12LZ4 = usesRawNV12LZ4
        self.usesRawNV12TileRuns = usesRawNV12TileRuns
        // Window drags and scrolls as copy rects; TB_NV12_COPY_RECT=0 sends
        // them as tile runs instead.
        self.usesRawNV12CopyRect = usesRawNV12CopyRect &&
            usesRawNV12TileRuns && usesRawNV12LZ4 &&
            ProcessInfo.processInfo.environment["TB_NV12_COPY_RECT"] != "0"
        self.rawNV12ChecksumPolicy =
            ProcessInfo.processInfo.environment["TB_NV12_CHECKSUM"] == "1"
                ? .fnv64
                : .disabled
        // On by default; TB_NV12_ZERO_COPY=0 falls back to the copying path.
        self.usesRawNV12ZeroCopy =
            ProcessInfo.processInfo.environment["TB_NV12_ZERO_COPY"] != "0"
        self.rawNV12LZ4Encoder = TBNV12LZ4Encoder.fromEnvironment(
            ProcessInfo.processInfo.environment
        )
        // Two performance cores by default; TB_NV12_LZ4_THREADS=1 encodes on
        // the pipeline queue only.
        self.rawNV12LZ4Threads = TBNV12ParallelLZ4Encoder.threadCount(
            environment: ProcessInfo.processInfo.environment
        )
        self.usesBC7Mode6 = usesBC7Mode6
        self.usesBC7TileDelta = usesBC7TileDelta
        self.bc7CompressionMode = bc7CompressionMode
        self.ackSent = ackAlreadySent
        self.onFirstFrame = onFirstFrame
    }

    // MARK: - Lifecycle (called from the main actor)

    /// Sets up the encoder on `queue`. Returns false if the hardware encoder
    /// could not be created.
    func start() -> Bool {
        queue.sync {
            if usesBC7Mode6 {
                bc7Encoder = TBBC7Mode6Encoder()
                if usesBC7TileDelta {
                    bc7DeltaPlanner = TBBC7DeltaPlanner(
                        keyframeIntervalFrames: preset.expectedFrameRate * 30
                    )
                }
                running = bc7Encoder != nil
                return running
            }
            if usesRawNV12 {
                if usesRawNV12LZ4 {
                    rawNV12ParallelLZ4 = TBNV12ParallelLZ4Encoder(
                        encoder: rawNV12LZ4Encoder,
                        threadCount: rawNV12LZ4Threads
                    )
                }
                if usesRawNV12TileRuns {
                    rawNV12TileDetector = TBNV12TileDetector()
                    guard rawNV12TileDetector != nil else { return false }
                }
                running = true
                return true
            }
            setupEncoder()
            running = vtEncoder != nil
            return running
        }
    }

    /// Tears the encoder down on `queue`. Because the queue is serial, any
    /// in-flight `encode` completes before `VTCompressionSessionInvalidate`,
    /// so a frame can never encode into an invalidated session.
    func stop() {
        queue.sync {
            running = false
            rawNV12HasBaseline = false
            rawNV12Width = 0
            rawNV12Height = 0
            rawNV12TileDetector?.reset()
            rawNV12ObservedDropped = 0
            lastRawNV12Frame = nil
            latestBC7Frame.cancel()
            latestRawNV12Frame.cancel()
            if let encoder = vtEncoder { VTCompressionSessionInvalidate(encoder) }
            vtEncoder = nil
            bc7Encoder = nil
            bc7DeltaPlanner = nil
            vtEncoderRef?.release()
            vtEncoderRef = nil
        }
    }

    // MARK: - Snapshots for the main thread

    var sentFramesSnapshot: Int {
        lock.lock(); defer { lock.unlock() }
        return _sentFrames
    }

    var lastCaptureFrameAtSnapshot: Date {
        lock.lock(); defer { lock.unlock() }
        return _lastCaptureFrameAt
    }

    var sentBytesSnapshot: Int {
        lock.lock(); defer { lock.unlock() }
        return _sentBytes
    }

    var capturedFramesSnapshot: Int {
        lock.lock(); defer { lock.unlock() }
        return _capturedFrames
    }

    func diagnosticsSnapshot() -> TBPipelineDiagnosticsSnapshot {
        queue.sync {
            lock.lock()
            defer { lock.unlock() }
            return TBPipelineDiagnosticsSnapshot(
                pending: pendingVideoPackets,
                inFlight: inFlightEncodeFrames,
                dropped: droppedVideoFrames + latestBC7Frame.droppedCount +
                    latestRawNV12Frame.droppedCount,
                ptsSeq: displayStreamFrameSequence,
                bc7Keyframes: bc7Keyframes,
                bc7DeltaFrames: bc7DeltaFrames,
                bc7DirtyTiles: bc7DirtyTiles,
                bc7FullEncodeFallbacks: bc7FullEncodeFallbacks,
                bc7ProcessedFrames: _bc7ProcessedFrames,
                bc7EncodeNanoseconds: _bc7EncodeNanoseconds,
                bc7PlanNanoseconds: _bc7PlanNanoseconds,
                bc7PacketNanoseconds: _bc7PacketNanoseconds,
                bc7GPUAnalyzedFrames: _bc7GPUAnalyzedFrames,
                bc7SendCompletedFrames: _bc7SendCompletedFrames,
                bc7SendNanoseconds: _bc7SendNanoseconds,
                bc7SendErrors: _bc7SendErrors,
                bc7CompressedPackets: _bc7CompressedPackets,
                bc7CompressionFallbacks: _bc7CompressionFallbacks,
                bc7RawPacketBytes: _bc7RawPacketBytes,
                bc7WirePacketBytes: _bc7WirePacketBytes,
                bc7CompressionMode: bc7CompressionMode.rawValue,
                captureComplete: _captureComplete,
                captureStarted: _captureStarted,
                captureIdle: _captureIdle,
                captureBlank: _captureBlank,
                captureSuspended: _captureSuspended,
                captureStopped: _captureStopped,
                captureUnknown: _captureUnknown,
                tileBudget: bc7TileBudgetController.currentBudget ?? bc7LastTotalTiles,
                deferredTiles: bc7DeferredTiles,
                worstDeferredAge: bc7WorstDeferredAge,
                captureInterval: _captureIntervalWindow.summary(),
                queueAge: _queueAgeWindow.summary(),
                encodeTime: _encodeTimeWindow.summary(),
                planTime: _planTimeWindow.summary(),
                packetTime: _packetTimeWindow.summary(),
                sendTime: _sendTimeWindow.summary(),
                packetBytes: _packetBytesWindow.summary(),
                dirtyTiles: _dirtyTilesWindow.summary(),
                planeSplitTime: _planeSplitTimeWindow.summary(),
                compressionTime: _compressionTimeWindow.summary(),
                nv12FullFrames: _nv12FullFrames,
                nv12RegionFrames: _nv12RegionFrames,
                nv12RawBytes: _nv12RawBytes,
                nv12WireBytes: _nv12WireBytes,
                nv12CopyTime: _nv12CopyTimeWindow.summary(),
                nv12CompressionTime: _nv12CompressionTimeWindow.summary(),
                nv12ChecksumTime: _nv12ChecksumTimeWindow.summary(),
                nv12PacketTime: _nv12PacketTimeWindow.summary(),
                nv12RegionPixels: _nv12RegionPixelsWindow.summary(),
                nv12DirtyPixels: _nv12DirtyPixelsWindow.summary(),
                nv12DirtyRectCount: _nv12DirtyRectCountWindow.summary(),
                nv12OverfetchPermille: _nv12OverfetchPermilleWindow.summary(),
                nv12TileDetectionTime:
                    _nv12TileDetectionTimeWindow.summary(),
                nv12RunCount: _nv12RunCountWindow.summary(),
                nv12ZeroCopyPackets: _nv12ZeroCopyPackets,
                nv12ZeroCopyFallbacks: _nv12ZeroCopyFallbacks,
                nv12LZ4Encoder: usesRawNV12LZ4
                    ? TBNV12ParallelLZ4Encoder.diagnosticName(
                        encoder: rawNV12LZ4Encoder,
                        threadCount: rawNV12LZ4Threads
                    )
                    : "off",
                nv12CopyRectFrames: _nv12CopyRectFrames,
                nv12CopyRectTiles: _nv12CopyRectTiles,
                nv12CopyRectRejects: _nv12CopyRectRejects,
                nv12CopyRectWriterFailures: _nv12CopyRectWriterFailures,
                nv12CopyRectSkippedSearches: _nv12CopyRectSkippedSearches,
                nv12CopyRectSearchTime:
                    _nv12CopyRectSearchTimeWindow.summary(),
                nv12CopyRectLastVector: usesRawNV12CopyRect
                    ? _nv12CopyRectLastVector.map { "\($0.x),\($0.y)" } ??
                        "none"
                    : "off",
                nv12CopyRectStats: _nv12CopyRectStats
            )
        }
    }

    func recordCaptureCallback(status: SCFrameStatus?) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        if let previous = _lastCaptureCallbackNanoseconds, now >= previous {
            _captureIntervalWindow.record(now - previous)
        }
        _lastCaptureCallbackNanoseconds = now
        switch status {
        case .complete?: _captureComplete += 1
        case .started?: _captureStarted += 1
        case .idle?: _captureIdle += 1
        case .blank?: _captureBlank += 1
        case .suspended?: _captureSuspended += 1
        case .stopped?: _captureStopped += 1
        case nil: _captureUnknown += 1
        @unknown default: _captureUnknown += 1
        }
        lock.unlock()
    }

    private func markCaptureFrame() {
        lock.lock()
        _capturedFrames += 1
        _lastCaptureFrameAt = Date()
        lock.unlock()
    }

    private func recordBC7Timing(
        encodeNanoseconds: UInt64,
        planNanoseconds: UInt64,
        packetNanoseconds: UInt64,
        usedGPUAnalysis: Bool
    ) {
        lock.lock()
        _bc7ProcessedFrames += 1
        _bc7EncodeNanoseconds &+= encodeNanoseconds
        _bc7PlanNanoseconds &+= planNanoseconds
        _bc7PacketNanoseconds &+= packetNanoseconds
        _encodeTimeWindow.record(encodeNanoseconds)
        _planTimeWindow.record(planNanoseconds)
        _packetTimeWindow.record(packetNanoseconds)
        if usedGPUAnalysis {
            _bc7GPUAnalyzedFrames += 1
        }
        lock.unlock()
    }

    private func recordBC7Compression(
        result: TBBC7CompressedPacketResult?,
        rawPacketBytes: Int,
        wirePacketBytes: Int,
        attempted: Bool
    ) {
        lock.lock()
        _bc7RawPacketBytes &+= UInt64(rawPacketBytes)
        _bc7WirePacketBytes &+= UInt64(wirePacketBytes)
        if let result {
            _bc7CompressedPackets += 1
            _planeSplitTimeWindow.record(result.planeSplitNanoseconds)
            _compressionTimeWindow.record(result.compressionNanoseconds)
        } else if attempted {
            _bc7CompressionFallbacks += 1
        }
        lock.unlock()
    }

    private func recordNV12Packet(
        _ result: TBNV12Compression.PacketResult,
        isRegion: Bool,
        dirtyPixels: Int,
        dirtyRectCount: Int = 1
    ) {
        lock.lock()
        if isRegion { _nv12RegionFrames += 1 } else { _nv12FullFrames += 1 }
        _nv12RawBytes &+= UInt64(result.rawBytes)
        _nv12WireBytes &+= UInt64(result.wireBytes)
        _nv12CopyTimeWindow.record(result.copyNanoseconds)
        _nv12CompressionTimeWindow.record(result.compressionNanoseconds)
        _nv12ChecksumTimeWindow.record(result.checksumNanoseconds)
        _nv12PacketTimeWindow.record(result.packetNanoseconds)
        _nv12RegionPixelsWindow.record(UInt64(result.regionPixels))
        _nv12DirtyPixelsWindow.record(UInt64(max(0, dirtyPixels)))
        _nv12DirtyRectCountWindow.record(UInt64(max(0, dirtyRectCount)))
        _nv12RunCountWindow.record(UInt64(max(0, result.runCount)))
        if dirtyPixels > 0 {
            _nv12OverfetchPermilleWindow.record(
                UInt64(result.regionPixels * 1000 / dirtyPixels)
            )
        }
        lock.unlock()
    }

    private func recordNV12RawBaseline(rawBytes: Int, wireBytes: Int) {
        lock.lock()
        _nv12FullFrames += 1
        _nv12RawBytes &+= UInt64(rawBytes)
        _nv12WireBytes &+= UInt64(wireBytes)
        _nv12RegionPixelsWindow.record(
            UInt64(preset.width * preset.height)
        )
        lock.unlock()
    }

    // MARK: - Encoder setup (on `queue`)

    private func setupEncoder() {
        if let encoder = vtEncoder { VTCompressionSessionInvalidate(encoder) }
        vtEncoder = nil
        vtEncoderRef?.release()
        vtEncoderRef = nil

        let spec: NSDictionary = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true
        ]
        let retained = Unmanaged.passRetained(self)
        vtEncoderRef = retained

        let callback: VTCompressionOutputCallback = { ref, _, status, _, sampleBuffer in
            guard let ref else { return }
            let pipeline = Unmanaged<TBVideoPipeline>.fromOpaque(ref).takeUnretainedValue()
            pipeline.queue.async {
                pipeline.inFlightEncodeFrames = max(0, pipeline.inFlightEncodeFrames - 1)
                guard status == noErr, let sampleBuffer else { return }
                pipeline.handleEncoded(sampleBuffer)
            }
        }

        var session: VTCompressionSession?
        guard VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(preset.width),
            height: Int32(preset.height),
            codecType: codecType,
            encoderSpecification: spec,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: callback,
            refcon: retained.toOpaque(),
            compressionSessionOut: &session
        ) == noErr, let session else {
            retained.release()
            vtEncoderRef = nil
            return
        }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        if codecType == kCMVideoCodecType_HEVC {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)
        } else {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: preset.expectedFrameRate))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: preset.maxKeyFrameInterval))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: preset.maxKeyFrameIntervalDuration))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: NSNumber(value: preset.maxFrameDelayCount))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: preset.averageBitRate))
        if preset.prioritizeSpeed {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
        vtEncoder = session
    }

    // MARK: - Encode paths (on `queue`)

    func submitCapturedFrame(_ sampleBuffer: CMSampleBuffer) {
        markCaptureFrame()
        guard usesBC7Mode6 else {
            if usesRawNV12 {
                let frame = TBCapturedFrame(
                    sampleBuffer: sampleBuffer,
                    receivedAtNanoseconds: DispatchTime.now().uptimeNanoseconds
                )
                if latestRawNV12Frame.submit(frame) {
                    queue.async { [weak self] in
                        self?.drainLatestRawNV12Frame()
                    }
                }
                return
            }
            queue.async { [weak self] in
                self?.encode(sampleBuffer)
            }
            return
        }
        let frame = TBCapturedFrame(
            sampleBuffer: sampleBuffer,
            receivedAtNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
        if latestBC7Frame.submit(frame) {
            queue.async { [weak self] in
                self?.drainLatestBC7Frame()
            }
        }
    }

    private func drainLatestRawNV12Frame() {
        guard pendingVideoPackets == 0 else { return }
        let taken = latestRawNV12Frame.takeWithDroppedCount()
        let dropped = taken.droppedCount
        if dropped > rawNV12ObservedDropped {
            rawNV12HasBaseline = false
            rawNV12TileDetector?.reset()
            rawNV12ObservedDropped = dropped
        }
        guard let capturedFrame = taken.value else {
            if latestRawNV12Frame.finishProcessing() {
                queue.async { [weak self] in self?.drainLatestRawNV12Frame() }
            }
            return
        }
        let queueAge = DispatchTime.now().uptimeNanoseconds -
            capturedFrame.receivedAtNanoseconds
        lock.lock()
        _queueAgeWindow.record(queueAge)
        lock.unlock()
        lastRawNV12Frame = capturedFrame
        encode(capturedFrame.sampleBuffer)
        if latestRawNV12Frame.finishProcessing(), pendingVideoPackets == 0 {
            queue.async { [weak self] in self?.drainLatestRawNV12Frame() }
        }
    }

    private func drainLatestBC7Frame() {
        guard pendingVideoPackets == 0 else { return }
        guard let capturedFrame = latestBC7Frame.take() else {
            if latestBC7Frame.finishProcessing() {
                queue.async { [weak self] in
                    self?.drainLatestBC7Frame()
                }
            }
            return
        }
        let queueAge = DispatchTime.now().uptimeNanoseconds -
            capturedFrame.receivedAtNanoseconds
        lock.lock()
        _queueAgeWindow.record(queueAge)
        lock.unlock()
        encode(capturedFrame.sampleBuffer)
        if latestBC7Frame.finishProcessing() {
            queue.async { [weak self] in
                self?.drainLatestBC7Frame()
            }
        }
    }

    /// Opt-in raw passthrough: ScreenCaptureKit already captures NV12,
    /// so we can forward the planes uncompressed and skip the encoder entirely.
    /// This removes all decode cost on the receiver — useful when the receiver is
    /// an older Intel Mac whose HEVC decoder struggles at high resolutions — at
    /// the price of much higher bandwidth (~10.6 Gb/s for 5K@60 4:2:0), which a
    /// direct Thunderbolt Bridge link comfortably sustains.
    /// SCStream capture path. Must be dispatched onto `queue` by the caller.
    func encode(_ sampleBuffer: CMSampleBuffer) {
        if usesBC7Mode6 {
            sendBC7Frame(sampleBuffer)
            return
        }
        if usesRawNV12 {
            sendRawFrame(sampleBuffer)
            return
        }
        guard running, let encoder = vtEncoder,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        if preset.dropsBeforeEncodeWhenBacklogged,
           (pendingVideoPackets >= preset.maxPendingVideoPackets ||
            inFlightEncodeFrames >= preset.maxInFlightEncodeFrames) {
            return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        encode(pixelBuffer: pixelBuffer, presentationTimeStamp: pts, using: encoder)
    }

    /// CGDisplayStream capture path. Delivered directly on `queue` by
    /// `TBDirectDisplayStreamCapture`.
    func encodeDisplaySurface(_ surface: IOSurfaceRef, displayTime: UInt64) {
        markCaptureFrame()
        guard running, let encoder = vtEncoder else { return }
        if preset.dropsBeforeEncodeWhenBacklogged,
           (pendingVideoPackets >= preset.maxPendingVideoPackets ||
            inFlightEncodeFrames >= preset.maxInFlightEncodeFrames) {
            return
        }

        let attrs: NSDictionary = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: preset.width,
            kCVPixelBufferHeightKey: preset.height,
            kCVPixelBufferIOSurfacePropertiesKey: NSDictionary()
        ]
        var unmanagedPixelBuffer: Unmanaged<CVPixelBuffer>?
        guard CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault,
            surface,
            attrs,
            &unmanagedPixelBuffer
        ) == kCVReturnSuccess, let unmanagedPixelBuffer else {
            return
        }
        let pixelBuffer = unmanagedPixelBuffer.takeRetainedValue()

        displayStreamFrameSequence += 1
        // Derive PTS from the frame's actual capture time. CGDisplayStream
        // delivers frames irregularly (event-driven on screen changes), so a
        // frame-counter PTS would drift away from real wall-clock time over a
        // long session and pace the receiver progressively wrong. displayTime is
        // in mach-absolute units, the same host clock the SCStream path uses.
        var pts = displayTime != 0
            ? CMClockMakeHostTimeFromSystemUnits(displayTime)
            : CMClockGetTime(CMClockGetHostTimeClock())
        if let last = lastEncodedDisplayPTS, CMTimeCompare(pts, last) <= 0 {
            // VTCompressionSession requires strictly increasing PTS.
            pts = CMTimeAdd(last, CMTime(value: 1, timescale: 600))
        }
        lastEncodedDisplayPTS = pts
        encode(pixelBuffer: pixelBuffer, presentationTimeStamp: pts, using: encoder)
    }

    private func encode(pixelBuffer: CVPixelBuffer, presentationTimeStamp pts: CMTime, using encoder: VTCompressionSession) {
        inFlightEncodeFrames += 1
        let status = VTCompressionSessionEncodeFrame(
            encoder,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
        if status != noErr {
            inFlightEncodeFrames = max(0, inFlightEncodeFrames - 1)
        }
    }

    private func handleEncoded(_ sampleBuffer: CMSampleBuffer) {
        guard running else { return }

        let dimensions = CMSampleBufferGetFormatDescription(sampleBuffer)
            .map(CMVideoFormatDescriptionGetDimensions)
        notifyFirstFrameIfNeeded(
            width: Int(dimensions?.width ?? 0),
            height: Int(dimensions?.height ?? 0)
        )

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let isKeyframe = !notSync

        if !isKeyframe, pendingVideoPackets >= preset.maxPendingVideoPackets {
            droppedVideoFrames += 1
            return
        }

        if isKeyframe,
           let format = CMSampleBufferGetFormatDescription(sampleBuffer),
           let packet = buildParamSetsPacket(from: format, codecType: codecType) {
            connection.send(content: packet, completion: .contentProcessed({ _ in }))
        }

        if let packet = buildFramePacket(from: sampleBuffer) {
            pendingVideoPackets += 1
            connection.send(content: packet, completion: .contentProcessed({ [weak self] _ in
                guard let self else { return }
                self.queue.async {
                    self.pendingVideoPackets = max(0, self.pendingVideoPackets - 1)
                }
            }))
            lock.lock(); _sentFrames += 1; _sentBytes += packet.count; lock.unlock()
        }
    }

    private func notifyFirstFrameIfNeeded(width: Int, height: Int) {
        if !ackSent {
            ackSent = true
            let ack = TBMonitorCreateSessionAck(
                accepted: true,
                displayName: displayName,
                displayID: displayID
            )
            if let packet = TBMonitorProtocol.makeJSONPacket(type: .createSessionAck, value: ack) {
                connection.send(content: packet, completion: .contentProcessed({ _ in }))
            }
        }
        if !firstFrameNotified {
            firstFrameNotified = true
            onFirstFrame(width, height)
        }
    }

    /// Raw passthrough: package the two NV12 planes of the captured pixel buffer
    /// and send them uncompressed. The receiver blits them directly (no decode).
    /// Payload: [1: format=1(NV12)][BE32 w][BE32 h][BE32 yStride][BE32 uvStride]
    ///          [Y plane: yStride*h][CbCr plane: uvStride*(h/2)]
    private func sendRawFrame(_ sampleBuffer: CMSampleBuffer) {
        guard running,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        // Backpressure: never pile frames on top of a network that can't keep up.
        if pendingVideoPackets != 0 {
            droppedVideoFrames += 1
            return
        }
        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2 else { return }

        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        if width != rawNV12Width || height != rawNV12Height {
            rawNV12HasBaseline = false
            rawNV12TileDetector?.reset()
            rawNV12PacketWriter = nil
            rawNV12LastCopyVector = nil
            rawNV12CopyRectBackoff.reset()
            rawNV12Width = width
            rawNV12Height = height
        }
        sampleRawNV12Pointer(width: width, height: height)
        let detectorHadBaseline = rawNV12TileDetector?.hasBaseline == true
        let detectedTiles: Set<Int>?
        var shouldCommitTileCandidate = false
        let tileGeometrySupported =
            width % TBNV12Compression.tileSize == 0 &&
            height % TBNV12Compression.tileSize == 0
        if usesRawNV12TileRuns, tileGeometrySupported {
            let detectionStarted = DispatchTime.now().uptimeNanoseconds
            detectedTiles = rawNV12TileDetector?.analyze(
                pixelBuffer: pixelBuffer
            )
            let detectionElapsed =
                DispatchTime.now().uptimeNanoseconds - detectionStarted
            lock.lock()
            _nv12TileDetectionTimeWindow.record(detectionElapsed)
            lock.unlock()
            if detectedTiles == nil {
                rawNV12TileDetector?.reset()
                rawNV12HasBaseline = false
            } else {
                shouldCommitTileCandidate = true
            }
            if rawNV12HasBaseline,
               detectorHadBaseline,
               detectedTiles?.isEmpty == true {
                rawNV12TileDetector?.commitCandidate()
                rawNV12CopyRectBackoff.reset()
                return
            }
        } else {
            detectedTiles = nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
        else { return }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let uvHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        let ySize = yStride * height
        let uvSize = uvStride * uvHeight

        // Send the session ack on the first frame, mirroring the encoded path.
        notifyFirstFrameIfNeeded(width: width, height: height)

        let packet: Data
        var isFullBaselinePacket = false
        let dirtyRects = Self.dirtyRects(
            from: sampleBuffer, pixelWidth: width, pixelHeight: height
        )

        let makeFullPacket: () -> Data = {
            let y = Data(bytes: yBase, count: ySize)
            let uv = Data(bytes: uvBase, count: uvSize)
            if self.usesRawNV12LZ4,
               let result = TBNV12Compression.makePacket(
                   y: y,
                   uv: uv,
                   width: width,
                   height: height,
                   yStride: yStride,
                   uvStride: uvStride,
                   checksumPolicy: self.rawNV12ChecksumPolicy,
                   encoder: self.rawNV12LZ4Encoder,
                   parallelEncoder: self.rawNV12ParallelLZ4
               ) {
                self.recordNV12Packet(
                    result,
                    isRegion: false,
                    dirtyPixels: width * height
                )
                return result.packet
            }
            var payload = Data(capacity: 17 + ySize + uvSize)
            payload.append(1)
            TBMonitorProtocol.appendBE32(&payload, UInt32(width))
            TBMonitorProtocol.appendBE32(&payload, UInt32(height))
            TBMonitorProtocol.appendBE32(&payload, UInt32(yStride))
            TBMonitorProtocol.appendBE32(&payload, UInt32(uvStride))
            payload.append(y)
            payload.append(uv)
            let rawPacket = TBMonitorProtocol.makePacket(
                type: .rawFrame, payload: payload
            )
            self.recordNV12RawBaseline(
                rawBytes: ySize + uvSize,
                wireBytes: rawPacket.count
            )
            return rawPacket
        }

        if usesRawNV12TileRuns,
           tileGeometrySupported,
           rawNV12HasBaseline,
           detectorHadBaseline,
           let detectedTiles {
            let tilesWide = width / TBNV12Compression.tileSize
            let tilesHigh = height / TBNV12Compression.tileSize
            let totalTiles = tilesWide * tilesHigh
            let tileRunCount = TBNV12Compression.tileRunCount(
                dirtyTiles: detectedTiles,
                width: width,
                height: height
            )
            if let result = makeRawNV12CopyRectPacket(
                yBase: yBase,
                uvBase: uvBase,
                width: width,
                height: height,
                yStride: yStride,
                uvStride: uvStride,
                dirtyTiles: detectedTiles
            ) {
                packet = result.packet
                recordNV12Packet(
                    result,
                    isRegion: true,
                    dirtyPixels: detectedTiles.count *
                        TBNV12Compression.tileSize *
                        TBNV12Compression.tileSize,
                    dirtyRectCount: result.runCount
                )
            } else if detectedTiles.count * 4 < totalTiles * 3,
               let tileRunCount, tileRunCount <= 256,
               let result = makeRawNV12TileRunPacket(
                   yBase: yBase,
                   uvBase: uvBase,
                   width: width,
                   height: height,
                   yStride: yStride,
                   uvStride: uvStride,
                   dirtyTiles: detectedTiles
               ) {
                packet = result.packet
                recordNV12Packet(
                    result,
                    isRegion: true,
                    dirtyPixels: result.regionPixels,
                    dirtyRectCount: result.runCount
                )
            } else {
                let tileXs = detectedTiles.map { $0 % tilesWide }
                let tileYs = detectedTiles.map { $0 / tilesWide }
                let minTileX = tileXs.min() ?? 0
                let maxTileX = tileXs.max() ?? (tilesWide - 1)
                let minTileY = tileYs.min() ?? 0
                let maxTileY = tileYs.max() ?? (tilesHigh - 1)
                let regionX = minTileX * TBNV12Compression.tileSize
                let regionY = minTileY * TBNV12Compression.tileSize
                let regionWidth =
                    (maxTileX - minTileX + 1) * TBNV12Compression.tileSize
                let regionHeight =
                    (maxTileY - minTileY + 1) * TBNV12Compression.tileSize
                if let result = TBNV12Compression.makeRegionPacket(
                    yBase: yBase,
                    uvBase: uvBase,
                    width: width,
                    height: height,
                    yStride: yStride,
                    uvStride: uvStride,
                    x: regionX,
                    y: regionY,
                    regionWidth: regionWidth,
                    regionHeight: regionHeight,
                    checksumPolicy: rawNV12ChecksumPolicy,
                    encoder: rawNV12LZ4Encoder,
                    parallelEncoder: rawNV12ParallelLZ4
                ) {
                    packet = result.packet
                    recordNV12Packet(
                        result,
                        isRegion: true,
                        dirtyPixels: detectedTiles.count *
                            TBNV12Compression.tileSize *
                            TBNV12Compression.tileSize,
                        dirtyRectCount: detectedTiles.count
                    )
                } else {
                    rawNV12HasBaseline = false
                    packet = makeFullPacket()
                    isFullBaselinePacket = true
                }
            }
        } else if usesRawNV12TileRuns,
                  tileGeometrySupported,
                  detectedTiles != nil {
            packet = makeFullPacket()
            isFullBaselinePacket = true
        } else if usesRawNV12LZ4, rawNV12HasBaseline,
           let rects = dirtyRects, rects.isEmpty {
            return
        } else if usesRawNV12LZ4, rawNV12HasBaseline,
                  let rects = dirtyRects {
            let union = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
            let x = max(0, Int(floor(union.minX)) & ~1)
            let y = max(0, Int(floor(union.minY)) & ~1)
            let maxX = min(width, (Int(ceil(union.maxX)) + 1) & ~1)
            let maxY = min(height, (Int(ceil(union.maxY)) + 1) & ~1)
            if let result = TBNV12Compression.makeRegionPacket(
                yBase: yBase, uvBase: uvBase,
                width: width, height: height,
                yStride: yStride, uvStride: uvStride,
                x: x, y: y, regionWidth: maxX - x, regionHeight: maxY - y,
                checksumPolicy: rawNV12ChecksumPolicy,
                encoder: rawNV12LZ4Encoder,
                parallelEncoder: rawNV12ParallelLZ4
            ) {
                packet = result.packet
                let dirtyPixels = rects.reduce(0) {
                    $0 + max(0, Int($1.width * $1.height))
                }
                recordNV12Packet(
                    result, isRegion: true, dirtyPixels: dirtyPixels,
                    dirtyRectCount: rects.count
                )
            } else {
                rawNV12HasBaseline = false
                let y = Data(bytes: yBase, count: ySize)
                let uv = Data(bytes: uvBase, count: uvSize)
                var payload = Data(capacity: 17 + ySize + uvSize)
                payload.append(1)
                TBMonitorProtocol.appendBE32(&payload, UInt32(width))
                TBMonitorProtocol.appendBE32(&payload, UInt32(height))
                TBMonitorProtocol.appendBE32(&payload, UInt32(yStride))
                TBMonitorProtocol.appendBE32(&payload, UInt32(uvStride))
                payload.append(y); payload.append(uv)
                packet = TBMonitorProtocol.makePacket(
                    type: .rawFrame, payload: payload
                )
                isFullBaselinePacket = true
                recordNV12RawBaseline(
                    rawBytes: ySize + uvSize,
                    wireBytes: packet.count
                )
            }
        } else if usesRawNV12LZ4 {
            packet = makeFullPacket()
            isFullBaselinePacket = true
        } else {
            let y = Data(bytes: yBase, count: ySize)
            let uv = Data(bytes: uvBase, count: uvSize)
            var payload = Data(capacity: 17 + ySize + uvSize)
            payload.append(1)
            TBMonitorProtocol.appendBE32(&payload, UInt32(width))
            TBMonitorProtocol.appendBE32(&payload, UInt32(height))
            TBMonitorProtocol.appendBE32(&payload, UInt32(yStride))
            TBMonitorProtocol.appendBE32(&payload, UInt32(uvStride))
            payload.append(y)
            payload.append(uv)
            packet = TBMonitorProtocol.makePacket(type: .rawFrame, payload: payload)
            recordNV12RawBaseline(
                rawBytes: ySize + uvSize,
                wireBytes: packet.count
            )
        }
        pendingVideoPackets += 1
        let sendStarted = DispatchTime.now().uptimeNanoseconds
        let fullBaselinePacket = isFullBaselinePacket
        let commitTileCandidate = shouldCommitTileCandidate
        connection.send(content: packet, completion: .contentProcessed({ [weak self] error in
            guard let self else { return }
            self.queue.async {
                self.pendingVideoPackets = max(0, self.pendingVideoPackets - 1)
                self.lock.lock()
                if error == nil {
                    self._bc7SendCompletedFrames += 1
                    let elapsed =
                        DispatchTime.now().uptimeNanoseconds - sendStarted
                    self._bc7SendNanoseconds &+= elapsed
                    self._sendTimeWindow.record(elapsed)
                    if fullBaselinePacket {
                        self.rawNV12HasBaseline = true
                    }
                    if commitTileCandidate {
                        self.rawNV12TileDetector?.commitCandidate()
                    }
                } else {
                    self._bc7SendErrors += 1
                    self.rawNV12HasBaseline = false
                    self.rawNV12TileDetector?.discardCandidate()
                    self.rawNV12TileDetector?.reset()
                }
                self.lock.unlock()
                self.drainLatestRawNV12Frame()
            }
        }))
        lock.lock(); _sentFrames += 1; _sentBytes += packet.count; lock.unlock()
    }

    /// Builds a tile-run packet, preferring the zero-copy writer unless
    /// `TB_NV12_ZERO_COPY=0`. Both paths use `rawNV12LZ4Encoder` and produce
    /// byte-identical packets.
    private func makeRawNV12TileRunPacket(
        yBase: UnsafeRawPointer,
        uvBase: UnsafeRawPointer,
        width: Int,
        height: Int,
        yStride: Int,
        uvStride: Int,
        dirtyTiles: Set<Int>
    ) -> TBNV12Compression.PacketResult? {
        if usesRawNV12ZeroCopy {
            if let result = rawNV12PacketWriter(
                width: width, height: height
            )?.makeTileRunPacket(
                yBase: yBase,
                uvBase: uvBase,
                yStride: yStride,
                uvStride: uvStride,
                dirtyTiles: dirtyTiles,
                checksumPolicy: rawNV12ChecksumPolicy
            ) {
                lock.lock(); _nv12ZeroCopyPackets += 1; lock.unlock()
                return result
            }
            lock.lock(); _nv12ZeroCopyFallbacks += 1; lock.unlock()
        }
        return TBNV12Compression.makeTileRunPacket(
            yBase: yBase,
            uvBase: uvBase,
            width: width,
            height: height,
            yStride: yStride,
            uvStride: uvStride,
            dirtyTiles: dirtyTiles,
            checksumPolicy: rawNV12ChecksumPolicy,
            encoder: rawNV12LZ4Encoder,
            parallelEncoder: rawNV12ParallelLZ4
        )
    }

    private func rawNV12PacketWriter(
        width: Int, height: Int
    ) -> TBNV12TileRunPacketWriter? {
        if rawNV12PacketWriter == nil {
            let lz4 = rawNV12ParallelLZ4 ?? TBNV12ParallelLZ4Encoder(
                encoder: rawNV12LZ4Encoder,
                threadCount: rawNV12LZ4Threads
            )
            rawNV12ParallelLZ4 = lz4
            rawNV12PacketWriter = TBNV12TileRunPacketWriter(
                width: width, height: height, lz4: lz4
            )
        }
        return rawNV12PacketWriter
    }

    /// Format 5 for window drags and scrolls: dirty tiles that equal the
    /// committed baseline under one shift are copied by the Receiver from
    /// its own screen, the rest are sent as tile runs. Returns nil whenever
    /// the frame is better sent another way. Must run between `analyze` and
    /// committing the detector candidate, while the committed baseline still
    /// equals the Receiver's screen.
    private func makeRawNV12CopyRectPacket(
        yBase: UnsafeRawPointer,
        uvBase: UnsafeRawPointer,
        width: Int,
        height: Int,
        yStride: Int,
        uvStride: Int,
        dirtyTiles: Set<Int>
    ) -> TBNV12Compression.PacketResult? {
        guard usesRawNV12CopyRect, usesRawNV12ZeroCopy,
              let detector = rawNV12TileDetector
        else {
            return nil
        }
        guard dirtyTiles.count >= 32 else {
            rawNV12CopyRectBackoff.reset()
            return nil
        }
        let pointerDelta = rawNV12PointerDelta ?? .zero
        guard rawNV12CopyRectBackoff.shouldSearch(
            at: DispatchTime.now().uptimeNanoseconds,
            pointerMoving: pointerDelta != .zero
        ) else {
            lock.lock()
            _nv12CopyRectSkippedSearches += 1
            _nv12CopyRectStats.skippedTiles += dirtyTiles.count
            lock.unlock()
            return nil
        }
        let searchStarted = DispatchTime.now().uptimeNanoseconds
        let copyRect = detector.findCopyRect(
            dirtyTiles: dirtyTiles,
            preferred: rawNV12LastCopyVector,
            predictions: [rawNV12LastCopyVector, rawNV12PointerDelta]
                .compactMap { $0 }
                .filter { $0 != .zero }
        )
        let searchElapsed = DispatchTime.now().uptimeNanoseconds - searchStarted
        lock.lock(); _nv12CopyRectSearchTimeWindow.record(searchElapsed); lock.unlock()
        guard let copyRect, copyRect.tiles.count * 4 >= dirtyTiles.count
        else {
            rawNV12LastCopyVector = nil
            rawNV12CopyRectBackoff.recordMiss()
            lock.lock()
            if copyRect == nil {
                _nv12CopyRectStats.noVectorFrames += 1
            } else {
                _nv12CopyRectStats.lowCoverageFrames += 1
            }
            if max(abs(pointerDelta.x), abs(pointerDelta.y)) >
                TBNV12TileDetector.CopyRectSearch.dragRadius {
                _nv12CopyRectStats.fastPointerMisses += 1
            }
            _nv12CopyRectStats.missedTiles += dirtyTiles.count
            lock.unlock()
            return nil
        }
        let freshTiles = dirtyTiles.subtracting(copyRect.tiles)
        guard let freshRunCount = TBNV12Compression.tileRunCount(
                  dirtyTiles: freshTiles, width: width, height: height
              ),
              freshRunCount <= 256
        else {
            rawNV12CopyRectBackoff.recordMiss()
            lock.lock()
            _nv12CopyRectRejects += 1
            _nv12CopyRectStats.missedTiles += dirtyTiles.count
            lock.unlock()
            return nil
        }
        // A busy writer slot says nothing about the content, so it does not
        // feed the backoff.
        guard let result = rawNV12PacketWriter(
                  width: width, height: height
              )?.makeCopyRectPacket(
                  yBase: yBase,
                  uvBase: uvBase,
                  yStride: yStride,
                  uvStride: uvStride,
                  copyTiles: copyRect.tiles,
                  dx: copyRect.dx,
                  dy: copyRect.dy,
                  freshTiles: freshTiles,
                  checksumPolicy: rawNV12ChecksumPolicy
              )
        else {
            lock.lock()
            _nv12CopyRectWriterFailures += 1
            _nv12CopyRectStats.missedTiles += dirtyTiles.count
            lock.unlock()
            return nil
        }
        let vector = SIMD2(copyRect.dx, copyRect.dy)
        rawNV12LastCopyVector = vector
        rawNV12CopyRectBackoff.reset()
        lock.lock()
        _nv12ZeroCopyPackets += 1
        _nv12CopyRectFrames += 1
        _nv12CopyRectTiles += copyRect.tiles.count
        _nv12CopyRectLastVector = vector
        _nv12CopyRectStats.recordHit(
            dx: copyRect.dx, dy: copyRect.dy,
            copyTiles: copyRect.tiles, freshTiles: freshTiles,
            tilesWide: width / TBNV12Compression.tileSize,
            tilesHigh: height / TBNV12Compression.tileSize
        )
        lock.unlock()
        return result
    }

    /// Records how far the pointer moved since the previous frame, scaled
    /// to captured pixels. A window drag moves the window by the same
    /// amount, so the move is a search prediction even beyond the drag box.
    private func sampleRawNV12Pointer(width: Int, height: Int) {
        let pointer = CGEvent(source: nil)?.location
        let bounds = CGDisplayBounds(displayID)
        if let pointer, let last = rawNV12LastPointer,
           bounds.width > 0, bounds.height > 0 {
            rawNV12PointerDelta = SIMD2(
                Int(((pointer.x - last.x) * CGFloat(width) / bounds.width)
                    .rounded()),
                Int(((pointer.y - last.y) * CGFloat(height) / bounds.height)
                    .rounded())
            )
        } else {
            rawNV12PointerDelta = nil
        }
        rawNV12LastPointer = pointer
    }

    func requestRawNV12Keyframe() {
        queue.async { [weak self] in
            guard let self else { return }
            self.rawNV12HasBaseline = false
            self.rawNV12TileDetector?.reset()
            self.rawNV12LastCopyVector = nil
            self.rawNV12CopyRectBackoff.reset()
            guard let frame = self.lastRawNV12Frame else { return }
            let retry = TBCapturedFrame(
                sampleBuffer: frame.sampleBuffer,
                receivedAtNanoseconds: DispatchTime.now().uptimeNanoseconds
            )
            let result = self.latestRawNV12Frame.submitIfEmpty(retry)
            if result.shouldSchedule {
                self.drainLatestRawNV12Frame()
            }
        }
    }

    private func sendBC7Frame(_ sampleBuffer: CMSampleBuffer) {
        guard running else { return }
        guard pendingVideoPackets == 0 else {
            droppedVideoFrames += 1
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        let requiresFullFrame = bc7DeltaPlanner?.requiresFullFrame != false
        let dirtyRects = usesBC7TileDelta && !requiresFullFrame
            ? Self.dirtyRects(
                from: sampleBuffer,
                pixelWidth: CVPixelBufferGetWidth(pixelBuffer),
                pixelHeight: CVPixelBufferGetHeight(pixelBuffer)
            )
            : nil
        if usesBC7TileDelta && !requiresFullFrame && dirtyRects == nil {
            bc7FullEncodeFallbacks += 1
        }
        let encodeStarted = DispatchTime.now().uptimeNanoseconds
        guard
              let encoded = bc7Encoder?.encode(
                  pixelBuffer: pixelBuffer,
                  dirtyRects: dirtyRects,
                  allowEmptyDirtyPlan: bc7DeltaPlanner?.hasDeferredTiles == true
              )
        else {
            return
        }
        let encodeFinished = DispatchTime.now().uptimeNanoseconds

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        notifyFirstFrameIfNeeded(width: width, height: height)

        let planStarted = DispatchTime.now().uptimeNanoseconds
        let planner = bc7DeltaPlanner
        let totalTiles =
            (width / TBBC7DeltaPlanner.tileSize) *
            ((height + TBBC7DeltaPlanner.tileSize - 1) / TBBC7DeltaPlanner.tileSize)
        bc7LastTotalTiles = totalTiles
        let tileBudget = bc7TileBudgetController.budget(totalTiles: totalTiles)
        let plan = planner?.plan(
               current: encoded.data,
               width: width,
               height: height,
               bytesPerRow: encoded.bytesPerRow,
               candidateDirtyTiles: encoded.candidateDirtyTiles,
               analyzedDirtyTiles: encoded.tileAnalysis?.dirtyTiles,
               analyzedChecksums: encoded.tileAnalysis?.checksums,
               maxTilesPerDelta: tileBudget
           )
        if let stats = planner?.lastStats {
            bc7DeferredTiles = stats.deferredTiles
            bc7WorstDeferredAge = stats.worstDeferredAge
            lock.lock()
            _dirtyTilesWindow.record(UInt64(stats.dirtyTiles))
            lock.unlock()
        }
        let planFinished = DispatchTime.now().uptimeNanoseconds
        let packetStarted = planFinished
        let rawPacket: Data
        if let plan {
            switch plan {
            case let .keyframe(sequence, checksum, data):
                bc7Keyframes += 1
                var payload = Data(capacity: 29 + data.count)
                payload.append(2)
                TBMonitorProtocol.appendBE64(&payload, sequence)
                TBMonitorProtocol.appendBE64(&payload, checksum)
                TBMonitorProtocol.appendBE32(&payload, UInt32(width))
                TBMonitorProtocol.appendBE32(&payload, UInt32(height))
                TBMonitorProtocol.appendBE32(&payload, UInt32(encoded.bytesPerRow))
                payload.append(data)
                rawPacket = TBMonitorProtocol.makePacket(type: .bc7Frame, payload: payload)
            case let .delta(sequence, baseSequence, checksum, runs, dirtyTiles, _):
                bc7DeltaFrames += 1
                bc7DirtyTiles += dirtyTiles
                guard let deltaPacket = tbMakeBC7DeltaPacket(
                    current: encoded.data,
                    width: width,
                    height: height,
                    bytesPerRow: encoded.bytesPerRow,
                    sequence: sequence,
                    baseSequence: baseSequence,
                    checksum: checksum,
                    runs: runs
                ) else {
                    planner?.markSendFailure()
                    TBLog.connection.error("Unable to serialize BC7 delta packet")
                    return
                }
                rawPacket = deltaPacket
            }
        } else {
            bc7Keyframes += 1
            var payload = Data(capacity: 13 + encoded.data.count)
            payload.append(1)
            TBMonitorProtocol.appendBE32(&payload, UInt32(width))
            TBMonitorProtocol.appendBE32(&payload, UInt32(height))
            TBMonitorProtocol.appendBE32(&payload, UInt32(encoded.bytesPerRow))
            payload.append(encoded.data)
            rawPacket = TBMonitorProtocol.makePacket(type: .bc7Frame, payload: payload)
        }
        let packetFinished = DispatchTime.now().uptimeNanoseconds
        recordBC7Timing(
            encodeNanoseconds: encodeFinished - encodeStarted,
            planNanoseconds: planFinished - planStarted,
            packetNanoseconds: packetFinished - packetStarted,
            usedGPUAnalysis: encoded.tileAnalysis != nil
        )
        let selection = tbSelectBC7WirePacket(
            rawPacket: rawPacket,
            compressionMode: bc7CompressionMode
        )
        let packet = selection.packet
        recordBC7Compression(
            result: selection.compressedResult,
            rawPacketBytes: rawPacket.count,
            wirePacketBytes: packet.count,
            attempted: selection.compressionAttempted
        )
        pendingVideoPackets += 1
        let sendStarted = DispatchTime.now().uptimeNanoseconds
        let packetBytes = packet.count
        lock.lock()
        _packetBytesWindow.record(UInt64(packetBytes))
        lock.unlock()
        connection.send(content: packet, completion: .contentProcessed({ [weak self] error in
            guard let self else { return }
            let sendNanoseconds =
                DispatchTime.now().uptimeNanoseconds - sendStarted
            self.queue.async {
                self.pendingVideoPackets = max(0, self.pendingVideoPackets - 1)
                if let error {
                    self.bc7DeltaPlanner?.markSendFailure()
                    TBLog.connection.error("BC7 frame send failed: \(error.localizedDescription, privacy: .public)")
                    self.lock.lock()
                    self._bc7SendErrors += 1
                    self.lock.unlock()
                } else {
                    self.bc7TileBudgetController.recordSend(
                        durationNanoseconds: sendNanoseconds,
                        totalTiles: self.bc7LastTotalTiles
                    )
                    self.lock.lock()
                    self._bc7SendCompletedFrames += 1
                    self._bc7SendNanoseconds &+= sendNanoseconds
                    self._sendTimeWindow.record(sendNanoseconds)
                    self.lock.unlock()
                }
                self.drainLatestBC7Frame()
            }
        }))
        lock.lock()
        _sentFrames += 1
        _sentBytes += packetBytes
        lock.unlock()
    }

    private static func dirtyRects(
        from sampleBuffer: CMSampleBuffer,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> [CGRect]? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let frame = attachments.first
        else {
            return nil
        }
        return tbBC7DirtyRects(
            from: frame,
            outputWidth: pixelWidth,
            outputHeight: pixelHeight
        )
    }

    func requestBC7Keyframe() {
        queue.async { [weak self] in
            self?.bc7DeltaPlanner?.markSendFailure()
        }
    }

    private func buildParamSetsPacket(from format: CMVideoFormatDescription, codecType: CMVideoCodecType) -> Data? {
        if codecType == kCMVideoCodecType_HEVC {
            var count = 0
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format,
                parameterSetIndex: 0,
                parameterSetPointerOut: nil,
                parameterSetSizeOut: nil,
                parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: nil
            )
            guard count > 0 else { return nil }

            var payload = Data([2, UInt8(count)])
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format,
                    parameterSetIndex: index,
                    parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size,
                    parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil
                )
                guard let pointer else { continue }
                TBMonitorProtocol.appendBE32(&payload, UInt32(size))
                payload.append(UnsafeBufferPointer(start: pointer, count: size))
            }
            return TBMonitorProtocol.makePacket(type: .paramSets, payload: payload)
        } else {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format,
                parameterSetIndex: 0,
                parameterSetPointerOut: nil,
                parameterSetSizeOut: nil,
                parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: nil
            )
            guard count > 0 else { return nil }

            var payload = Data([1, UInt8(count)])
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format,
                    parameterSetIndex: index,
                    parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size,
                    parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil
                )
                guard let pointer else { continue }
                TBMonitorProtocol.appendBE32(&payload, UInt32(size))
                payload.append(UnsafeBufferPointer(start: pointer, count: size))
            }
            return TBMonitorProtocol.makePacket(type: .paramSets, payload: payload)
        }
    }

    private func buildFramePacket(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let totalLength = CMBlockBufferGetDataLength(blockBuffer)
        guard totalLength > 0 else { return nil }

        var payload = Data(count: totalLength)
        let status = payload.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return kCMBlockBufferBadCustomBlockSourceErr
            }
            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: totalLength,
                destination: baseAddress
            )
        }
        guard status == kCMBlockBufferNoErr else { return nil }
        return TBMonitorProtocol.makePacket(type: .frame, payload: payload)
    }
}

/// Live, frequently-updating session readouts (currently just the FPS counter),
/// split out of `TBDisplaySenderSession` so their ~1 Hz changes only invalidate
/// the small subview that displays them rather than the whole session card.
@MainActor
final class TBSessionLiveMetrics: ObservableObject {
    @Published var senderFPS = 0
    @Published var senderNetworkGbps = 0.0
    @Published var receiverFPS = 0.0
}

@MainActor
final class TBDisplaySenderSession: NSObject, ObservableObject, Identifiable, @unchecked Sendable {
    private static let receiverIPDefaultsKey = "fd.tbdisplaysender.receiverIP"
    private struct SavedExtendedDisplayArrangement {
        let x: Int32
        let y: Int32
        let isRelativeToMainDisplay: Bool
    }

    private static let extendedArrangementDefaultsPrefix = "com.targetbridge.sender.extended-arrangement"

    private static func normalizedPng(for image: NSImage) -> Data? {
        let targetSize = NSSize(width: 32, height: 32)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetSize.width),
            pixelsHigh: Int(targetSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        let context = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        // Clear canvas
        NSColor.clear.set()
        NSRect(origin: .zero, size: targetSize).fill()

        // Draw the image centered
        let x = (targetSize.width - image.size.width) / 2
        let y = (targetSize.height - image.size.height) / 2
        image.draw(in: NSRect(x: x, y: y, width: image.size.width, height: image.size.height))

        NSGraphicsContext.restoreGraphicsState()

        return bitmap.representation(using: .png, properties: [:])
    }

    private static let standardCursorPngs: [Data: Int] = {
        let standardCursors: [(Int, NSCursor)] = [
            (0, NSCursor.arrow),
            (1, NSCursor.iBeam),
            (2, NSCursor.pointingHand),
            (3, NSCursor.resizeLeft),
            (3, NSCursor.resizeRight),
            (3, NSCursor.resizeLeftRight),
            (4, NSCursor.resizeUp),
            (4, NSCursor.resizeDown),
            (4, NSCursor.resizeUpDown),
            (5, NSCursor.closedHand),
            (5, NSCursor.openHand),
            (6, NSCursor.crosshair)
        ]
        var dict = [Data: Int]()
        for (type, cursor) in standardCursors {
            if let png = normalizedPng(for: cursor.image) {
                dict[png] = type
            }
        }

        // Dynamically load private system window resize cursors to support macOS window borders perfectly
        let privateCursors: [(Int, String)] = [
            (3, "_windowResizeEastWestCursor"),
            (4, "_windowResizeNorthSouthCursor"),
            (7, "_windowResizeNorthWestSouthEastCursor"),
            (8, "_windowResizeNorthEastSouthWestCursor"),
            (3, "_horizontalResizeCursor"),
            (4, "_verticalResizeCursor")
        ]
        for (type, selName) in privateCursors {
            let sel = NSSelectorFromString(selName)
            if NSCursor.responds(to: sel),
               let cursorObj = NSCursor.perform(sel)?.takeUnretainedValue() as? NSCursor,
               let png = normalizedPng(for: cursorObj.image) {
                dict[png] = type
            }
        }

        return dict
    }()

    let id = UUID()

    init(
        language: TBDisplaySenderLanguage,
        largeCursor: Bool,
        preventDisplaySleep: Bool,
        autoRestartOnWake: Bool,
        audioEnabled: Bool,
        verboseDisplayLogging: Bool = false
    ) {
        self.statusText = TBDisplaySenderStatusState.ready.text(language)
        self.receiverPanelText = TBDisplaySenderL10n.waitingReceiverProfile(language)
        self.virtualDisplayText = TBDisplaySenderL10n.virtualDisplayNotCreated(language)
        self.captureDisplayText = TBDisplaySenderL10n.captureDisplayNotAvailable(language)
        self.displayStateText = TBDisplaySenderL10n.displayStateNotAvailable(language)
        self.language = language
        self.largeCursor = largeCursor
        self.preventDisplaySleep = preventDisplaySleep
        self.autoRestartOnWake = autoRestartOnWake
        self.audioEnabled = audioEnabled
        self.verboseDisplayLogging = verboseDisplayLogging
        self.streamResolutionText = TBDisplaySenderL10n.streamSummary(
            preset: .standard1440p,
            source: .desktopMirror,
            language: language
        )
        super.init()
        registerWakeObservers()
        registerDisplayReconfigurationCallback()
    }

    deinit {
        for token in wakeObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            DistributedNotificationCenter.default().removeObserver(token)
        }
        if displayReconfigurationCallbackRegistered {
            CGDisplayRemoveReconfigurationCallback(
                Self.displayReconfigurationCallback,
                Unmanaged.passUnretained(self).toOpaque()
            )
        }
    }

    @Published var isConnected = false
    @Published var isStreaming = false
    @Published private(set) var connectionStartedAt: Date?
    @Published var statusText: String
    @Published var transportKind: TBTransportKind = .thunderboltBridge
    @Published var localInterfaceIP = ""
    @Published var selectedReceiverID = "" {
        didSet {
            if selectedReceiverID.isEmpty {
                receiverSupportsHEVCDecodeHint = nil
                receiverSupportsRawNV12Hint = nil
                receiverSupportsRawNV12LZ4Hint = nil
                receiverSupportsRawNV12TileRunsHint = nil
                receiverSupportsBC7Mode6Hint = nil
                receiverSupportsBC7TileDeltaHint = nil
                receiverSupportsBC7LZFSEHint = nil
                receiverSupportsBC7LZ4Hint = nil
                receiverInputMonitoringTrustedHint = nil
                receiverAccessibilityTrustedHint = nil
            }
        }
    }
    @Published var isCableTesting = false
    @Published var cableTestResult: Double? = nil
    private var isCableTestConnection = false
    @Published var receiverIP: String = UserDefaults.standard.string(forKey: receiverIPDefaultsKey) ?? "" {
        didSet {
            UserDefaults.standard.set(receiverIP, forKey: Self.receiverIPDefaultsKey)
            if receiverIP != oldValue {
                receiverSupportsHEVCDecodeHint = nil
                receiverSupportsRawNV12Hint = nil
                receiverSupportsRawNV12LZ4Hint = nil
                receiverSupportsRawNV12TileRunsHint = nil
                receiverSupportsBC7Mode6Hint = nil
                receiverSupportsBC7TileDeltaHint = nil
                receiverSupportsBC7LZFSEHint = nil
                receiverSupportsBC7LZ4Hint = nil
                receiverInputMonitoringTrustedHint = nil
                receiverAccessibilityTrustedHint = nil
            }
        }
    }
    var shortHostName: String? {
        if let receiver = TBDisplaySenderService.shared.discoveredReceivers.first(where: {
            $0.id == selectedReceiverID ||
            $0.preferredIP == receiverIP ||
            $0.thunderboltIP == receiverIP ||
            $0.networkIP == receiverIP
        }) {
            return receiver.shortHostName
        }
        return nil
    }

    var receiverDisplayName: String {
        if let host = shortHostName {
            return host
        }
        return receiverIP.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var receiverSubtitle: String {
        var parts: [String] = []
        let ip = receiverIP.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ip.isEmpty {
            parts.append("\(TBDisplaySenderL10n.receiverIP(language)) \(ip)")
        }
        if !receiverPanelText.isEmpty {
            parts.append(receiverPanelText)
        }
        return parts.joined(separator: "\n")
    }

    @Published var audioEnabled: Bool
    @Published var brightness: Double = 1.0 {
        didSet {
            sendBrightnessUpdate()
        }
    }
    @Published var volume: Double = 0.5 {
        didSet {
            sendVolumeUpdate()
        }
    }
    var audioAddonAvailable = true
    var receiverSupportsHEVCDecodeHint: Bool?
    var receiverSupportsRawNV12Hint: Bool?
    var receiverSupportsRawNV12LZ4Hint: Bool?
    var receiverSupportsRawNV12TileRunsHint: Bool?
    var receiverSupportsBC7Mode6Hint: Bool?
    var receiverSupportsBC7TileDeltaHint: Bool?
    var receiverSupportsBC7LZFSEHint: Bool?
    var receiverSupportsBC7LZ4Hint: Bool?
    var receiverInputMonitoringTrustedHint: Bool?
    var receiverAccessibilityTrustedHint: Bool?
    @Published var senderFPS = 0
    // Live FPS readout. Kept on a dedicated observable so its once-per-second
    // update only re-renders the small FPS subview — not the whole session card
    // or (via the manager's objectWillChange bubble-up) the entire window.
    let liveMetrics = TBSessionLiveMetrics()
    @Published var receiverPanelText: String
    @Published var virtualDisplayText: String
    @Published var captureDisplayText: String
    @Published var displayStateText: String
    @Published var displayModeDiagnosticsText = "Not active"
    @Published var receiverMetricsText = "Not available"
    @Published private(set) var sessionLogEntries: [TBSessionLogEntry] = []
    @Published var language: TBDisplaySenderLanguage {
        didSet {
            refreshLocalizedText()
        }
    }
    @Published var largeCursor: Bool
    @Published var preventDisplaySleep: Bool = true
    @Published var autoRestartOnWake: Bool = true
    @Published var verboseDisplayLogging: Bool = false {
        didSet {
            if verboseDisplayLogging {
                startVerboseLoggingTimer()
            } else {
                stopVerboseLoggingTimer()
            }
        }
    }
    /// When enabled, the virtual display's backing store is sized to the capture
    /// preset instead of the receiver-advertised 5120x2880. Removes the capture-side
    /// downsample and the GPU cost of rendering pixels that get thrown away.
    @Published var matchRenderToStream: Bool = false

    @Published var videoTransportMode: TBVideoTransportMode = .automatic {
        didSet {
            if !isStreaming {
                refreshConfiguredStreamSummary()
            }
        }
    }
    @Published var bc7CompressionMode: TBBC7CompressionMode = .lz4
    @Published var capturePreset: TBDisplayCapturePreset = .standard1440p {
        didSet {
            if !isStreaming {
                refreshConfiguredStreamSummary()
            }
        }
    }
    @Published var captureSource: TBDisplayCaptureSource = .desktopMirror {
        didSet {
            if !isStreaming {
                refreshConfiguredStreamSummary()
            }
        }
    }
    @Published var streamResolutionText: String
    @Published var actualStreamText = "Not active"
    @Published var bc7TestStatusText = ""
    @Published var transportDiagnosticsText = "pending=0 · in-flight=0 · dropped=0 · 0.00 Gbit/s"
    var inputRelayActive = false {
        didSet {
            guard inputRelayActive != oldValue else { return }
            applyCursorOverlayMode()
        }
    }
    @Published var inputControlRole: TBInputControlRole = .off {
        didSet {
            inputRelayActive = (inputControlRole == .senderMaster)
            if inputControlRole != .receiverMaster {
                injectedRemoteMouseLocation = nil
                injectedLeftClickTracker.reset()
                releaseInjectedModifiersIfNeeded()
                remoteHeldModifierKeyCodes.removeAll()
                suppressedTriggerKeyCode = nil
            }
        }
    }
    @Published var inputGestureMode: TBInputGestureMode = .native
    /// User-defined receiver-master shortcuts for this session. See
    /// TBInputBinding.
    @Published var inputBindings: [TBInputBinding] = []

    private var connection: NWConnection?
    private let connectionQueue = DispatchQueue(label: "fd.tbmonitor.sender.connection", qos: .userInteractive)
    private var recvBuffer = Data()

    private var session = ReceiverBackedVirtualDisplaySession()
    private let audioConverter = SBAudioConverter()
    private var activeProfile: TBMonitorDisplayProfile?
    private var activeCodecType: CMVideoCodecType?
    private var activeCodecName: String?

    private var captureDelegate: CaptureDelegate?
    private var scStream: SCStream?
    private var directDisplayStream: TBDirectDisplayStreamCapture?
    private var pipeline: TBVideoPipeline?

    private var sentSnapshot = 0
    private var sentBytesSnapshot = 0
    private var capturedSnapshot = 0
    private var bc7ProcessedSnapshot = 0
    private var bc7EncodeNanosecondsSnapshot: UInt64 = 0
    private var bc7PlanNanosecondsSnapshot: UInt64 = 0
    private var bc7PacketNanosecondsSnapshot: UInt64 = 0
    private var bc7GPUAnalyzedSnapshot = 0
    private var bc7SendCompletedSnapshot = 0
    private var bc7SendNanosecondsSnapshot: UInt64 = 0
    private var fpsSnapshotAt = Date()
    private var sessionAckSent = false
    private var pipelineHasFirstFrame = false
    private var captureGeneration: UInt64 = 0
    private var bc7RenderConfirmed = false
    private var bc7RenderGeneration: UInt32 = 0
    private var lastReceiverMetrics: TBMonitorReceiverMetrics?
    private var fpsTimer: Timer?
    private var heartbeatTimer: Timer?
    private var heartbeatLivenessTimer: Timer?
    private var firstFrameTimer: Timer?
    private var cursorTimer: Timer?
    private var connectTimeoutWorkItem: DispatchWorkItem?
    /// Name of the local interface the current connect attempt is bound to
    /// (e.g. "bridge0"), resolved when dialing. Diagnostic context only.
    private var connectInterfaceName: String?
    /// Last state reported by NWConnection for the current attempt (e.g.
    /// "waiting(No route to host)") — surfaced when a connect fails or times
    /// out so the real reason is not lost.
    private var lastConnectionStateDetail: String?
    private var heartbeatSequence: UInt64 = 0
    private var lastReceiverActivityNanoseconds: UInt64?
    private var lastHeartbeatSentNanoseconds: UInt64?
    private var lastHeartbeatAckNanoseconds: UInt64?
    private var lastHeartbeatAckSequence: UInt64 = 0
    private var receiverProcessInstanceID: String?
    private var receiverEventLoopLagMs: UInt64?
    private var receiverAppliedSequence: UInt64?
    private var receiverHeartbeatRTTMs: UInt64?
    private var connectionSessionID: String?
    private var statusState: TBDisplaySenderStatusState = .ready
    private var streamingActivity: NSObjectProtocol?
    private var lastCheckedCursor: NSCursor?
    private var lastCheckedCursorType: Int = 0
    private var baselineDisplayIDs = Set<CGDirectDisplayID>()
    private var cursorDisplayID: CGDirectDisplayID = kCGNullDirectDisplay
    private var lastCursorPacket: TBMonitorCursor?
    private var injectedRemoteMouseLocation: CGPoint?
    private var injectedLeftClickTracker = TBInjectedClickStateTracker()
    private var injectedCommandDown = false
    private var injectedShiftDown = false
    private var injectedOptionDown = false
    private var injectedControlDown = false
    private var injectedCapsDown = false
    // Tracks the actual modifier keys still held on the receiver while a
    // System Events shortcut is running, so released keys are never restored.
    private var remoteHeldModifierKeyCodes = Set<UInt16>()
    /// While a binding trigger key is held (matched), swallow its key-up so the
    /// raw trigger key never reaches the slave.
    private var suppressedTriggerKeyCode: UInt16?
    private static var cachedSupportsHEVCHardwareEncode: Bool?
    private var receivedInputEventCount: UInt64 = 0
    var onRemoteSwitchRequest: ((Int) -> Void)?
    var onRemoteDeactivateInputRequest: (() -> Void)?
    nonisolated(unsafe) private var wakeObservers: [NSObjectProtocol] = []
    private var isRestartingCaptureAfterWake = false
    nonisolated(unsafe) private var displayReconfigurationCallbackRegistered = false
    private var verboseLoggingTimer: Timer?
    private var captureHealthWatchdog: Timer?

    nonisolated(unsafe) private static let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { displayID, flags, userInfo in
        guard let userInfo else { return }
        let service = Unmanaged<TBDisplaySenderSession>.fromOpaque(userInfo).takeUnretainedValue()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                service.handleDisplayReconfiguration(displayID: displayID, flags: flags)
            }
        }
    }

    private final class CaptureDelegate: NSObject, SCStreamOutput, SCStreamDelegate {
        var onFrame: ((CMSampleBuffer) -> Void)?
        var onFrameStatus: ((SCFrameStatus?) -> Void)?
        var onAudio: ((CMSampleBuffer) -> Void)?
        var onError: ((Error) -> Void)?

        private static func frameStatus(_ sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
                  let rawStatus = attachments.first?[SCStreamFrameInfo.status] as? Int,
                  let status = SCFrameStatus(rawValue: rawStatus)
            else {
                return nil
            }
            return status
        }

        private static func shouldProcessFrame(status: SCFrameStatus?) -> Bool {
            switch status {
            case .complete?, .started?, nil:
                return true
            case .idle?, .blank?, .suspended?, .stopped?:
                return false
            @unknown default:
                return true
            }
        }

        nonisolated func stream(_ stream: SCStream,
                                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                                of type: SCStreamOutputType) {
            if type == .audio {
                onAudio?(sampleBuffer)
                return
            }
            guard type == .screen else { return }
            let status = Self.frameStatus(sampleBuffer)
            onFrameStatus?(status)
            guard Self.shouldProcessFrame(status: status) else { return }
            onFrame?(sampleBuffer)
        }

        nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
            onError?(error)
        }
    }

    private func setStatus(_ state: TBDisplaySenderStatusState) {
        let nextText = state.text(language)
        statusState = state
        statusText = nextText
        recordSessionEvent(nextText)
    }

    func clearSessionLog() {
        sessionLogEntries.removeAll(keepingCapacity: true)
    }

    func recordSessionEvent(_ message: String, at date: Date = Date()) {
        let components = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        let timestamp = String(
            format: "%02d:%02d:%02d",
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0
        )
        sessionLogEntries = tbAppendingSessionLogEntry(
            to: sessionLogEntries,
            message: message,
            timestamp: timestamp
        )
    }

    var connectionPathText: String {
        let interface = connectInterfaceName ?? transportKind.rawValue
        return "\(localInterfaceIP) → \(receiverIP):\(TBMonitorProtocol.port) · \(interface)"
    }

    var connectionStartedText: String {
        tbConnectionStartedTimestamp(connectionStartedAt)
    }

    var connectionStartedClockText: String {
        tbConnectionStartedClockTime(connectionStartedAt)
    }

    var generationDiagnosticsText: String {
        "capture=\(captureGeneration) · renderAck=\(bc7RenderConfirmed ? "yes" : "no")"
    }

    private func refreshDisplayModeDiagnostics() {
        guard session.displayID != kCGNullDirectDisplay,
              let mode = CGDisplayCopyDisplayMode(session.displayID)
        else {
            displayModeDiagnosticsText = "Not active"
            return
        }
        let scale = mode.width > 0 ? Double(mode.pixelWidth) / Double(mode.width) : 0
        displayModeDiagnosticsText = String(
            format: "logical %d×%d · pixels %d×%d · %.1fx · %.0f Hz",
            mode.width,
            mode.height,
            mode.pixelWidth,
            mode.pixelHeight,
            scale,
            mode.refreshRate
        )
    }

    private static func probeHEVCHardwareEncoderSupport() -> Bool {
        if let cachedSupportsHEVCHardwareEncode {
            return cachedSupportsHEVCHardwareEncode
        }

        let encoderSpecification: CFDictionary = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true
        ] as CFDictionary

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: 1920,
            height: 1080,
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: encoderSpecification,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        if let session {
            VTCompressionSessionInvalidate(session)
        }

        let supported = status == noErr
        cachedSupportsHEVCHardwareEncode = supported
        return supported
    }

    private func resolvedCodecType(for preset: TBDisplayCapturePreset, profile: TBMonitorDisplayProfile?) -> CMVideoCodecType {
        switch preset {
        case .standard1440p, .smooth1440p60, .smooth1800p60:
            let receiverSupportsHEVC = profile?.supportsHEVCDecode ?? receiverSupportsHEVCDecodeHint ?? false
            if receiverSupportsHEVC, Self.probeHEVCHardwareEncoderSupport() {
                return kCMVideoCodecType_HEVC
            }
            return kCMVideoCodecType_H264
        case .crisp2160p60, .native5k, .native5k60Experimental:
            return preset.codecType
        }
    }

    private func codecName(for codecType: CMVideoCodecType) -> String {
        codecType == kCMVideoCodecType_HEVC ? "HEVC" : "H.264"
    }

    private func refreshConfiguredStreamSummary() {
        streamResolutionText = TBDisplaySenderL10n.streamSummary(
            preset: capturePreset,
            source: captureSource,
            language: language,
            codecName: videoTransportMode.codecName(for: capturePreset)
        )
    }

    private func refreshLocalizedText() {
        statusText = statusState.text(language)
        streamResolutionText = TBDisplaySenderL10n.streamSummary(
            preset: capturePreset,
            source: captureSource,
            language: language,
            codecName: isStreaming ? activeCodecName : videoTransportMode.codecName(for: capturePreset)
        )

        if let profile = activeProfile {
            receiverPanelText = TBDisplaySenderL10n.receiverSummary(profile, language: language)
        } else {
            receiverPanelText = TBDisplaySenderL10n.waitingReceiverProfile(language)
        }

        if session.displayID != kCGNullDirectDisplay, !session.displayName.isEmpty {
            virtualDisplayText = TBDisplaySenderL10n.virtualDisplaySummary(
                name: session.displayName,
                id: session.displayID,
                language: language
            )
        } else {
            virtualDisplayText = TBDisplaySenderL10n.virtualDisplayNotCreated(language)
        }

        if captureDisplayText.isEmpty
            || captureDisplayText == TBDisplaySenderL10n.captureDisplayNotAvailable(.italian)
            || captureDisplayText == TBDisplaySenderL10n.captureDisplayNotAvailable(.english)
            || captureDisplayText == TBDisplaySenderL10n.captureDisplayNotAvailable(.german)
            || captureDisplayText == TBDisplaySenderL10n.captureDisplayNotAvailable(.french)
            || captureDisplayText == TBDisplaySenderL10n.captureDisplayNotAvailable(.chinese) {
            captureDisplayText = TBDisplaySenderL10n.captureDisplayNotAvailable(language)
        }

        if displayStateText.isEmpty
            || displayStateText == TBDisplaySenderL10n.displayStateNotAvailable(.italian)
            || displayStateText == TBDisplaySenderL10n.displayStateNotAvailable(.english)
            || displayStateText == TBDisplaySenderL10n.displayStateNotAvailable(.german)
            || displayStateText == TBDisplaySenderL10n.displayStateNotAvailable(.french)
            || displayStateText == TBDisplaySenderL10n.displayStateNotAvailable(.chinese) {
            displayStateText = TBDisplaySenderL10n.displayStateNotAvailable(language)
        }
    }

    private func formattedCaptureErrorMessage(for error: Error) -> String {
        let nsError = error as NSError
        let details = "\(nsError.localizedDescription) [\(nsError.domain) \(nsError.code)]"
        let permissionGranted = CGPreflightScreenCaptureAccess()
        let lowered = nsError.localizedDescription.lowercased()

        if !permissionGranted {
            return TBDisplaySenderL10n.missingScreenRecordingPermission(language: language)
        }

        if lowered.contains("denied")
            || lowered.contains("not authorized")
            || lowered.contains("permission")
            || lowered.contains("tcc") {
            return TBDisplaySenderL10n.screenCaptureKitPermissionMismatch(details: details, language: language)
        }

        return details
    }

    func connect() {
        guard connection == nil, !receiverIP.isEmpty, !localInterfaceIP.isEmpty else { return }
        connectTimeoutWorkItem?.cancel()
        connectTimeoutWorkItem = nil
        recvBuffer.removeAll(keepingCapacity: false)
        activeProfile = nil
        connectionSessionID = UUID().uuidString
        resetHeartbeatLiveness()
        TBSenderDiagnosticsLogger.shared.append(
            event: "session_start",
            fields: [
                "sessionID": connectionSessionID ?? "",
                "receiverIP": receiverIP,
                "localInterfaceIP": localInterfaceIP,
                "transport": transportKind.rawValue
            ]
        )
        activeCodecType = nil
        activeCodecName = nil
        captureGeneration &+= 1
        actualStreamText = "Not active"
        lastConnectionStateDetail = nil
        setStatus(.connecting(receiverDisplayName))

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.allowLocalEndpointReuse = true
        params.serviceClass = .interactiveVideo
        if let localPort = NWEndpoint.Port(rawValue: 0) {
            params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(localInterfaceIP), port: localPort)
        }

        // Scope link-local dials to the interface that owns the local IP.
        // requiredLocalEndpoint pins the source address but NOT the egress
        // interface — the routing table keeps 169.254/16 on the primary
        // interface (usually Wi-Fi), so an unscoped dial to a Thunderbolt
        // Bridge peer leaves via the wrong link and times out.
        let interfaces = TBConnectionDiagnostics.currentIPv4Interfaces()
        connectInterfaceName = TBConnectionDiagnostics.interfaceName(forLocalIP: localInterfaceIP, in: interfaces)
        let scopedHost = TBConnectionDiagnostics.scopedReceiverHost(
            receiverIP: receiverIP,
            localIP: localInterfaceIP,
            interfaces: interfaces
        )
        let dialHost: NWEndpoint.Host
        if scopedHost != receiverIP, let scopedAddress = IPv4Address(scopedHost) {
            dialHost = .ipv4(scopedAddress)
        } else {
            dialHost = NWEndpoint.Host(receiverIP)
        }
        TBLog.connection.info("connect: dialing \(scopedHost, privacy: .public):\(TBMonitorProtocol.port) from \(self.localInterfaceIP, privacy: .public) (\(self.connectInterfaceName ?? "unknown interface", privacy: .public)) transport=\(self.transportKind.rawValue, privacy: .public)")
        let conn = NWConnection(
            host: dialHost,
            port: NWEndpoint.Port(integerLiteral: TBMonitorProtocol.port),
            using: params
        )
        connection = conn

        conn.stateUpdateHandler = { [weak self, weak conn] state in
            Task { @MainActor [weak self, weak conn] in
                guard let self, let conn, self.connection === conn else { return }
                switch state {
                case .ready:
                    self.connectTimeoutWorkItem?.cancel()
                    self.connectTimeoutWorkItem = nil
                    self.isConnected = true
                    self.connectionStartedAt = Date()
                    TBSenderDiagnosticsLogger.shared.append(
                        event: "connection_state",
                        fields: [
                            "sessionID": self.connectionSessionID ?? "",
                            "state": "ready",
                            "receiverIP": self.receiverIP,
                            "localInterfaceIP": self.localInterfaceIP,
                            "interface": self.connectInterfaceName ?? ""
                        ]
                    )
                    self.lastReceiverActivityNanoseconds =
                        DispatchTime.now().uptimeNanoseconds
                    TBLog.connection.info("connect: ready — \(self.receiverIP, privacy: .public) via \(self.connectInterfaceName ?? "?", privacy: .public)")
                    self.recordSessionEvent("Connected: \(self.connectionPathText)")
                    self.setStatus(.waitingDisplayProfile)
                    self.startHeartbeat()
                    self.sendAutomaticReceiverStateUpdates()
                    self.receiveLoop(on: conn)
                case .waiting(let error):
                    // The dial cannot proceed yet (no route, host down, cable
                    // unplugged, firewall drop, …). Record and log the real
                    // reason so a later timeout can report it instead of a
                    // bare "Connection timed out".
                    self.lastConnectionStateDetail = "waiting(\(error.localizedDescription))"
                    TBSenderDiagnosticsLogger.shared.append(
                        event: "connection_state",
                        fields: [
                            "sessionID": self.connectionSessionID ?? "",
                            "state": "waiting",
                            "error": error.localizedDescription
                        ]
                    )
                    TBLog.connection.warning("connect: waiting — \(error.localizedDescription, privacy: .public)")
                    if tbShouldReleaseSessionOnNetworkWait(
                        isConnected: self.isConnected,
                        transportKind: self.transportKind
                    ) {
                        let message =
                            "Thunderbolt disconnected: \(error.localizedDescription)"
                        self.recordSessionEvent(message)
                        self.stop(
                            resetStatusTo: .connectionFailed(message),
                            persistArrangement: false,
                            closeContext: .transport(
                                "network_wait",
                                detail: message
                            )
                        )
                    }
                case .failed(let error):
                    self.lastConnectionStateDetail = "failed(\(error.localizedDescription))"
                    TBSenderDiagnosticsLogger.shared.append(
                        event: "connection_state",
                        fields: [
                            "sessionID": self.connectionSessionID ?? "",
                            "state": "failed",
                            "error": error.localizedDescription
                        ]
                    )
                    let detail = TBConnectionDiagnostics.failureDetail(
                        receiverHost: self.receiverIP,
                        port: TBMonitorProtocol.port,
                        localIP: self.localInterfaceIP,
                        interfaceName: self.connectInterfaceName,
                        transport: self.transportKind.rawValue,
                        lastNetworkState: nil
                    )
                    TBLog.connection.error("connect: failed — \(error.localizedDescription, privacy: .public); \(detail, privacy: .public)")
                    self.setStatus(.connectionFailed("\(error.localizedDescription) — \(detail)"))
                    self.stop(
                        resetStatusTo: nil,
                        closeContext: .transport(
                            "connect_failed",
                            detail: error.localizedDescription
                        )
                    )
                case .cancelled:
                    self.isConnected = false
                default:
                    break
                }
            }
        }

        startConnectWatchdog()
        conn.start(queue: connectionQueue)
    }

    func startCableTest() {
        guard !isCableTesting, !isConnected, !receiverIP.isEmpty else { return }
        isCableTesting = true
        cableTestResult = nil
        isCableTestConnection = true
        connect()
    }

    func startBC7Test() {
        guard !isConnected, !isStreaming, !receiverIP.isEmpty, !localInterfaceIP.isEmpty else { return }
        guard TBBC7Mode6Encoder() != nil else {
            bc7TestStatusText = "Sender Metal BC7 encoder is unavailable."
            return
        }
        if receiverSupportsBC7Mode6Hint == false {
            bc7TestStatusText = "Selected Receiver does not advertise BC7 support."
            return
        }

        videoTransportMode = .bc7Mode6
        if capturePreset == .native5k || capturePreset == .native5k60Experimental {
            captureSource = .extendedDesktop
            matchRenderToStream = true
        }
        bc7TestStatusText = receiverSupportsBC7Mode6Hint == true
            ? "Starting \(capturePreset.description) BC7 end-to-end test."
            : "Connecting to verify Receiver BC7 capability."
        connect()
    }

    private func performCableTest() async throws -> Double {
        guard let conn = connection else {
            throw NSError(domain: "TBDisplaySenderService", code: -1, userInfo: [NSLocalizedDescriptionKey: "No connection"])
        }

        let totalBytes: Int64 = 20 * 1000 * 1000 * 1000
        let chunkSize = 4 * 1000 * 1000
        let totalChunks = Int(totalBytes / Int64(chunkSize))

        // Pre-allocate the single test packet to avoid memory overhead
        var packet = Data()
        TBMonitorProtocol.appendBE32(&packet, UInt32(1 + chunkSize))
        packet.append(TBMonitorPacketType.testData.rawValue)
        packet.append(Data(repeating: 0, count: chunkSize))

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let startTime = DispatchTime.now()
                let condition = NSCondition()

                let lock = NSLock()
                var sendError: Error?
                var resumed = false
                var inFlightCount = 0

                func finish(with error: Error?) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !resumed else { return }
                    resumed = true
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        let endTime = DispatchTime.now()
                        let nanoTime = endTime.uptimeNanoseconds - startTime.uptimeNanoseconds
                        let timeInSeconds = Double(nanoTime) / 1_000_000_000.0

                        // 20 GB = 20,000,000,000 bytes = 160,000,000,000 bits
                        // Decimal Gigabits = bits / 1,000,000,000
                        let totalBits = Double(totalBytes) * 8.0
                        let rate = totalBits / 1_000_000_000.0 / timeInSeconds
                        continuation.resume(returning: rate)
                    }
                }

                for _ in 0..<totalChunks {
                    lock.lock()
                    let err = sendError
                    lock.unlock()
                    if err != nil {
                        break
                    }

                    condition.lock()
                    while inFlightCount >= 8 {
                        lock.lock()
                        let errCheck = sendError
                        lock.unlock()
                        if errCheck != nil {
                            break
                        }
                        condition.wait()
                    }

                    lock.lock()
                    let errCheck2 = sendError
                    lock.unlock()
                    if errCheck2 != nil {
                        condition.unlock()
                        break
                    }

                    inFlightCount += 1
                    condition.unlock()

                    conn.send(content: packet, completion: .contentProcessed({ error in
                        if let error = error {
                            lock.lock()
                            if sendError == nil {
                                sendError = error
                            }
                            lock.unlock()
                        }

                        condition.lock()
                        inFlightCount -= 1
                        condition.broadcast()
                        condition.unlock()
                    }))
                }

                // Wait for all outstanding packets to complete (up to 3 seconds)
                let limitDate = Date().addingTimeInterval(3.0)
                condition.lock()
                while inFlightCount > 0 {
                    if !condition.wait(until: limitDate) {
                        break // Timed out
                    }
                }
                condition.unlock()

                lock.lock()
                let err = sendError
                lock.unlock()

                finish(with: err)
            }
        }
    }

    func stop(
        persistArrangement: Bool = true,
        closeContext: TBSessionCloseContext = .userStop
    ) {
        stop(
            resetStatusTo: .stopped,
            persistArrangement: persistArrangement,
            closeContext: closeContext
        )
    }

    func persistExtendedDisplayArrangementSnapshot() {
        persistExtendedDisplayArrangementIfNeeded()
    }

    private func stop(
        resetStatusTo status: TBDisplaySenderStatusState?,
        persistArrangement: Bool = true,
        closeContext: TBSessionCloseContext = .userStop
    ) {
        if persistArrangement {
            persistExtendedDisplayArrangementIfNeeded()
        }
        let closingSessionID = connectionSessionID
        let closingConnection = connection
        let sentFrames = UInt64(max(0, pipeline?.sentFramesSnapshot ?? 0))
        let sentBytes = UInt64(max(0, pipeline?.sentBytesSnapshot ?? 0))
        let hadActiveSession =
            closingConnection != nil ||
            isConnected ||
            isStreaming ||
            closingSessionID != nil
        if hadActiveSession {
            TBSenderDiagnosticsLogger.shared.append(
                event: "session_close",
                fields: [
                    "sessionID": closingSessionID ?? "",
                    "reason": closeContext.reason,
                    "category": closeContext.category,
                    "detail": closeContext.detail ?? "",
                    "notifyPeer": closeContext.notifyPeer,
                    "frames": sentFrames,
                    "bytes": sentBytes,
                    "receiverIP": receiverIP,
                    "connected": isConnected
                ]
            )
        }
        if let closingConnection {
            closingConnection.stateUpdateHandler = nil
            if closeContext.notifyPeer {
                sendTeardown(
                    on: closingConnection,
                    context: closeContext,
                    sessionID: closingSessionID,
                    frames: sentFrames,
                    bytes: sentBytes
                )
            } else {
                closingConnection.cancel()
            }
        }
        connectTimeoutWorkItem?.cancel()
        connectTimeoutWorkItem = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        heartbeatLivenessTimer?.invalidate()
        heartbeatLivenessTimer = nil
        resetHeartbeatLiveness()
        firstFrameTimer?.invalidate()
        firstFrameTimer = nil
        cursorTimer?.invalidate()
        cursorTimer = nil
        fpsTimer?.invalidate()
        fpsTimer = nil
        stopCaptureWatchdog()
        if let directDisplayStream {
            directDisplayStream.stop()
            self.directDisplayStream = nil
        }
        if let stream = scStream {
            if let delegate = captureDelegate {
                try? stream.removeStreamOutput(delegate, type: .screen)
                try? stream.removeStreamOutput(delegate, type: .audio)
            }
            stream.stopCapture(completionHandler: nil)
            scStream = nil
        }
        captureDelegate = nil
        if let activity = streamingActivity {
            ProcessInfo.processInfo.endActivity(activity)
            streamingActivity = nil
        }
        pipeline?.stop()
        pipeline = nil
        releaseInjectedModifiersIfNeeded()
        remoteHeldModifierKeyCodes.removeAll()
        injectedLeftClickTracker.reset()
        suppressedTriggerKeyCode = nil
        connection = nil
        let currentSession = session
        Task { @MainActor in
            currentSession.destroy()
        }
        activeProfile = nil
        activeCodecType = nil
        activeCodecName = nil
        actualStreamText = "Not active"
        displayModeDiagnosticsText = "Not active"
        isConnected = false
        isStreaming = false
        isCableTesting = false
        isCableTestConnection = false
        if let status {
            setStatus(status)
        }
        refreshLocalizedText()
        liveMetrics.senderFPS = 0
        liveMetrics.senderNetworkGbps = 0
        liveMetrics.receiverFPS = 0
        sentSnapshot = 0
        sentBytesSnapshot = 0
        capturedSnapshot = 0
        bc7ProcessedSnapshot = 0
        bc7EncodeNanosecondsSnapshot = 0
        bc7PlanNanosecondsSnapshot = 0
        bc7PacketNanosecondsSnapshot = 0
        bc7GPUAnalyzedSnapshot = 0
        bc7SendCompletedSnapshot = 0
        bc7SendNanosecondsSnapshot = 0
        transportDiagnosticsText = "pending=0 · in-flight=0 · dropped=0 · 0.00 Gbit/s"
        receiverMetricsText = "Not available"
        lastReceiverMetrics = nil
        sessionAckSent = false
        pipelineHasFirstFrame = false
        bc7RenderConfirmed = false
        baselineDisplayIDs = []
        cursorDisplayID = kCGNullDirectDisplay
        lastCursorPacket = nil
        connectionSessionID = nil
        captureDisplayText = TBDisplaySenderL10n.captureDisplayNotAvailable(language)
        displayStateText = TBDisplaySenderL10n.displayStateNotAvailable(language)
    }

    /// Stable per-receiver discriminator: the connection address when known
    /// (distinct per machine even when two identical iMacs report the same SDL
    /// display name), falling back to the receiver-reported name.
    private func receiverIdentityDiscriminator(for profile: TBMonitorDisplayProfile) -> String {
        let trimmedIP = receiverIP.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedIP.isEmpty ? profile.receiverName : trimmedIP
    }

    /// Key used to derive the extended-desktop virtual display identity. Shares
    /// the same receiver discriminator as the saved-arrangement key so a given
    /// receiver maps to one stable virtual display identity across reconnects.
    private func extendedDisplayIdentityKey(for profile: TBMonitorDisplayProfile) -> String {
        "\(receiverIdentityDiscriminator(for: profile))|\(profile.panelWidth)x\(profile.panelHeight)"
    }

    private func extendedArrangementDefaultsKey(for profile: TBMonitorDisplayProfile) -> String {
        let normalizedIdentity = receiverIdentityDiscriminator(for: profile).replacingOccurrences(
            of: #"[^A-Za-z0-9._-]+"#,
            with: "-",
            options: .regularExpression
        )
        return "\(Self.extendedArrangementDefaultsPrefix).\(normalizedIdentity).\(profile.panelWidth)x\(profile.panelHeight)"
    }

    private func loadSavedExtendedDisplayArrangement(for profile: TBMonitorDisplayProfile) -> SavedExtendedDisplayArrangement? {
        let key = extendedArrangementDefaultsKey(for: profile)
        guard let stored = UserDefaults.standard.dictionary(forKey: key) else {
            return nil
        }

        if let dx = stored["dx"] as? Int,
           let dy = stored["dy"] as? Int {
            return SavedExtendedDisplayArrangement(
                x: Int32(dx),
                y: Int32(dy),
                isRelativeToMainDisplay: true
            )
        }

        guard let x = stored["x"] as? Int,
              let y = stored["y"] as? Int
        else {
            return nil
        }
        return SavedExtendedDisplayArrangement(
            x: Int32(x),
            y: Int32(y),
            isRelativeToMainDisplay: false
        )
    }

    private func persistExtendedDisplayArrangementIfNeeded() {
        guard captureSource == .extendedDesktop,
              let profile = activeProfile,
              session.displayID != kCGNullDirectDisplay,
              CGDisplayIsInMirrorSet(session.displayID) == 0
        else { return }

        let bounds = CGDisplayBounds(session.displayID)
        let mainBounds = CGDisplayBounds(CGMainDisplayID())
        let key = extendedArrangementDefaultsKey(for: profile)
        let payload: [String: Int] = [
            "dx": Int((bounds.origin.x - mainBounds.origin.x).rounded()),
            "dy": Int((bounds.origin.y - mainBounds.origin.y).rounded()),
            "x": Int(bounds.origin.x.rounded()),
            "y": Int(bounds.origin.y.rounded())
        ]
        UserDefaults.standard.set(payload, forKey: key)
    }

    private func sendHello() {
        let name = Host.current().localizedName ?? "MacBook"
        let preset = capturePreset
        let helloCodecType = resolvedCodecType(for: preset, profile: activeProfile)
        let helloCodecName: String
        if let profile = activeProfile, bc7Mode6Enabled(for: profile) {
            helloCodecName = "BC7 Mode 6"
        } else if let profile = activeProfile, rawNV12Enabled(for: profile) {
            helloCodecName = "NV12 RAW"
        } else {
            helloCodecName = codecName(for: helloCodecType)
        }
        guard let packet = TBMonitorProtocol.makeJSONPacket(
            type: .helloReceiver,
            value: TBMonitorHelloReceiver(
                senderName: name,
                uiLanguage: language.fileStem,
                capturePreset: preset.title,
                captureSource: captureSource.title(language),
                captureWidth: preset.width,
                captureHeight: preset.height,
                codec: helloCodecName,
                senderProcessInstanceID:
                    TBSenderDiagnosticsLogger.shared.processInstanceID,
                sessionID: connectionSessionID
            )
        ) else { return }
        send(packet)
    }

    private func sendInputControlModeUpdate() {
        guard let packet = TBMonitorProtocol.makeJSONPacket(
            type: .inputControlMode,
            value: TBMonitorInputControlMode(mode: inputControlRole.rawValue)
        ) else { return }
        TBInputDebugLog.log("sender send control mode update \(inputControlRole.rawValue) to \(receiverIP)")
        send(packet)
    }

    private func sendBrightnessUpdate() {
        guard let packet = TBMonitorProtocol.makeJSONPacket(
            type: .brightness,
            value: TBMonitorBrightness(level: brightness)
        ) else { return }
        send(packet)
    }

    private func sendVolumeUpdate() {
        guard let packet = TBMonitorProtocol.makeJSONPacket(
            type: .volume,
            value: TBMonitorVolume(level: volume)
        ) else { return }
        send(packet)
    }

    private func sendAutomaticReceiverStateUpdates() {
        for update in TBReceiverStateUpdate.automaticOnConnect {
            switch update {
            case .hello:
                sendHello()
            case .inputControlMode:
                sendInputControlModeUpdate()
            case .brightness:
                sendBrightnessUpdate()
            case .volume:
                sendVolumeUpdate()
            }
        }
    }

    func sendClipboardText(_ text: String) {
        guard let packet = TBMonitorProtocol.makeJSONPacket(
            type: .clipboard,
            value: TBMonitorClipboard(text: text)
        ) else { return }
        send(packet)
    }

    private func sendHeartbeat() {
        guard let connection, isConnected else { return }
        let nowNanoseconds = DispatchTime.now().uptimeNanoseconds
        let evaluation = tbHeartbeatLivenessEvaluation(
            supportsHeartbeatAck: activeProfile?.supportsHeartbeatAck == true,
            isConnected: isConnected,
            nowNanoseconds: nowNanoseconds,
            lastReceiverActivityNanoseconds: lastReceiverActivityNanoseconds,
            lastHeartbeatSentSequence: heartbeatSequence,
            lastHeartbeatAcknowledgedSequence: lastHeartbeatAckSequence
        )

        heartbeatSequence &+= 1
        lastHeartbeatSentNanoseconds = nowNanoseconds
        let senderTimestampMs = nowNanoseconds / 1_000_000
        guard let packet = TBMonitorProtocol.makeJSONPacket(
            type: .heartbeat,
            value: TBMonitorHeartbeat(
                sequence: heartbeatSequence,
                senderTimestampMs: senderTimestampMs
            )
        ) else { return }
        let sentSequence = heartbeatSequence
        TBLog.connection.debug(
            "heartbeat sent sequence=\(sentSequence, privacy: .public) missed=\(evaluation.missedAcknowledgments, privacy: .public)"
        )
        connection.send(
            content: packet,
            completion: .contentProcessed({ [weak self, weak connection] error in
                Task { @MainActor [weak self, weak connection] in
                    guard let self, let connection else { return }
                    let isCurrentConnection = self.connection === connection
                    guard tbShouldStopAfterHeartbeatSend(
                        hasError: error != nil,
                        isCurrentConnection: isCurrentConnection,
                        isConnected: self.isConnected
                    ), let error
                    else { return }
                    let message =
                        "Receiver heartbeat send failed: " +
                        error.localizedDescription
                    TBLog.connection.error("\(message, privacy: .public)")
                    self.recordSessionEvent(message)
                    self.setStatus(.connectionClosed(message))
                    self.stop(
                        resetStatusTo: nil,
                        closeContext: .liveness(
                            "heartbeat_send_error",
                            detail: message,
                            notifyPeer: false
                        )
                    )
                }
            })
        )
    }

    private func sendTeardown(
        on connection: NWConnection,
        context: TBSessionCloseContext,
        sessionID: String?,
        frames: UInt64,
        bytes: UInt64
    ) {
        guard let packet = TBMonitorProtocol.makeJSONPacket(
            type: .teardown,
            value: TBMonitorTeardown(
                reason: context.reason,
                origin: "sender",
                category: context.category,
                detail: context.detail,
                errno: 0,
                timestampMs:
                    DispatchTime.now().uptimeNanoseconds / 1_000_000,
                processInstanceID:
                    TBSenderDiagnosticsLogger.shared.processInstanceID,
                sessionID: sessionID,
                frames: frames,
                packets: heartbeatSequence,
                bytes: bytes
            )
        ) else {
            TBSenderDiagnosticsLogger.shared.append(
                event: "peer_signal_send_error",
                fields: [
                    "sessionID": sessionID ?? "",
                    "reason": context.reason,
                    "category": context.category,
                    "error": "unable to encode teardown payload"
                ]
            )
            connection.cancel()
            return
        }
        connection.send(
            content: packet,
            completion: .contentProcessed({ error in
                TBSenderDiagnosticsLogger.shared.append(
                    event: error == nil
                        ? "peer_signal_sent"
                        : "peer_signal_send_error",
                    fields: [
                        "sessionID": sessionID ?? "",
                        "reason": context.reason,
                        "category": context.category,
                        "error": error?.localizedDescription ?? ""
                    ]
                )
                connection.cancel()
            })
        )
        connectionQueue.asyncAfter(deadline: .now() + 0.25) {
            connection.cancel()
        }
    }

    private func receiveLoop(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isDone, error in
            Task { @MainActor [weak self] in
                guard let self, self.connection === connection else { return }
                if let data, !data.isEmpty {
                    self.recvBuffer.append(data)
                    self.drainPackets()
                    guard self.connection === connection else { return }
                }
                if error != nil || isDone {
                    if let error {
                        self.setStatus(.connectionClosed(error.localizedDescription))
                    } else if case .startingCapture = self.statusState {
                        self.setStatus(.receiverClosedDuringCapture)
                    } else if case .captureActive = self.statusState {
                        self.setStatus(.receiverClosedConnection)
                    }
                    self.stop(
                        resetStatusTo: nil,
                        closeContext: .transport(
                            error == nil ? "peer_closed" : "receive_error",
                            detail: error?.localizedDescription ??
                                "Receiver closed connection"
                        )
                    )
                    return
                }
                self.receiveLoop(on: connection)
            }
        }
    }

    private func drainPackets() {
        do {
            try drainPacketsOrThrow()
        } catch {
            // Corrupt length prefix: the framing is unrecoverable, so tear the
            // connection down instead of buffering inbound data forever.
            TBLog.connection.error("corrupt inbound stream (\(String(describing: error), privacy: .public)); closing connection")
            recvBuffer.removeAll(keepingCapacity: false)
            setStatus(.connectionClosed(String(describing: error)))
            stop(
                resetStatusTo: nil,
                closeContext: .appError(
                    "protocol_error",
                    detail: String(describing: error)
                )
            )
        }
    }

    private func drainPacketsOrThrow() throws {
        while let (type, payload) = try TBMonitorProtocol.drainPacket(from: &recvBuffer) {
            noteReceiverActivity()
            switch type {
            case .displayProfile:
                handleDisplayProfile(payload)
            case .receiverMetrics:
                handleReceiverMetrics(payload)
            case .bc7RenderAck:
                guard !bc7RenderConfirmed, payload.count == 12 else { break }
                let generation = TBMonitorProtocol.readBE32(payload, offset: 0)
                guard generation == bc7RenderGeneration else { break }
                let width = TBMonitorProtocol.readBE32(payload, offset: 4)
                let height = TBMonitorProtocol.readBE32(payload, offset: 8)
                bc7RenderConfirmed = true
                bc7TestStatusText = "BC7 end-to-end test passed: Receiver rendered \(width)×\(height)."
            case .bc7KeyframeRequest:
                guard payload.count == 4 else { break }
                let generation = TBMonitorProtocol.readBE32(payload, offset: 0)
                guard generation == bc7RenderGeneration else { break }
                pipeline?.requestBC7Keyframe()
            case .rawNV12KeyframeRequest:
                guard payload.isEmpty else { break }
                pipeline?.requestRawNV12Keyframe()
            case .inputEvent:
                if inputControlRole == .receiverMaster,
                   let event = TBMonitorProtocol.decodeJSON(TBMonitorInputEvent.self, from: payload) {
                    receivedInputEventCount += 1
                    if receivedInputEventCount <= 20 || receivedInputEventCount.isMultiple(of: 100) {
                        TBInputDebugLog.log("sender received #\(receivedInputEventCount) kind=\(event.kind) dx=\(event.dx ?? 0) dy=\(event.dy ?? 0) sx=\(event.scrollX ?? 0) sy=\(event.scrollY ?? 0) key=\(event.keyCode ?? 0)")
                    }
                    if event.kind == "switchPrevTarget" {
                        releaseInjectedModifiersIfNeeded()
                        onRemoteSwitchRequest?(-1)
                    } else if event.kind == "switchNextTarget" {
                        releaseInjectedModifiersIfNeeded()
                        onRemoteSwitchRequest?(1)
                    } else if event.kind == "switchPrevSpace" {
                        releaseInjectedModifiersIfNeeded()
                        postLocalSpaceSwitch(direction: -1)
                    } else if event.kind == "switchNextSpace" {
                        releaseInjectedModifiersIfNeeded()
                        postLocalSpaceSwitch(direction: 1)
                    } else if event.kind == "deactivateInputControl" {
                        releaseInjectedModifiersIfNeeded()
                        onRemoteDeactivateInputRequest?()
                    } else {
                        applyIncomingInputEvent(event)
                    }
                }
            case .heartbeat:
                handleHeartbeatAcknowledgment(payload)
            case .teardown:
                let teardown = TBMonitorProtocol.decodeJSON(
                    TBMonitorTeardown.self,
                    from: payload
                )
                TBSenderDiagnosticsLogger.shared.append(
                    event: "peer_close_signal",
                    fields: [
                        "sessionID":
                            teardown?.sessionID ?? connectionSessionID ?? "",
                        "reason": teardown?.reason ?? "unknown",
                        "origin": teardown?.origin ?? "receiver",
                        "category": teardown?.category ?? "unknown",
                        "detail": teardown?.detail ?? "",
                        "errno": teardown?.errno ?? 0,
                        "peerProcessInstanceID":
                            teardown?.processInstanceID ?? "",
                        "frames": teardown?.frames ?? 0,
                        "packets": teardown?.packets ?? 0,
                        "bytes": teardown?.bytes ?? 0
                    ]
                )
                setStatus(.receiverTerminatedSession)
                stop(
                    resetStatusTo: nil,
                    closeContext: .transport(
                        "receiver_\(teardown?.reason ?? "teardown")",
                        detail: teardown?.detail ??
                            "Receiver sent teardown",
                        notifyPeer: false
                    )
                )
                return
            case .clipboard:
                if let clipboard = TBMonitorProtocol.decodeJSON(TBMonitorClipboard.self, from: payload) {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(clipboard.text, forType: .string)
                }
            default:
                break
            }
        }
    }

    private func currentLocalMouseLocation() -> CGPoint? {
        CGEvent(source: nil)?.location
    }

    // Bounds of every active display, in the Quartz global coordinate space
    // (top-left origin) — matching CGEvent locations and CGWarpMouseCursorPosition.
    // NSScreen.frame uses AppKit's bottom-left origin and must not be mixed in here.
    private func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    private func screenFrame(containing point: CGPoint) -> CGRect? {
        activeDisplayBounds().first(where: { $0.contains(point) })
    }

    private func clampedMouseTarget(from current: CGPoint, dx: Int, dy: Int) -> CGPoint {
        let rawTarget = CGPoint(x: current.x + CGFloat(dx), y: current.y + CGFloat(dy))
        let displays = activeDisplayBounds()
        guard !displays.isEmpty else { return rawTarget }

        // If the target lands on any display, allow it unchanged. This lets the
        // relayed cursor cross from one screen onto an adjacent one (e.g. the
        // receiver-backed virtual extended display), matching how the pointer
        // behaves with the local touchpad. Clamping to a single screen's bounds
        // previously trapped the pointer on the sender's main display (issue #97).
        if displays.contains(where: { $0.contains(rawTarget) }) {
            return rawTarget
        }

        // Off every display: keep the pointer on the display it is currently on so
        // the injected cursor can never get lost in a gap between displays.
        let frame = displays.first(where: { $0.contains(current) }) ?? displays[0]
        let minX = frame.minX
        let maxX = frame.maxX - 1
        let minY = frame.minY
        let maxY = frame.maxY - 1

        return CGPoint(
            x: min(max(rawTarget.x, minX), maxX),
            y: min(max(rawTarget.y, minY), maxY)
        )
    }

    private func localInputEventSource() -> CGEventSource? {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
        return source
    }

    private func logLocalInputInjectionStateIfNeeded(context: String) {
        let trusted = AXIsProcessTrusted()
        TBInputDebugLog.log("sender input injection state trusted=\(trusted) context=\(context)")
    }

    private func postLocalMouseMove(dx: Int, dy: Int, type: CGEventType = .mouseMoved, button: CGMouseButton = .left) {
        logLocalInputInjectionStateIfNeeded(context: "mouseMove")
        guard let current = injectedRemoteMouseLocation ?? currentLocalMouseLocation() else { return }
        let target = clampedMouseTarget(from: current, dx: dx, dy: dy)
        injectedRemoteMouseLocation = target
        let shouldWarp = (type == .mouseMoved)
        if shouldWarp {
            CGWarpMouseCursorPosition(target)
        }
        guard let event = CGEvent(mouseEventSource: localInputEventSource(), mouseType: type, mouseCursorPosition: target, mouseButton: button) else { return }
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
        event.post(tap: .cghidEventTap)

        // Auto-hidden menu bar / Dock reveal on macOS depends on the pointer
        // really landing on a screen edge. A second edge-pinned move helps the
        // system treat relayed motion like a native "push against the border".
        if type == .mouseMoved,
           let frame = screenFrame(containing: target),
           target.x <= frame.minX || target.x >= frame.maxX - 1 ||
           target.y <= frame.minY || target.y >= frame.maxY - 1,
           let edgeEvent = CGEvent(mouseEventSource: localInputEventSource(), mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: button) {
            edgeEvent.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
            edgeEvent.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
            edgeEvent.post(tap: .cghidEventTap)
        }
    }

    private func postLocalMouseButton(type: CGEventType, button: CGMouseButton) {
        logLocalInputInjectionStateIfNeeded(context: "mouseButton")
        guard let current = injectedRemoteMouseLocation ?? currentLocalMouseLocation() else { return }
        guard let event = CGEvent(mouseEventSource: localInputEventSource(), mouseType: type, mouseCursorPosition: current, mouseButton: button) else { return }
        if button == .left {
            let clickState: Int
            if type == .leftMouseDown {
                clickState = injectedLeftClickTracker.registerClick(
                    at: current,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    doubleClickInterval: NSEvent.doubleClickInterval
                )
            } else {
                clickState = max(injectedLeftClickTracker.currentClickState, 1)
            }
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        }
        event.post(tap: .cghidEventTap)
    }

    private func postLocalScroll(scrollX: Int, scrollY: Int) {
        logLocalInputInjectionStateIfNeeded(context: "scroll")
        guard let event = CGEvent(
            scrollWheelEvent2Source: localInputEventSource(),
            units: .line,
            wheelCount: 2,
            wheel1: Int32(scrollY),
            wheel2: Int32(scrollX),
            wheel3: 0
        ) else { return }
        event.post(tap: .cghidEventTap)
    }

    private func postLocalKey(keyCode: UInt16, isDown: Bool) {
        logLocalInputInjectionStateIfNeeded(context: "key")
        switch keyCode {
        case 54, 55: injectedCommandDown = isDown
        case 56, 60: injectedShiftDown = isDown
        case 58, 61: injectedOptionDown = isDown
        case 59, 62: injectedControlDown = isDown
        case 57: injectedCapsDown = isDown
        default: break
        }
        guard let event = CGEvent(keyboardEventSource: localInputEventSource(), virtualKey: CGKeyCode(keyCode), keyDown: isDown) else { return }
        event.flags = currentInjectedModifierFlags()
        event.post(tap: .cghidEventTap)
    }

    private func currentInjectedModifierFlags() -> CGEventFlags {
        var flags: CGEventFlags = []
        if injectedCommandDown {
            flags.insert(.maskCommand)
        }
        if injectedShiftDown {
            flags.insert(.maskShift)
        }
        if injectedOptionDown {
            flags.insert(.maskAlternate)
        }
        if injectedControlDown {
            flags.insert(.maskControl)
        }
        if injectedCapsDown {
            flags.insert(.maskAlphaShift)
        }
        return flags
    }

    private func releaseInjectedModifiersIfNeeded() {
        if injectedCommandDown {
            postLocalKey(keyCode: 55, isDown: false)
            injectedCommandDown = false
        }
        if injectedShiftDown {
            postLocalKey(keyCode: 56, isDown: false)
            injectedShiftDown = false
        }
        if injectedOptionDown {
            postLocalKey(keyCode: 58, isDown: false)
            injectedOptionDown = false
        }
        if injectedControlDown {
            postLocalKey(keyCode: 59, isDown: false)
            injectedControlDown = false
        }
        if injectedCapsDown {
            postLocalKey(keyCode: 57, isDown: false)
            injectedCapsDown = false
        }
    }

    private func postLocalSpaceSwitch(direction: Int) {
        logLocalInputInjectionStateIfNeeded(context: "spaceSwitch")

        let controlKeyCode: UInt16 = 59
        let arrowKeyCode: UInt16 = direction < 0 ? 123 : 124

        guard let controlDown = CGEvent(keyboardEventSource: localInputEventSource(), virtualKey: CGKeyCode(controlKeyCode), keyDown: true),
              let arrowDown = CGEvent(keyboardEventSource: localInputEventSource(), virtualKey: CGKeyCode(arrowKeyCode), keyDown: true),
              let arrowUp = CGEvent(keyboardEventSource: localInputEventSource(), virtualKey: CGKeyCode(arrowKeyCode), keyDown: false),
              let controlUp = CGEvent(keyboardEventSource: localInputEventSource(), virtualKey: CGKeyCode(controlKeyCode), keyDown: false)
        else {
            return
        }

        controlDown.flags = .maskControl
        arrowDown.flags = .maskControl
        arrowUp.flags = .maskControl
        controlUp.flags = []

        controlDown.post(tap: .cghidEventTap)
        arrowDown.post(tap: .cghidEventTap)
        arrowUp.post(tap: .cghidEventTap)
        controlUp.post(tap: .cghidEventTap)
    }

    private func applyIncomingInputEvent(_ event: TBMonitorInputEvent) {
        TBInputDebugLog.log("sender applying incoming event kind=\(event.kind)")
        switch event.kind {
        case "move":
            postLocalMouseMove(dx: event.dx ?? 0, dy: event.dy ?? 0)
        case "leftDrag":
            postLocalMouseMove(dx: event.dx ?? 0, dy: event.dy ?? 0, type: .leftMouseDragged, button: .left)
        case "rightDrag":
            postLocalMouseMove(dx: event.dx ?? 0, dy: event.dy ?? 0, type: .rightMouseDragged, button: .right)
        case "otherDrag":
            postLocalMouseMove(dx: event.dx ?? 0, dy: event.dy ?? 0, type: .otherMouseDragged, button: .center)
        case "leftDown":
            postLocalMouseButton(type: .leftMouseDown, button: .left)
        case "leftUp":
            postLocalMouseButton(type: .leftMouseUp, button: .left)
        case "rightDown":
            postLocalMouseButton(type: .rightMouseDown, button: .right)
        case "rightUp":
            postLocalMouseButton(type: .rightMouseUp, button: .right)
        case "otherDown":
            postLocalMouseButton(type: .otherMouseDown, button: .center)
        case "otherUp":
            postLocalMouseButton(type: .otherMouseUp, button: .center)
        case "scroll":
            postLocalScroll(scrollX: event.scrollX ?? 0, scrollY: event.scrollY ?? 0)
        case "keyDown":
            if let keyCode = event.keyCode {
                updateRemoteModifierState(keyCode: keyCode, isDown: true)
                if handleIncomingTriggerKeyDown(keyCode) { return }
                postLocalKey(keyCode: keyCode, isDown: true)
            }
        case "keyUp":
            if let keyCode = event.keyCode {
                updateRemoteModifierState(keyCode: keyCode, isDown: false)
                if keyCode == suppressedTriggerKeyCode {
                    suppressedTriggerKeyCode = nil
                    return
                }
                postLocalKey(keyCode: keyCode, isDown: false)
            }
        default:
            break
        }
    }

    /// receiverMaster: if the incoming key-down completes a binding trigger,
    /// inject the action locally and swallow the trigger. Returns true if handled.
    private func handleIncomingTriggerKeyDown(_ keyCode: UInt16) -> Bool {
        guard !TBInputBindingEngine.isModifierKeyCode(keyCode), !inputBindings.isEmpty else { return false }
        // Debounce key-repeat: ignore repeats while the trigger is still held.
        if keyCode == suppressedTriggerKeyCode { return true }
        let held = currentHeldModifierBits()
        guard let binding = TBInputBindingEngine.match(keyCode: keyCode, modifiers: held, in: inputBindings) else {
            return false
        }
        suppressedTriggerKeyCode = keyCode
        TBInputDebugLog.log("binding MATCH: trigger=\(binding.trigger.displayString) -> inject \(binding.action.displayString)")
        injectActionViaSystemEvents(binding.action)
        return true
    }

    /// Inject a binding action through System Events (AppleScript) rather than a
    /// raw CGEvent. The WindowServer ignores synthetic CGEvent presses for
    /// protected symbolic hotkeys (e.g. ⌃← to switch Spaces), but honors the same
    /// shortcut when it comes from the trusted System Events process.
    ///
    /// The user may be holding the trigger's modifiers, which we inject as held
    /// CGEvent state — that would contaminate the action (e.g. a stray ⌥). So we
    /// release the held modifiers first so System Events sees a clean combo. On
    /// completion, restore only modifiers that the receiver still holds.
    private func injectActionViaSystemEvents(_ action: TBInputShortcut) {
        let heldKeyCodes = currentlyHeldRemoteModifierKeyCodes()
        for keyCode in heldKeyCodes { postLocalKey(keyCode: keyCode, isDown: false) }

        // Run the AppleScript in-process (NSAppleScript), NOT via /usr/bin/osascript:
        // when spawned, osascript is the keystroke-sending client and lacks
        // Accessibility (error 1002). In-process, this app is the client and it
        // already holds Accessibility + Automation, so System Events is allowed
        // to post the shortcut.
        let source = "tell application \"System Events\" to key code \(action.keyCode)\(Self.appleScriptModifierClause(action.modifiers))"
        DispatchQueue.global(qos: .userInitiated).async {
            var errorInfo: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
            let failure: String? = errorInfo.map { "\($0)" }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let failure { TBInputDebugLog.log("system-events inject error: \(failure)") }
                guard self.inputControlRole == .receiverMaster else { return }
                for keyCode in self.currentlyHeldRemoteModifierKeyCodes() {
                    self.postLocalKey(keyCode: keyCode, isDown: true)
                }
            }
        }
    }

    private func updateRemoteModifierState(keyCode: UInt16, isDown: Bool) {
        guard TBInputBindingEngine.modifierBit(for: keyCode) != nil else { return }
        if isDown {
            remoteHeldModifierKeyCodes.insert(keyCode)
        } else {
            remoteHeldModifierKeyCodes.remove(keyCode)
        }
    }

    private func currentlyHeldRemoteModifierKeyCodes() -> [UInt16] {
        TBInputShortcut.modifierTable.compactMap { modifier in
            remoteHeldModifierKeyCodes.first {
                TBInputBindingEngine.modifierBit(for: $0) == modifier.bit
            }
        }
    }

    private static func appleScriptModifierClause(_ modifiers: UInt32) -> String {
        var parts: [String] = []
        if modifiers & TBInputShortcut.control != 0 { parts.append("control down") }
        if modifiers & TBInputShortcut.option  != 0 { parts.append("option down") }
        if modifiers & TBInputShortcut.shift   != 0 { parts.append("shift down") }
        if modifiers & TBInputShortcut.command != 0 { parts.append("command down") }
        guard !parts.isEmpty else { return "" }
        return " using {" + parts.joined(separator: ", ") + "}"
    }

    /// Current held modifier state (our bitmask) reconstructed from injected keys.
    private func currentHeldModifierBits() -> UInt32 {
        var m: UInt32 = 0
        if injectedControlDown { m |= TBInputShortcut.control }
        if injectedOptionDown  { m |= TBInputShortcut.option }
        if injectedShiftDown   { m |= TBInputShortcut.shift }
        if injectedCommandDown { m |= TBInputShortcut.command }
        return m
    }

    private func handleDisplayProfile(_ payload: Data) {
        guard activeProfile == nil,
              let profile = TBMonitorProtocol.decodeJSON(TBMonitorDisplayProfile.self, from: payload)
        else { return }

        activeProfile = profile
        if profile.supportsHeartbeatAck == true {
            recordSessionEvent("Receiver heartbeat ACK capability enabled")
        }
        let receiverIdentity = [
            profile.receiverVersion.map { "v\($0)" },
            profile.receiverBuild.map { "build \($0)" },
            profile.receiverCommit.map { "commit \($0)" }
        ].compactMap { $0 }.joined(separator: ", ")
        recordSessionEvent(
            "Receiver profile: \(profile.panelWidth)×\(profile.panelHeight), mode \(profile.modeWidth)×\(profile.modeHeight), \(Int(profile.refreshRate.rounded())) Hz" +
            (receiverIdentity.isEmpty ? ", build unknown" : ", \(receiverIdentity)")
        )
        if let supportsHEVCDecode = profile.supportsHEVCDecode {
            receiverSupportsHEVCDecodeHint = supportsHEVCDecode
        }

        receiverSupportsRawNV12Hint = profile.supportsRawNV12
        receiverSupportsRawNV12LZ4Hint = profile.supportsRawNV12LZ4
        receiverSupportsRawNV12TileRunsHint =
            profile.supportsRawNV12TileRuns
        receiverSupportsBC7Mode6Hint = profile.supportsBC7Mode6
        receiverSupportsBC7TileDeltaHint = profile.supportsBC7TileDelta
        receiverSupportsBC7LZFSEHint = profile.supportsBC7LZFSE
        receiverSupportsBC7LZ4Hint = profile.supportsBC7LZ4
        if let inputMonitoringTrusted = profile.inputMonitoringTrusted {
            receiverInputMonitoringTrustedHint = inputMonitoringTrusted
        }
        if let accessibilityTrusted = profile.accessibilityTrusted {
            receiverAccessibilityTrustedHint = accessibilityTrusted
        }
        receiverPanelText = TBDisplaySenderL10n.receiverSummary(profile, language: language)
        sendAutomaticReceiverStateUpdates()

        Task { @MainActor in
            if self.isCableTestConnection {
                self.setStatus(.testingCable)
                do {
                    let rate = try await self.performCableTest()
                    self.cableTestResult = rate
                } catch {
                    NSLog("TargetBridge: cable test failed: \(error)")
                    self.stop(
                        resetStatusTo:
                            .connectionFailed(error.localizedDescription),
                        closeContext: .test(
                            "cable_test_failed",
                            detail: error.localizedDescription
                        )
                    )
                    return
                }
                self.isCableTestConnection = false
                self.isCableTesting = false
                self.stop(
                    resetStatusTo: .stopped,
                    closeContext: .test(
                        "cable_test_complete",
                        detail: "Cable test completed"
                    )
                )
                return
            }

            self.setStatus(.creatingVirtualDisplay)
            self.baselineDisplayIDs = await self.fetchShareableDisplayIDs()
            let receiverKey = self.extendedDisplayIdentityKey(for: profile)
            let modeOverride: TBVirtualDisplayModeSize? = (self.matchRenderToStream && self.captureSource == .extendedDesktop)
                ? self.capturePreset.renderMatchedDisplayMode
                : nil
            if let modeOverride {
                NSLog(
                    "TargetBridge: render matching on, virtual display mode %dx%d (backing %dx%d) for %dx%d stream",
                    modeOverride.width, modeOverride.height,
                    modeOverride.backingWidth, modeOverride.backingHeight,
                    self.capturePreset.width, self.capturePreset.height
                )
            }
            guard self.session.create(
                from: profile,
                refreshRate: self.capturePreset.virtualDisplayRefreshRate,
                modeOverride: modeOverride,
                identity: self.captureSource.virtualDisplayIdentity(receiverKey: receiverKey),
                receiverKey: receiverKey
            ) else {
                self.setStatus(.virtualDisplayCreationFailed)
                self.stop(
                    resetStatusTo: nil,
                    closeContext: .appError(
                        "virtual_display_creation_failed",
                        detail: "Unable to create virtual display"
                    )
                )
                return
            }
            if self.captureSource == .desktopMirror {
                let displayReady = await self.waitForOnlineDisplay(self.session.displayID)
                let mirrorConfigured = displayReady && self.configureDesktopMirror(for: self.session.displayID)
                if !mirrorConfigured {
                    NSLog(
                        "TargetBridge: unable to enable mirror mode for virtual display %u on first attempt; scheduling retry",
                        self.session.displayID
                    )
                }
            }
            self.virtualDisplayText = TBDisplaySenderL10n.virtualDisplaySummary(
                name: self.session.displayName,
                id: self.session.displayID,
                language: self.language
            )
            self.displayStateText = self.describeDisplayState(for: self.session.displayID)
            self.refreshDisplayModeDiagnostics()
            self.recordSessionEvent("Virtual display: \(self.displayModeDiagnosticsText)")

            // Reset the first-frame flag BEFORE capture starts. startCapture() is
            // async and frames can begin flowing (firing handleFirstEncodedFrame,
            // which sets sessionAckSent = true) during its suspension. Resetting
            // afterward would clobber that true back to false, leaving the watchdog
            // armed against a session that has already delivered frames — it then
            // tears down a healthy stream ~4s in. See onFirstFrame wiring below.
            self.sessionAckSent = false
            self.setStatus(.startingCapture(self.capturePreset.description, self.captureSource))
            let started = await self.startCapture(for: profile)
            guard started else {
                self.stop(
                    resetStatusTo: nil,
                    closeContext: .appError(
                        "capture_start_failed",
                        detail: "Unable to start capture"
                    )
                )
                return
            }

            if self.captureSource == .extendedDesktop {
                self.scheduleExtendedDesktopRecovery(for: self.session.displayID)
            } else if self.captureSource == .desktopMirror {
                self.scheduleDesktopMirrorRecovery(for: self.session.displayID)
            }

            self.setStatus(.captureStartedWaitingFirstFrame)
            self.startFirstFrameWatchdog()
        }
    }

    private func handleReceiverMetrics(_ payload: Data) {
        guard let metrics = TBMonitorProtocol.decodeJSON(
            TBMonitorReceiverMetrics.self,
            from: payload
        ) else {
            TBLog.connection.error("Receiver metrics payload could not be decoded")
            return
        }
        receiverMetricsText = String(
            format: "apply fps=%.2f · present fps=%.2f · %.3f Gbit/s · seq=%llu · frames=%llu · compressed=%llu · ratio=%.3f · decompress p95=%.2f ms · packet p95=%.2f ms · apply p95=%.2f ms · upload p95=%.2f ms · present p95=%.2f ms · cadence p95=%.2f ms · invalid=%llu · decompress failures=%llu · render failures=%llu · keyframe requests=%llu",
            metrics.fps,
            metrics.presentFPS ?? 0,
            metrics.networkGbps,
            metrics.appliedSequence,
            metrics.bc7Frames,
            metrics.compressedPackets ?? 0,
            (metrics.rawBlockBytes ?? 0) > 0
                ? Double(metrics.compressedBlockBytes ?? 0) /
                    Double(metrics.rawBlockBytes ?? 1)
                : 1.0,
            metrics.decompressionP95Ms ?? 0,
            metrics.packetIntervalP95Ms ?? 0,
            metrics.applyP95Ms ?? 0,
            metrics.uploadP95Ms ?? 0,
            metrics.presentP95Ms ?? 0,
            metrics.presentIntervalP95Ms ?? 0,
            metrics.bc7Invalid,
            metrics.decompressionFailures ?? 0,
            metrics.renderFailures,
            metrics.keyframeRequests
        )
        liveMetrics.receiverFPS = metrics.presentFPS ?? metrics.fps
        let event = "Receiver metrics: \(receiverMetricsText)"
        TBLog.connection.info("\(event, privacy: .public)")
        if lastReceiverMetrics == nil ||
            metrics.bc7Invalid != lastReceiverMetrics?.bc7Invalid ||
            metrics.renderFailures != lastReceiverMetrics?.renderFailures ||
            metrics.keyframeRequests != lastReceiverMetrics?.keyframeRequests {
            recordSessionEvent(event)
        }
        lastReceiverMetrics = metrics
    }

    private func startCapture(for profile: TBMonitorDisplayProfile) async -> Bool {
        do {
            let preset = capturePreset
            if videoTransportMode == .bc7Mode6, !videoTransportMode.isSupported(by: profile) {
                bc7TestStatusText = "Receiver does not support BC7 Mode 6."
                setStatus(.connectionFailed(bc7TestStatusText))
                return false
            }
            if videoTransportMode == .rawNV12, !videoTransportMode.isSupported(by: profile) {
                setStatus(.connectionFailed("Receiver does not support raw NV12."))
                return false
            }
            let usesBC7Mode6 = bc7Mode6Enabled(for: profile)
            let usesRawNV12 = !usesBC7Mode6 && rawNV12Enabled(for: profile)
            let codecType = resolvedCodecType(for: preset, profile: profile)
            let codecName = usesBC7Mode6 ? "BC7 Mode 6" : (usesRawNV12 ? "NV12 RAW" : codecName(for: codecType))
            activeCodecType = (usesRawNV12 || usesBC7Mode6) ? nil : codecType
            activeCodecName = codecName
            guard let connection else { return false }
            captureGeneration &+= 1
            let generation = captureGeneration
            pipelineHasFirstFrame = false

            // The encode/send pipeline runs entirely on its own serial queue,
            // off the main thread, so SwiftUI layout can never stall frame
            // delivery. Preset/dimensions/codec are immutable for a session
            // (the pickers are disabled while streaming), so we capture them once.
            let pipeline = TBVideoPipeline(
                preset: preset,
                codecType: codecType,
                connection: connection,
                displayName: session.displayName,
                displayID: session.displayID,
                usesRawNV12: usesRawNV12,
                usesRawNV12LZ4: usesRawNV12 &&
                    profile.supportsRawNV12LZ4 == true,
                usesRawNV12TileRuns: usesRawNV12 &&
                    profile.supportsRawNV12TileRuns == true,
                usesRawNV12CopyRect: usesRawNV12,
                usesBC7Mode6: usesBC7Mode6,
                usesBC7TileDelta: usesBC7Mode6 && profile.supportsBC7TileDelta == true,
                bc7CompressionMode: usesBC7Mode6
                    ? tbResolveBC7CompressionMode(
                        requested: self.bc7CompressionMode,
                        supportsLZ4: profile.supportsBC7LZ4 == true,
                        supportsLZFSE: profile.supportsBC7LZFSE == true
                    )
                    : .off,
                ackAlreadySent: sessionAckSent,
                onFirstFrame: { [weak self] width, height in
                    Task { @MainActor in
                        self?.handleFirstEncodedFrame(
                            generation: generation,
                            width: width,
                            height: height
                        )
                    }
                }
            )
            if usesBC7Mode6 {
                bc7RenderConfirmed = false
                bc7RenderGeneration &+= 1
                var requestPayload = Data()
                TBMonitorProtocol.appendBE32(&requestPayload, bc7RenderGeneration)
                connection.send(
                    content: TBMonitorProtocol.makePacket(type: .bc7RenderAckRequest, payload: requestPayload),
                    completion: .contentProcessed({ error in
                        if let error {
                            TBLog.connection.error("BC7 render acknowledgment request failed: \(error.localizedDescription, privacy: .public)")
                        }
                    })
                )
            }
            guard pipeline.start() else {
                if usesBC7Mode6 {
                    bc7TestStatusText = "Sender Metal BC7 encoder initialization failed."
                    setStatus(.captureError(bc7TestStatusText))
                }
                return false
            }
            self.pipeline = pipeline
            if usesBC7Mode6 {
                bc7TestStatusText = "BC7 Sender active; waiting for Receiver render confirmation."
            }
            TBLog.connection.info("capture: pipeline started preset=\(preset.rawValue, privacy: .public) source=\(String(describing: self.captureSource), privacy: .public) codec=\(codecName, privacy: .public) rawNV12=\(usesRawNV12, privacy: .public)")

            let display: SCDisplay
            if captureSource == .desktopMirror {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let mainDisplay = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
                    return false
                }
                display = mainDisplay
            } else {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                if session.displayID != kCGNullDirectDisplay,
                   let targetDisplay = content.displays.first(where: { $0.displayID == session.displayID }) {
                    display = targetDisplay
                } else {
                    display = try await waitForCaptureDisplay()
                }
            }
            if preset == .native5k || preset == .native5k60Experimental {
                guard let sourceMode = CGDisplayCopyDisplayMode(display.displayID),
                      tbSourceFramebufferSupportsNativeCapture(
                          preset: preset,
                          pixelWidth: sourceMode.pixelWidth,
                          pixelHeight: sourceMode.pixelHeight
                      ) else {
                    let sourceMode = CGDisplayCopyDisplayMode(display.displayID)
                    let sourceWidth = sourceMode?.pixelWidth ?? 0
                    let sourceHeight = sourceMode?.pixelHeight ?? 0
                    bc7TestStatusText =
                        "5K validation failed: source framebuffer is \(sourceWidth)×\(sourceHeight), not native 5120×2880."
                    setStatus(.captureError(bc7TestStatusText))
                    return false
                }
                bc7TestStatusText =
                    "Native 5K source verified: \(sourceMode.pixelWidth)×\(sourceMode.pixelHeight); waiting for Receiver render confirmation."
            }

            let configuration = SCStreamConfiguration()
            configuration.width = preset.width
            configuration.height = preset.height
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: Int32(preset.expectedFrameRate))
            configuration.queueDepth = preset.queueDepth
            configuration.pixelFormat = usesBC7Mode6
                ? kCVPixelFormatType_32BGRA
                : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            configuration.showsCursor = !largeCursor
            configuration.scalesToFit = true
            configuration.captureResolution = preset.captureResolution
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48000
            configuration.channelCount = 2

            streamResolutionText = TBDisplaySenderL10n.streamSummary(
                preset: preset,
                source: captureSource,
                language: language,
                codecName: codecName
            )

            let delegate = CaptureDelegate()
            delegate.onFrameStatus = { status in
                pipeline.recordCaptureCallback(status: status)
            }
            delegate.onFrame = { sampleBuffer in
                pipeline.submitCapturedFrame(sampleBuffer)
            }
            delegate.onAudio = { [weak self] sampleBuffer in
                self?.processAudio(sampleBuffer)
            }
            delegate.onError = { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.setStatus(.captureError(self.formattedCaptureErrorMessage(for: error)))
                    self.stop(
                        resetStatusTo: nil,
                        closeContext: .appError(
                            "capture_error",
                            detail:
                                self.formattedCaptureErrorMessage(for: error)
                        )
                    )
                }
            }
            captureDelegate = delegate

            let filter = SCContentFilter(display: display, excludingWindows: [])
            captureDisplayText = TBDisplaySenderL10n.captureDisplaySCDisplay(language, id: display.displayID)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
            try stream.addStreamOutput(
                delegate,
                type: .screen,
                sampleHandlerQueue: DispatchQueue(label: "fd.tbmonitor.sender.capture", qos: .userInteractive)
            )
            try stream.addStreamOutput(
                delegate,
                type: .audio,
                sampleHandlerQueue: DispatchQueue(label: "fd.tbmonitor.sender.audio", qos: .userInteractive)
            )
            try await stream.startCapture()
            scStream = stream
            isStreaming = true
            if largeCursor { startCursorUpdates(displayID: display.displayID) }
            streamingActivity = ProcessInfo.processInfo.beginActivity(
                options: activityOptions(),
                reason: "TargetBridge streaming active"
            )
            startFPSTimer()
            startCaptureWatchdog()
            return true
        } catch {
            if error.localizedDescription.hasPrefix("no virtual SCDisplay available") {
                setStatus(.noShareableDisplay(error.localizedDescription))
            } else {
                setStatus(.captureDesktopError(formattedCaptureErrorMessage(for: error)))
            }
            return false
        }
    }

    private func startDirectDisplayStream(displayID: CGDirectDisplayID, preset: TBDisplayCapturePreset) -> Bool {
        guard let pipeline else { return false }
        let codecName = activeCodecName ?? codecName(for: activeCodecType ?? preset.codecType)
        streamResolutionText = TBDisplaySenderL10n.streamSummary(
            preset: preset,
            source: captureSource,
            language: language,
            codecName: codecName
        )

        // Deliver frames straight onto the pipeline's own queue — the handler
        // runs there, so encode happens off the main thread with no extra hop.
        let directCapture = TBDirectDisplayStreamCapture(pipeline: pipeline, queue: pipeline.queue)
        guard directCapture.start(displayID: displayID, preset: preset, showCursor: !largeCursor) else {
            return false
        }

        directDisplayStream = directCapture
        captureDisplayText = TBDisplaySenderL10n.captureDisplayCGDisplayStream(language, id: displayID)
        isStreaming = true
        if largeCursor { startCursorUpdates(displayID: displayID) }
        streamingActivity = ProcessInfo.processInfo.beginActivity(
            options: activityOptions(),
            reason: "TargetBridge streaming active"
        )
        startFPSTimer()
        startCaptureWatchdog()
        return true
    }

    private func activityOptions() -> ProcessInfo.ActivityOptions {
        var options: ProcessInfo.ActivityOptions = [.userInitiated, .idleSystemSleepDisabled]
        if preventDisplaySleep {
            options.insert(.idleDisplaySleepDisabled)
        }
        return options
    }

    private func waitForCaptureDisplay() async throws -> SCDisplay {
        let targetDisplayID = (captureSource == .desktopMirror) ? CGMainDisplayID() : session.displayID
        return try await waitForVirtualDisplay(
            matching: targetDisplayID,
            baselineDisplayIDs: baselineDisplayIDs
        )
    }

    private func waitForVirtualDisplay(
        matching targetDisplayID: CGDirectDisplayID,
        baselineDisplayIDs: Set<CGDirectDisplayID>
    ) async throws -> SCDisplay {
        enum DisplayLookupError: LocalizedError {
            case notFound(details: String)

            var errorDescription: String? {
                switch self {
                case .notFound(let details):
                    return details
                }
            }
        }

        var lastContent: SCShareableContent?
        for _ in 0..<80 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            lastContent = content
            if let display = content.displays.first(where: { $0.displayID == targetDisplayID }) {
                return display
            }
            if let display = content.displays.first(where: { !baselineDisplayIDs.contains($0.displayID) }) {
                return display
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        let content: SCShareableContent
        if let lastContent {
            content = lastContent
        } else {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        }
        let availableIDs = content.displays.map { String($0.displayID) }.sorted().joined(separator: ", ")
        let baselineIDs = baselineDisplayIDs.map(String.init).sorted().joined(separator: ", ")
        let onlineIDs = onlineDisplayIDs().map(String.init).sorted().joined(separator: ", ")
        throw DisplayLookupError.notFound(
            details: "no virtual SCDisplay available (target=\(targetDisplayID), baseline=[\(baselineIDs)], available=[\(availableIDs)], online=[\(onlineIDs)])"
        )
    }

    private func fetchShareableDisplayIDs() async -> Set<CGDirectDisplayID> {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            return Set(content.displays.map(\.displayID))
        } catch {
            return []
        }
    }

    /// A freshly created virtual display can be reported by CoreGraphics before
    /// it is usable in a display configuration. Waiting briefly avoids racing
    /// `CGConfigureDisplayMirrorOfDisplay` on first connect.
    private func waitForOnlineDisplay(_ displayID: CGDirectDisplayID) async -> Bool {
        for _ in 0..<20 {
            if onlineDisplayIDs().contains(displayID) {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return onlineDisplayIDs().contains(displayID)
    }

    private func rawNV12Enabled(for profile: TBMonitorDisplayProfile) -> Bool {
        videoTransportMode == .rawNV12 && profile.supportsRawNV12 == true
    }

    private func bc7Mode6Enabled(for profile: TBMonitorDisplayProfile) -> Bool {
        videoTransportMode == .bc7Mode6 && profile.supportsBC7Mode6 == true
    }

    private func configureDesktopMirror(for virtualDisplayID: CGDirectDisplayID) -> Bool {
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            var displayConfig: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&displayConfig) == .success, let cfg = displayConfig else {
                return false
            }

            var completed = false
            defer {
                if !completed {
                    CGCancelDisplayConfiguration(cfg)
                }
            }

            let result = CGConfigureDisplayMirrorOfDisplay(cfg, virtualDisplayID, CGMainDisplayID())
            if result == .success {
                let complete = CGCompleteDisplayConfiguration(cfg, .forSession)
                if complete == .success {
                    completed = true
                    return true
                }
            }

            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }

        return false
    }

    private func scheduleExtendedDesktopRecovery(for virtualDisplayID: CGDirectDisplayID) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            var hasAppliedArrangement = false

            for attempt in 1...12 {
                try? await Task.sleep(nanoseconds: 500_000_000)

                guard self.captureSource == .extendedDesktop,
                      self.session.displayID == virtualDisplayID,
                      self.activeProfile != nil
                else { return }

                // A newly recreated virtual display can already be outside a mirror set
                // while still sitting at macOS's default placement on the right.
                // Force at least one explicit extended-desktop configuration pass so
                // we can reapply the saved arrangement for this receiver.
                if CGDisplayIsInMirrorSet(virtualDisplayID) == 0 && hasAppliedArrangement {
                    self.displayStateText = self.describeDisplayState(for: virtualDisplayID)
                    return
                }

                let configured = self.configureExtendedDesktop(for: virtualDisplayID)
                if configured {
                    hasAppliedArrangement = true
                }
                self.displayStateText = self.describeDisplayState(for: virtualDisplayID)
                NSLog(
                    "TargetBridge: extended desktop recovery attempt %d for %u configured=%d state=%@",
                    attempt,
                    virtualDisplayID,
                    configured,
                    self.displayStateText
                )

                if configured || (CGDisplayIsInMirrorSet(virtualDisplayID) == 0 && hasAppliedArrangement) {
                    return
                }
            }
        }
    }

    private func scheduleDesktopMirrorRecovery(for virtualDisplayID: CGDirectDisplayID) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            for attempt in 1...12 {
                try? await Task.sleep(nanoseconds: 500_000_000)

                guard self.captureSource == .desktopMirror,
                      self.session.displayID == virtualDisplayID,
                      self.activeProfile != nil
                else { return }

                if CGDisplayIsInMirrorSet(virtualDisplayID) != 0 {
                    self.displayStateText = self.describeDisplayState(for: virtualDisplayID)
                    return
                }

                let configured = self.configureDesktopMirror(for: virtualDisplayID)
                self.displayStateText = self.describeDisplayState(for: virtualDisplayID)
                NSLog(
                    "TargetBridge: desktop mirror recovery attempt %d for %u configured=%d state=%@",
                    attempt,
                    virtualDisplayID,
                    configured,
                    self.displayStateText
                )

                if configured || CGDisplayIsInMirrorSet(virtualDisplayID) != 0 {
                    return
                }
            }
        }
    }

    private func configureExtendedDesktop(for virtualDisplayID: CGDirectDisplayID) -> Bool {
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            var displayConfig: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&displayConfig) == .success, let cfg = displayConfig else {
                return false
            }

            var completed = false
            defer {
                if !completed {
                    CGCancelDisplayConfiguration(cfg)
                }
            }

            let mainDisplayID = CGMainDisplayID()
            let mainBounds = CGDisplayBounds(mainDisplayID)
            let mainMirrorResult = CGConfigureDisplayMirrorOfDisplay(cfg, mainDisplayID, kCGNullDirectDisplay)
            let virtualMirrorResult = CGConfigureDisplayMirrorOfDisplay(cfg, virtualDisplayID, kCGNullDirectDisplay)
            if mainMirrorResult != .success || virtualMirrorResult != .success {
                NSLog(
                    "TargetBridge: failed to detach mirror set for extended desktop (main=%d virtual=%d)",
                    mainMirrorResult.rawValue,
                    virtualMirrorResult.rawValue
                )
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
                continue
            }

            let mainOriginResult = CGConfigureDisplayOrigin(cfg, mainDisplayID, 0, 0)
            let savedArrangement = activeProfile.flatMap { loadSavedExtendedDisplayArrangement(for: $0) }
            let defaultTargetX = Int32((mainBounds.maxX - mainBounds.origin.x).rounded())
            let targetX: Int32
            let targetY: Int32
            if let savedArrangement {
                if savedArrangement.isRelativeToMainDisplay {
                    targetX = Int32(mainBounds.origin.x.rounded()) + savedArrangement.x
                    targetY = Int32(mainBounds.origin.y.rounded()) + savedArrangement.y
                } else {
                    targetX = savedArrangement.x
                    targetY = savedArrangement.y
                }
            } else {
                targetX = defaultTargetX
                targetY = 0
            }
            let originResult = CGConfigureDisplayOrigin(cfg, virtualDisplayID, targetX, targetY)
            if mainOriginResult != .success || originResult != .success {
                NSLog(
                    "TargetBridge: failed to position displays for extended desktop (main=%d virtual=%u targetX=%d targetY=%d result=%d)",
                    mainOriginResult.rawValue,
                    virtualDisplayID,
                    targetX,
                    targetY,
                    originResult.rawValue
                )
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
                continue
            }

            let complete = CGCompleteDisplayConfiguration(cfg, .forSession)
            if complete == .success {
                completed = true
                return true
            }
            NSLog(
                "TargetBridge: CGCompleteDisplayConfiguration failed while forcing extended desktop for %u (result=%d)",
                virtualDisplayID,
                complete.rawValue
            )

            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }

        return CGDisplayIsInMirrorSet(virtualDisplayID) == 0
    }

    private func describeDisplayState(for virtualDisplayID: CGDirectDisplayID) -> String {
        let mainDisplayID = CGMainDisplayID()
        let virtualMirror = CGDisplayIsInMirrorSet(virtualDisplayID) != 0
        let mainMirror = CGDisplayIsInMirrorSet(mainDisplayID) != 0
        let virtualMirrors = CGDisplayMirrorsDisplay(virtualDisplayID)
        let mainMirrors = CGDisplayMirrorsDisplay(mainDisplayID)
        let identity = session.identityDescription.isEmpty ? "identity=n/a" : session.identityDescription
        return TBDisplaySenderL10n.displayStateSummary(
            language: language,
            identity: identity,
            virtual: virtualDisplayID,
            virtualMirror: virtualMirror,
            virtualMirrors: virtualMirrors,
            main: mainDisplayID,
            mainMirror: mainMirror,
            mainMirrors: mainMirrors
        )
    }

    private func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return [] }
        return Array(displays.prefix(Int(count)))
    }
    private func startCursorUpdates(displayID: CGDirectDisplayID) {
        cursorTimer?.invalidate()
        cursorDisplayID = displayID
        lastCursorPacket = nil

        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                sendCursorUpdateIfNeeded()
            }
        }
        cursorTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        sendCursorUpdateIfNeeded(force: true)
    }

    private func sendHiddenCursorPacketIfNeeded() {
        guard isConnected else { return }

        let cursor = TBMonitorCursor(
            x: 0,
            y: 0,
            width: capturePreset.width,
            height: capturePreset.height,
            visible: false,
            type: 0
        )
        lastCursorPacket = cursor
        if let packet = TBMonitorProtocol.makeJSONPacket(type: .cursor, value: cursor) {
            send(packet)
        }
    }

    private func applyCursorOverlayMode() {
        if inputRelayActive {
            cursorTimer?.invalidate()
            cursorTimer = nil
            sendHiddenCursorPacketIfNeeded()
            return
        }

        guard largeCursor, isStreaming, cursorDisplayID != kCGNullDirectDisplay else { return }
        startCursorUpdates(displayID: cursorDisplayID)
    }

    private func getCurrentCursorType() -> Int {
        guard let current = NSCursor.currentSystem else { return 0 }
        if let last = lastCheckedCursor, last == current {
            return lastCheckedCursorType
        }

        lastCheckedCursor = current

        if let currentPng = Self.normalizedPng(for: current.image),
           let matchedType = Self.standardCursorPngs[currentPng] {
            lastCheckedCursorType = matchedType
            return matchedType
        }

        let size = current.image.size
        let hotSpot = current.hotSpot
        let type: Int
        if size.width > 0 && size.height > 0 {
            if hotSpot.x > 0 && hotSpot.x < 10 && hotSpot.y == 0 {
                type = 2 // Pointing Hand
            } else if size.width < size.height && abs(hotSpot.x - size.width / 2) < 2 && abs(hotSpot.y - size.height / 2) < 2 {
                type = 1 // I-Beam
            } else if abs(hotSpot.x - size.width / 2) < 2 && abs(hotSpot.y - size.height / 2) < 2 {
                if size.width > size.height {
                    type = 3 // Resize Horizontal
                } else if size.height > size.width {
                    type = 4 // Resize Vertical
                } else {
                    type = 3 // Default fallback for square symmetric cursors: Resize Horizontal
                }
            } else {
                type = 0 // Arrow
            }
        } else {
            type = 0 // Arrow
        }

        lastCheckedCursorType = type
        return type
    }

    private func sendCursorUpdateIfNeeded(force: Bool = false) {
        guard !inputRelayActive else { return }
        guard isConnected, isStreaming, cursorDisplayID != kCGNullDirectDisplay else { return }
        guard let point = CGEvent(source: nil)?.location else { return }

        let bounds = CGDisplayBounds(cursorDisplayID)
        guard bounds.width > 0, bounds.height > 0 else { return }

        let localX = point.x - bounds.origin.x
        let localY = point.y - bounds.origin.y
        let visible = localX >= 0 && localY >= 0 && localX <= bounds.width && localY <= bounds.height

        let scaledX = Int((max(0, min(bounds.width, localX)) / bounds.width) * Double(capturePreset.width))
        let scaledY = Int((max(0, min(bounds.height, localY)) / bounds.height) * Double(capturePreset.height))
        let cursor = TBMonitorCursor(
            x: scaledX,
            y: scaledY,
            width: capturePreset.width,
            height: capturePreset.height,
            visible: visible,
            type: getCurrentCursorType()
        )

        if !force, let previous = lastCursorPacket {
            let movement = abs(previous.x - cursor.x) + abs(previous.y - cursor.y)
            if movement < 2,
               previous.visible == cursor.visible,
               previous.width == cursor.width,
               previous.height == cursor.height,
               previous.type == cursor.type {
                return
            }
        }

        lastCursorPacket = cursor
        if let packet = TBMonitorProtocol.makeJSONPacket(type: .cursor, value: cursor) {
            send(packet)
        }
    }

    private func registerWakeObservers() {
        let handler: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSystemWake()
            }
        }

        wakeObservers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil,
                queue: nil,
                using: handler
            )
        )
        wakeObservers.append(
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.apple.screenIsUnlocked"),
                object: nil,
                queue: nil,
                using: handler
            )
        )
        wakeObservers.append(
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.apple.screensaver.didstop"),
                object: nil,
                queue: nil,
                using: handler
            )
        )
    }

    private func registerDisplayReconfigurationCallback() {
        guard !displayReconfigurationCallbackRegistered else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = CGDisplayRegisterReconfigurationCallback(Self.displayReconfigurationCallback, context)
        displayReconfigurationCallbackRegistered = (result == .success)
        if verboseDisplayLogging {
            startVerboseLoggingTimer()
        }
    }

    private func handleDisplayReconfiguration(displayID: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        let isOurs = session.displayID != kCGNullDirectDisplay && displayID == session.displayID
        guard verboseDisplayLogging || isOurs else { return }
        var parts: [String] = []
        if flags.contains(.addFlag) { parts.append("add") }
        if flags.contains(.removeFlag) { parts.append("remove") }
        if flags.contains(.enabledFlag) { parts.append("enabled") }
        if flags.contains(.disabledFlag) { parts.append("disabled") }
        if flags.contains(.mirrorFlag) { parts.append("mirror") }
        if flags.contains(.unMirrorFlag) { parts.append("unMirror") }
        if flags.contains(.movedFlag) { parts.append("moved") }
        if flags.contains(.setMainFlag) { parts.append("setMain") }
        if flags.contains(.setModeFlag) { parts.append("setMode") }
        if flags.contains(.beginConfigurationFlag) { parts.append("beginConfiguration") }
        if flags.contains(.desktopShapeChangedFlag) { parts.append("desktopShapeChanged") }
        let flagText = parts.isEmpty ? "none" : parts.joined(separator: "|")
        NSLog(
            "TargetBridge: display reconfiguration displayID=%u ours=%@ flags=%@ online=[%@]",
            displayID,
            isOurs ? "yes" : "no",
            flagText,
            onlineDisplayIDs().map(String.init).joined(separator: ",")
        )
        if isOurs, session.displayID != kCGNullDirectDisplay {
            displayStateText = describeDisplayState(for: session.displayID)
        }
    }

    private func startVerboseLoggingTimer() {
        stopVerboseLoggingTimer()
        guard verboseDisplayLogging else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.logStreamSnapshot()
            }
        }
        verboseLoggingTimer = timer
        logStreamSnapshot()
    }

    private func stopVerboseLoggingTimer() {
        verboseLoggingTimer?.invalidate()
        verboseLoggingTimer = nil
    }

    private func startCaptureWatchdog() {
        captureHealthWatchdog?.invalidate()
        captureHealthWatchdog = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkCaptureHealth()
            }
        }
    }

    private func stopCaptureWatchdog() {
        captureHealthWatchdog?.invalidate()
        captureHealthWatchdog = nil
    }

    private func checkCaptureHealth() {
        guard isStreaming, activeProfile != nil, !isRestartingCaptureAfterWake, let pipeline else { return }
        let elapsed = Date().timeIntervalSince(pipeline.lastCaptureFrameAtSnapshot)
        guard elapsed >= 8.0 else { return }
        NSLog("TargetBridge: capture watchdog tripped — %.1fs since last frame, soft restart", elapsed)
        scheduleCaptureRestart(reason: "watchdog (\(Int(elapsed))s without frames)", delaySeconds: 0.5)
    }

    private func logStreamSnapshot() {
        guard verboseDisplayLogging else { return }
        let online = onlineDisplayIDs()
        let virtualOnline = online.contains(session.displayID)
        let diag = pipeline?.diagnosticsSnapshot() ?? .empty
        NSLog(
            "TargetBridge: stream snapshot streaming=%@ fps=%d virtualID=%u online=%@ pendingPackets=%d inFlightEncode=%d dropped=%d ptsSeq=%lld bc7Keyframes=%d bc7Deltas=%d bc7DirtyTiles=%d bc7FullEncodeFallbacks=%d",
            isStreaming ? "yes" : "no",
            liveMetrics.senderFPS,
            session.displayID,
            virtualOnline ? "yes" : "no",
            diag.pending,
            diag.inFlight,
            diag.dropped,
            diag.ptsSeq,
            diag.bc7Keyframes,
            diag.bc7DeltaFrames,
            diag.bc7DirtyTiles,
            diag.bc7FullEncodeFallbacks
        )
    }

    private func handleSystemWake() {
        grantHeartbeatLivenessGrace()
        guard autoRestartOnWake else { return }
        scheduleCaptureRestart(reason: "system wake", delaySeconds: 1.0)
    }

    func restartCaptureNow() {
        scheduleCaptureRestart(reason: "manual restart", delaySeconds: 0.0)
    }

    var canRestartCapture: Bool {
        isStreaming && activeProfile != nil && !isRestartingCaptureAfterWake
    }

    private func scheduleCaptureRestart(reason: String, delaySeconds: Double) {
        guard isStreaming, !isRestartingCaptureAfterWake, let profile = activeProfile else { return }
        isRestartingCaptureAfterWake = true
        NSLog("TargetBridge: \(reason) — soft restart of capture pipeline")
        Task { @MainActor [weak self] in
            if delaySeconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }
            guard let self else { return }
            guard self.isStreaming, self.activeProfile?.receiverName == profile.receiverName else {
                self.isRestartingCaptureAfterWake = false
                return
            }
            await self.softRestartCapture(for: profile)
            self.isRestartingCaptureAfterWake = false
        }
    }

    private func softRestartCapture(for profile: TBMonitorDisplayProfile) async {
        // Tear down only the capture pipeline — keep the network connection and virtual display.
        cursorTimer?.invalidate()
        cursorTimer = nil
        fpsTimer?.invalidate()
        fpsTimer = nil
        firstFrameTimer?.invalidate()
        firstFrameTimer = nil
        stopCaptureWatchdog()
        if let directDisplayStream {
            directDisplayStream.stop()
            self.directDisplayStream = nil
        }
        if let stream = scStream {
            if let delegate = captureDelegate {
                try? stream.removeStreamOutput(delegate, type: .screen)
                try? stream.removeStreamOutput(delegate, type: .audio)
            }
            stream.stopCapture(completionHandler: nil)
            scStream = nil
        }
        captureDelegate = nil
        if let activity = streamingActivity {
            ProcessInfo.processInfo.endActivity(activity)
            streamingActivity = nil
        }
        pipeline?.stop()
        pipeline = nil
        isStreaming = false
        actualStreamText = "Not active"
        bc7RenderConfirmed = false
        liveMetrics.senderFPS = 0
        senderFPS = 0
        sentSnapshot = 0
        sentBytesSnapshot = 0
        capturedSnapshot = 0
        bc7ProcessedSnapshot = 0
        bc7EncodeNanosecondsSnapshot = 0
        bc7PlanNanosecondsSnapshot = 0
        bc7PacketNanosecondsSnapshot = 0
        bc7GPUAnalyzedSnapshot = 0
        bc7SendCompletedSnapshot = 0
        bc7SendNanosecondsSnapshot = 0
        transportDiagnosticsText = "pending=0 · in-flight=0 · dropped=0 · 0.00 Gbit/s"
        receiverMetricsText = "Not available"
        lastReceiverMetrics = nil
        cursorDisplayID = kCGNullDirectDisplay
        lastCursorPacket = nil

        let started = await startCapture(for: profile)
        if !started {
            NSLog("TargetBridge: soft restart after wake failed — falling back to full stop")
            stop(
                resetStatusTo:
                    .captureError("capture restart after wake failed"),
                closeContext: .appError(
                    "capture_restart_failed",
                    detail: "Capture restart after wake failed"
                )
            )
        } else {
            setStatus(.captureStartedWaitingFirstFrame)
            startFirstFrameWatchdog()
        }
    }

    private func handleFirstEncodedFrame(generation: UInt64, width: Int, height: Int) {
        guard generation == captureGeneration else { return }
        sessionAckSent = true
        pipelineHasFirstFrame = true
        firstFrameTimer?.invalidate()
        firstFrameTimer = nil
        TBLog.connection.info("capture: first encoded frame received")
        actualStreamText = "\(width) × \(height) · \(activeCodecName ?? capturePreset.codecName)"
        recordSessionEvent("First encoded frame: \(actualStreamText)")
        if capturePreset == .native5k || capturePreset == .native5k60Experimental,
           (width != capturePreset.width || height != capturePreset.height) {
            let message =
                "5K validation failed: captured frame is \(width)×\(height), expected \(capturePreset.width)×\(capturePreset.height)."
            bc7TestStatusText = message
            stop(
                resetStatusTo: .captureError(message),
                closeContext: .appError(
                    "capture_validation_failed",
                    detail: message
                )
            )
            return
        }
        setStatus(.captureActive(capturePreset.description, activeCodecName ?? capturePreset.codecName, captureSource))
    }

    private func startFPSTimer() {
        fpsTimer?.invalidate()
        sentSnapshot = pipeline?.sentFramesSnapshot ?? 0
        sentBytesSnapshot = pipeline?.sentBytesSnapshot ?? 0
        capturedSnapshot = pipeline?.capturedFramesSnapshot ?? 0
        let initialDiagnostics = pipeline?.diagnosticsSnapshot()
        bc7ProcessedSnapshot = initialDiagnostics?.bc7ProcessedFrames ?? 0
        bc7EncodeNanosecondsSnapshot = initialDiagnostics?.bc7EncodeNanoseconds ?? 0
        bc7PlanNanosecondsSnapshot = initialDiagnostics?.bc7PlanNanoseconds ?? 0
        bc7PacketNanosecondsSnapshot = initialDiagnostics?.bc7PacketNanoseconds ?? 0
        bc7GPUAnalyzedSnapshot = initialDiagnostics?.bc7GPUAnalyzedFrames ?? 0
        bc7SendCompletedSnapshot = initialDiagnostics?.bc7SendCompletedFrames ?? 0
        bc7SendNanosecondsSnapshot = initialDiagnostics?.bc7SendNanoseconds ?? 0
        fpsSnapshotAt = Date()
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                let now = Date()
                let intervalSeconds = max(0.001, now.timeIntervalSince(fpsSnapshotAt))
                let total = pipeline?.sentFramesSnapshot ?? 0
                let completedFrames = max(0, total - sentSnapshot)
                let sentHz = Double(completedFrames) / intervalSeconds
                let totalBytes = pipeline?.sentBytesSnapshot ?? 0
                let completedBytes = max(0, totalBytes - sentBytesSnapshot)
                let bytesPerSecond = Double(completedBytes) / intervalSeconds
                let capturedTotal = pipeline?.capturedFramesSnapshot ?? 0
                let capturedFrames = max(0, capturedTotal - capturedSnapshot)
                let captureHz = Double(capturedFrames) / intervalSeconds
                let diagnostics = pipeline?.diagnosticsSnapshot() ?? .empty
                let processedFrames = max(
                    0,
                    diagnostics.bc7ProcessedFrames - bc7ProcessedSnapshot
                )
                let encodeNanoseconds =
                    diagnostics.bc7EncodeNanoseconds - bc7EncodeNanosecondsSnapshot
                let planNanoseconds =
                    diagnostics.bc7PlanNanoseconds - bc7PlanNanosecondsSnapshot
                let packetNanoseconds =
                    diagnostics.bc7PacketNanoseconds - bc7PacketNanosecondsSnapshot
                let sendCompletedFrames = max(
                    0,
                    diagnostics.bc7SendCompletedFrames - bc7SendCompletedSnapshot
                )
                let sendNanoseconds =
                    diagnostics.bc7SendNanoseconds - bc7SendNanosecondsSnapshot
                let gpuAnalyzedFrames = max(
                    0,
                    diagnostics.bc7GPUAnalyzedFrames - bc7GPUAnalyzedSnapshot
                )
                let encodeMilliseconds = processedFrames > 0
                    ? Double(encodeNanoseconds) / Double(processedFrames) / 1_000_000.0
                    : 0
                let planMilliseconds = processedFrames > 0
                    ? Double(planNanoseconds) / Double(processedFrames) / 1_000_000.0
                    : 0
                let packetMilliseconds = processedFrames > 0
                    ? Double(packetNanoseconds) / Double(processedFrames) / 1_000_000.0
                    : 0
                let sendMilliseconds = sendCompletedFrames > 0
                    ? Double(sendNanoseconds) / Double(sendCompletedFrames) / 1_000_000.0
                    : 0
                let completedHz = Double(sendCompletedFrames) / intervalSeconds
                let displayedFPS = Int(sentHz.rounded())
                liveMetrics.senderFPS = displayedFPS
                liveMetrics.senderNetworkGbps =
                    bytesPerSecond * 8.0 / 1_000_000_000.0
                senderFPS = displayedFPS
                sentSnapshot = total
                sentBytesSnapshot = totalBytes
                capturedSnapshot = capturedTotal
                bc7ProcessedSnapshot = diagnostics.bc7ProcessedFrames
                bc7EncodeNanosecondsSnapshot = diagnostics.bc7EncodeNanoseconds
                bc7PlanNanosecondsSnapshot = diagnostics.bc7PlanNanoseconds
                bc7PacketNanosecondsSnapshot = diagnostics.bc7PacketNanoseconds
                bc7GPUAnalyzedSnapshot = diagnostics.bc7GPUAnalyzedFrames
                bc7SendCompletedSnapshot = diagnostics.bc7SendCompletedFrames
                bc7SendNanosecondsSnapshot = diagnostics.bc7SendNanoseconds
                fpsSnapshotAt = now
                transportDiagnosticsText = String(
                    format: "capture=%.1f · sent=%.1f · completed=%.1f · pending=%d · dropped=%d · budget=%d · deferred=%d/%d · queue p95=%.2f ms · send p95=%.2f ms · %.2f Gbit/s",
                    captureHz,
                    sentHz,
                    completedHz,
                    diagnostics.pending,
                    diagnostics.dropped,
                    diagnostics.tileBudget,
                    diagnostics.deferredTiles,
                    diagnostics.worstDeferredAge,
                    Double(diagnostics.queueAge.p95) / 1_000_000.0,
                    Double(diagnostics.sendTime.p95) / 1_000_000.0,
                    bytesPerSecond * 8.0 / 1_000_000_000.0
                )
                var metricsJSON: [String: Any] = [
                    "timestampMs": Int64(now.timeIntervalSince1970 * 1000.0),
                    "commit": TBDisplaySenderBuildInfo.gitCommit,
                    "preset": capturePreset.rawValue,
                    "captureHz": captureHz,
                    "sentHz": sentHz,
                    "completedHz": completedHz,
                    "networkGbps": bytesPerSecond * 8.0 / 1_000_000_000.0,
                    "pending": diagnostics.pending,
                    "dropped": diagnostics.dropped,
                    "processedFrames": processedFrames,
                    "gpuAnalyzedFrames": gpuAnalyzedFrames,
                    "captureComplete": diagnostics.captureComplete,
                    "captureIdle": diagnostics.captureIdle,
                    "captureIntervalP50Ms":
                        Double(diagnostics.captureInterval.p50) / 1_000_000.0,
                    "captureIntervalP95Ms":
                        Double(diagnostics.captureInterval.p95) / 1_000_000.0,
                    "captureIntervalP99Ms":
                        Double(diagnostics.captureInterval.p99) / 1_000_000.0,
                    "queueAgeP50Ms":
                        Double(diagnostics.queueAge.p50) / 1_000_000.0,
                    "queueAgeP95Ms":
                        Double(diagnostics.queueAge.p95) / 1_000_000.0,
                    "queueAgeP99Ms":
                        Double(diagnostics.queueAge.p99) / 1_000_000.0,
                    "encodeAvgMs": encodeMilliseconds,
                    "encodeP95Ms":
                        Double(diagnostics.encodeTime.p95) / 1_000_000.0,
                    "planAvgMs": planMilliseconds,
                    "planP95Ms":
                        Double(diagnostics.planTime.p95) / 1_000_000.0,
                    "packetAvgMs": packetMilliseconds,
                    "packetP95Ms":
                        Double(diagnostics.packetTime.p95) / 1_000_000.0,
                    "sendAvgMs": sendMilliseconds,
                    "sendP50Ms":
                        Double(diagnostics.sendTime.p50) / 1_000_000.0,
                    "sendP95Ms":
                        Double(diagnostics.sendTime.p95) / 1_000_000.0,
                    "sendP99Ms":
                        Double(diagnostics.sendTime.p99) / 1_000_000.0,
                    "packetBytesP50": diagnostics.packetBytes.p50,
                    "packetBytesP95": diagnostics.packetBytes.p95,
                    "dirtyTilesP95": diagnostics.dirtyTiles.p95,
                    "tileBudget": diagnostics.tileBudget,
                    "deferredTiles": diagnostics.deferredTiles,
                    "worstDeferredAge": diagnostics.worstDeferredAge,
                    "compressedPackets": diagnostics.bc7CompressedPackets,
                    "bc7CompressionMode": diagnostics.bc7CompressionMode,
                    "compressionFallbacks": diagnostics.bc7CompressionFallbacks,
                    "rawPacketBytes": diagnostics.bc7RawPacketBytes,
                    "wirePacketBytes": diagnostics.bc7WirePacketBytes,
                    "planeSplitP50Ms":
                        Double(diagnostics.planeSplitTime.p50) / 1_000_000.0,
                    "planeSplitP95Ms":
                        Double(diagnostics.planeSplitTime.p95) / 1_000_000.0,
                    "compressionP50Ms":
                        Double(diagnostics.compressionTime.p50) / 1_000_000.0,
                    "compressionP95Ms":
                        Double(diagnostics.compressionTime.p95) / 1_000_000.0,
                    "nv12FullFrames": diagnostics.nv12FullFrames,
                    "nv12RegionFrames": diagnostics.nv12RegionFrames,
                    "nv12RawBytes": diagnostics.nv12RawBytes,
                    "nv12WireBytes": diagnostics.nv12WireBytes,
                    "nv12CopyP50Ms":
                        Double(diagnostics.nv12CopyTime.p50) / 1_000_000.0,
                    "nv12CopyP95Ms":
                        Double(diagnostics.nv12CopyTime.p95) / 1_000_000.0,
                    "nv12CompressionP50Ms":
                        Double(diagnostics.nv12CompressionTime.p50) / 1_000_000.0,
                    "nv12CompressionP95Ms":
                        Double(diagnostics.nv12CompressionTime.p95) / 1_000_000.0,
                    "nv12ChecksumP50Ms":
                        Double(diagnostics.nv12ChecksumTime.p50) / 1_000_000.0,
                    "nv12ChecksumP95Ms":
                        Double(diagnostics.nv12ChecksumTime.p95) / 1_000_000.0,
                    "nv12PacketP50Ms":
                        Double(diagnostics.nv12PacketTime.p50) / 1_000_000.0,
                    "nv12PacketP95Ms":
                        Double(diagnostics.nv12PacketTime.p95) / 1_000_000.0,
                    "nv12RegionPixelsP50": diagnostics.nv12RegionPixels.p50,
                    "nv12RegionPixelsP95": diagnostics.nv12RegionPixels.p95,
                    "nv12DirtyPixelsP50": diagnostics.nv12DirtyPixels.p50,
                    "nv12DirtyPixelsP95": diagnostics.nv12DirtyPixels.p95,
                    "nv12DirtyRectCountP50":
                        diagnostics.nv12DirtyRectCount.p50,
                    "nv12DirtyRectCountP95":
                        diagnostics.nv12DirtyRectCount.p95,
                    "nv12OverfetchP50":
                        Double(diagnostics.nv12OverfetchPermille.p50) / 1000.0,
                    "nv12OverfetchP95":
                        Double(diagnostics.nv12OverfetchPermille.p95) / 1000.0,
                    "nv12TileDetectionP50Ms":
                        Double(diagnostics.nv12TileDetectionTime.p50) /
                            1_000_000.0,
                    "nv12TileDetectionP95Ms":
                        Double(diagnostics.nv12TileDetectionTime.p95) /
                            1_000_000.0,
                    "nv12RunCountP50": diagnostics.nv12RunCount.p50,
                    "nv12RunCountP95": diagnostics.nv12RunCount.p95,
                    "nv12ZeroCopyPackets": diagnostics.nv12ZeroCopyPackets,
                    "nv12ZeroCopyFallbacks": diagnostics.nv12ZeroCopyFallbacks,
                    "nv12LZ4Encoder": diagnostics.nv12LZ4Encoder,
                    "nv12CopyRectFrames": diagnostics.nv12CopyRectFrames,
                    "nv12CopyRectTiles": diagnostics.nv12CopyRectTiles,
                    "nv12CopyRectRejects": diagnostics.nv12CopyRectRejects,
                    "nv12CopyRectWriterFailures":
                        diagnostics.nv12CopyRectWriterFailures,
                    "nv12CopyRectSkippedSearches":
                        diagnostics.nv12CopyRectSkippedSearches,
                    "nv12CopyRectSearchP50Ms":
                        Double(diagnostics.nv12CopyRectSearchTime.p50) /
                            1_000_000.0,
                    "nv12CopyRectSearchP95Ms":
                        Double(diagnostics.nv12CopyRectSearchTime.p95) /
                            1_000_000.0,
                    "nv12CopyRectLastVector":
                        diagnostics.nv12CopyRectLastVector
                ]
                metricsJSON.merge(diagnostics.nv12CopyRectStats.metrics) { $1 }
                let livenessNow = DispatchTime.now().uptimeNanoseconds
                let liveness = tbHeartbeatLivenessEvaluation(
                    supportsHeartbeatAck:
                        activeProfile?.supportsHeartbeatAck == true,
                    isConnected: isConnected,
                    nowNanoseconds: livenessNow,
                    lastReceiverActivityNanoseconds:
                        lastReceiverActivityNanoseconds,
                    lastHeartbeatSentSequence: heartbeatSequence,
                    lastHeartbeatAcknowledgedSequence:
                        lastHeartbeatAckSequence
                )
                let lastSentAgeMs = lastHeartbeatSentNanoseconds.map {
                    livenessNow >= $0 ? (livenessNow - $0) / 1_000_000 : 0
                } ?? 0
                let lastAckAgeMs = lastHeartbeatAckNanoseconds.map {
                    livenessNow >= $0 ? (livenessNow - $0) / 1_000_000 : 0
                } ?? 0
                metricsJSON["receiverLiveness"] = [
                    "supportsHeartbeatAck":
                        activeProfile?.supportsHeartbeatAck == true,
                    "lastSentSequence": heartbeatSequence,
                    "lastAckSequence": lastHeartbeatAckSequence,
                    "missedAcks": liveness.missedAcknowledgments,
                    "receiverSilenceMs":
                        liveness.receiverSilenceNanoseconds / 1_000_000,
                    "lastHeartbeatSentAgeMs": lastSentAgeMs,
                    "lastHeartbeatAckAgeMs": lastAckAgeMs,
                    "rttMs": receiverHeartbeatRTTMs ?? 0,
                    "eventLoopLagMs": receiverEventLoopLagMs ?? 0,
                    "appliedSequence": receiverAppliedSequence ?? 0,
                    "processInstanceID":
                        receiverProcessInstanceID ?? "unknown"
                ]
                if let receiver = lastReceiverMetrics {
                    metricsJSON["receiver"] = [
                        "applyFPS": receiver.fps,
                        "presentFPS": receiver.presentFPS ?? 0,
                        "networkGbps": receiver.networkGbps,
                        "packetIntervalP95Ms":
                            receiver.packetIntervalP95Ms ?? 0,
                        "applyP95Ms": receiver.applyP95Ms ?? 0,
                        "uploadP95Ms": receiver.uploadP95Ms ?? 0,
                        "presentP95Ms": receiver.presentP95Ms ?? 0,
                        "presentIntervalP95Ms":
                            receiver.presentIntervalP95Ms ?? 0,
                        "compressedPackets": receiver.compressedPackets ?? 0,
                        "decompressionFailures":
                            receiver.decompressionFailures ?? 0,
                        "rawBlockBytes": receiver.rawBlockBytes ?? 0,
                        "compressedBlockBytes":
                            receiver.compressedBlockBytes ?? 0,
                        "decompressionP95Ms":
                            receiver.decompressionP95Ms ?? 0,
                        "inverseTransformP95Ms":
                            receiver.inverseTransformP95Ms ?? 0,
                        "rawFullFrames": receiver.rawFullFrames ?? 0,
                        "rawRegionFrames": receiver.rawRegionFrames ?? 0,
                        "rawTileRunFrames":
                            receiver.rawTileRunFrames ?? 0,
                        "rawTileRuns": receiver.rawTileRuns ?? 0,
                        "rawCopyRectFrames":
                            receiver.rawCopyRectFrames ?? 0,
                        "rawCopiedTiles": receiver.rawCopiedTiles ?? 0,
                        "rawShadowCommitP95Ms":
                            receiver.rawShadowCommitP95Ms ?? 0,
                        "rawChecksumP95Ms":
                            receiver.rawChecksumP95Ms ?? 0,
                        "rawUploadPresentP95Ms":
                            receiver.rawUploadP95Ms ?? 0,
                        "invalid": receiver.bc7Invalid,
                        "renderFailures": receiver.renderFailures,
                        "keyframeRequests": receiver.keyframeRequests
                    ]
                }
                TBMetricsFileLogger.shared.append(metricsJSON)
                TBLog.connection.info(
                    "metrics captureHz=\(captureHz, format: .fixed(precision: 2), privacy: .public) sentHz=\(sentHz, format: .fixed(precision: 2), privacy: .public) completedHz=\(completedHz, format: .fixed(precision: 2), privacy: .public) pending=\(diagnostics.pending, privacy: .public) dropped=\(diagnostics.dropped, privacy: .public) queueP95Ms=\(Double(diagnostics.queueAge.p95) / 1_000_000.0, format: .fixed(precision: 2), privacy: .public) encodeMs=\(encodeMilliseconds, format: .fixed(precision: 2), privacy: .public) planMs=\(planMilliseconds, format: .fixed(precision: 2), privacy: .public) networkGbps=\(bytesPerSecond * 8.0 / 1_000_000_000.0, format: .fixed(precision: 3), privacy: .public)"
                )
                TBLog.connection.info(
                    "compression mode=\(diagnostics.bc7CompressionMode, privacy: .public) packets=\(diagnostics.bc7CompressedPackets, privacy: .public) fallback=\(diagnostics.bc7CompressionFallbacks, privacy: .public) rawBytes=\(diagnostics.bc7RawPacketBytes, privacy: .public) wireBytes=\(diagnostics.bc7WirePacketBytes, privacy: .public) splitP95Ms=\(Double(diagnostics.planeSplitTime.p95) / 1_000_000.0, format: .fixed(precision: 2), privacy: .public) compressionP95Ms=\(Double(diagnostics.compressionTime.p95) / 1_000_000.0, format: .fixed(precision: 2), privacy: .public)"
                )
            }
        }
    }

    private func resetHeartbeatLiveness() {
        heartbeatSequence = 0
        lastReceiverActivityNanoseconds = nil
        lastHeartbeatSentNanoseconds = nil
        lastHeartbeatAckNanoseconds = nil
        lastHeartbeatAckSequence = 0
        receiverProcessInstanceID = nil
        receiverEventLoopLagMs = nil
        receiverAppliedSequence = nil
        receiverHeartbeatRTTMs = nil
    }

    private func grantHeartbeatLivenessGrace() {
        guard isConnected else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        lastReceiverActivityNanoseconds = now
        lastHeartbeatAckSequence = heartbeatSequence
        lastHeartbeatAckNanoseconds = now
        TBLog.connection.info("heartbeat liveness reset after wake")
    }

    private func noteReceiverActivity() {
        lastReceiverActivityNanoseconds =
            DispatchTime.now().uptimeNanoseconds
    }

    private func handleHeartbeatAcknowledgment(_ payload: Data) {
        guard let acknowledgment = TBMonitorProtocol.decodeJSON(
            TBMonitorHeartbeat.self,
            from: payload
        ), acknowledgment.ack == true
        else {
            TBLog.connection.error(
                "Receiver heartbeat ACK payload could not be decoded"
            )
            return
        }
        guard tbShouldAcceptHeartbeatAck(
            sequence: acknowledgment.sequence,
            lastAcceptedSequence: lastHeartbeatAckSequence,
            lastSentSequence: heartbeatSequence
        ) else {
            let ackSequence = acknowledgment.sequence
            let acceptedSequence = lastHeartbeatAckSequence
            let sentSequence = heartbeatSequence
            TBLog.connection.debug(
                "ignored stale heartbeat ACK sequence=\(ackSequence, privacy: .public) accepted=\(acceptedSequence, privacy: .public) sent=\(sentSequence, privacy: .public)"
            )
            return
        }

        let nowNanoseconds = DispatchTime.now().uptimeNanoseconds
        lastHeartbeatAckSequence = acknowledgment.sequence
        lastHeartbeatAckNanoseconds = nowNanoseconds
        receiverEventLoopLagMs = acknowledgment.eventLoopLagMs
        receiverAppliedSequence = acknowledgment.appliedSequence
        if let senderTimestampMs = acknowledgment.senderTimestampMs {
            let nowMilliseconds = nowNanoseconds / 1_000_000
            receiverHeartbeatRTTMs =
                nowMilliseconds >= senderTimestampMs
                    ? nowMilliseconds - senderTimestampMs
                    : 0
        }

        if let processInstanceID = acknowledgment.processInstanceID {
            if let previous = receiverProcessInstanceID,
               previous != processInstanceID {
                recordSessionEvent(
                    "Receiver process restarted: \(previous) → " +
                    processInstanceID
                )
            } else if receiverProcessInstanceID == nil {
                recordSessionEvent(
                    "Receiver process: \(processInstanceID)"
                )
            }
            receiverProcessInstanceID = processInstanceID
        }

        let evaluation = tbHeartbeatLivenessEvaluation(
            supportsHeartbeatAck: activeProfile?.supportsHeartbeatAck == true,
            isConnected: isConnected,
            nowNanoseconds: nowNanoseconds,
            lastReceiverActivityNanoseconds: lastReceiverActivityNanoseconds,
            lastHeartbeatSentSequence: heartbeatSequence,
            lastHeartbeatAcknowledgedSequence: lastHeartbeatAckSequence
        )
        let ackSequence = acknowledgment.sequence
        let rttMs = receiverHeartbeatRTTMs ?? 0
        let loopLagMs = receiverEventLoopLagMs ?? 0
        let appliedSequence = receiverAppliedSequence ?? 0
        let missedAcknowledgments = evaluation.missedAcknowledgments
        TBLog.connection.debug(
            "heartbeat ACK sequence=\(ackSequence, privacy: .public) rttMs=\(rttMs, privacy: .public) loopLagMs=\(loopLagMs, privacy: .public) appliedSequence=\(appliedSequence, privacy: .public) missed=\(missedAcknowledgments, privacy: .public)"
        )
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatLivenessTimer?.invalidate()
        sendHeartbeat()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sendHeartbeat()
            }
        }
        heartbeatLivenessTimer = Timer.scheduledTimer(
            withTimeInterval: 1,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkHeartbeatLiveness()
            }
        }
    }

    private func checkHeartbeatLiveness() {
        guard connection != nil, isConnected else { return }
        let evaluation = tbHeartbeatLivenessEvaluation(
            supportsHeartbeatAck: activeProfile?.supportsHeartbeatAck == true,
            isConnected: isConnected,
            nowNanoseconds: DispatchTime.now().uptimeNanoseconds,
            lastReceiverActivityNanoseconds: lastReceiverActivityNanoseconds,
            lastHeartbeatSentSequence: heartbeatSequence,
            lastHeartbeatAcknowledgedSequence: lastHeartbeatAckSequence
        )
        guard evaluation.shouldTimeout else { return }
        let silenceMilliseconds =
            evaluation.receiverSilenceNanoseconds / 1_000_000
        let message =
            "Receiver heartbeat timeout: " +
            "\(evaluation.missedAcknowledgments) ACKs missed, " +
            "\(silenceMilliseconds) ms silent"
        TBLog.connection.error("\(message, privacy: .public)")
        recordSessionEvent(message)
        setStatus(.connectionClosed(message))
        stop(
            resetStatusTo: nil,
            closeContext: .liveness(
                "heartbeat_timeout",
                detail: message
            )
        )
    }

    private func startFirstFrameWatchdog() {
        // If the first encoded frame already arrived (handleFirstEncodedFrame ran
        // while startCapture was still suspended), there is nothing to watch for —
        // arming would only leave a no-op timer dangling for 4s.
        guard !pipelineHasFirstFrame else { return }
        firstFrameTimer?.invalidate()
        firstFrameTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard isStreaming, !pipelineHasFirstFrame else { return }
                let sentFrames = self.pipeline?.sentFramesSnapshot ?? 0
                TBLog.connection.error("capture: first-frame timeout preset=\(self.capturePreset.rawValue, privacy: .public) source=\(String(describing: self.captureSource), privacy: .public) connected=\(self.isConnected, privacy: .public) sentFrames=\(sentFrames, privacy: .public)")
                if self.capturePreset == .native5k || self.capturePreset == .native5k60Experimental {
                    setStatus(.hevcNoFrames)
                } else {
                    setStatus(.noFirstFrame)
                }
                stop(
                    resetStatusTo: nil,
                    closeContext: .appError(
                        "first_frame_timeout",
                        detail: "Capture produced no first frame"
                    )
                )
            }
        }
    }

    private func startConnectWatchdog() {
        connectTimeoutWorkItem?.cancel()
        
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard !self.isConnected else { return }

                let timeoutMessage: String
                switch self.language {
                case .italian: timeoutMessage = "Connessione scaduta"
                case .english: timeoutMessage = "Connection timed out"
                case .german: timeoutMessage = "Verbindungs-Zeitüberschreitung"
                case .french: timeoutMessage = "Délai de connexion dépassé"
                case .chinese: timeoutMessage = "连接超时"
                }

                // Attach where we dialed, from which interface, and the last
                // state the network stack reported — previously all of this
                // was discarded and the user saw only the bare timeout.
                let detail = TBConnectionDiagnostics.failureDetail(
                    receiverHost: self.receiverIP,
                    port: TBMonitorProtocol.port,
                    localIP: self.localInterfaceIP,
                    interfaceName: self.connectInterfaceName,
                    transport: self.transportKind.rawValue,
                    lastNetworkState: self.lastConnectionStateDetail
                )
                TBLog.connection.error("connect: timed out — \(detail, privacy: .public)")
                self.setStatus(.connectionFailed("\(timeoutMessage) — \(detail)"))
                self.stop(
                    resetStatusTo: nil,
                    closeContext: .transport(
                        "connect_timeout",
                        detail: detail
                    )
                )
            }
        }
        
        connectTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: workItem)
    }

    private func processAudio(_ sampleBuffer: CMSampleBuffer) {
        guard audioEnabled else { return }
        guard let data = audioConverter.convert(sampleBuffer: sampleBuffer) else { return }
        let packet = TBMonitorProtocol.makePacket(type: .audioFrame, payload: data)
        send(packet)
    }

    private func send(_ packet: Data) {
        connection?.send(content: packet, completion: .contentProcessed({ _ in }))
    }

    func sendInputEvent(_ event: TBMonitorInputEvent) {
        guard isConnected else { return }
        send(TBMonitorProtocol.makeInputEventPacket(event))
    }

    func updateInputControlMode() {
        guard isConnected else { return }
        sendInputControlModeUpdate()
    }

}

private final class SBAudioConverter: Sendable {
    private let converterState: LockedConverterState = LockedConverterState()

    private final class LockedConverterState: @unchecked Sendable {
        private let lock = NSLock()
        var converter: AVAudioConverter?
        var inputFormat: AVAudioFormat?
        let outputFormat: AVAudioFormat

        init() {
            var asbd = AudioStreamBasicDescription(
                mSampleRate: 48000.0,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 4,
                mFramesPerPacket: 1,
                mBytesPerFrame: 4,
                mChannelsPerFrame: 2,
                mBitsPerChannel: 16,
                mReserved: 0
            )
            self.outputFormat = AVAudioFormat(streamDescription: &asbd)!
        }

        func convert(sampleBuffer: CMSampleBuffer) -> Data? {
            lock.lock()
            defer { lock.unlock() }

            guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
            guard let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return nil }
            let inputASBD = asbdPointer.pointee

            // Recreate converter if input format changes
            if inputFormat == nil ||
               inputFormat!.streamDescription.pointee.mFormatFlags != inputASBD.mFormatFlags ||
               inputFormat!.streamDescription.pointee.mSampleRate != inputASBD.mSampleRate ||
               inputFormat!.streamDescription.pointee.mChannelsPerFrame != inputASBD.mChannelsPerFrame {
                var mutableASBD = inputASBD
                guard let inFormat = AVAudioFormat(streamDescription: &mutableASBD) else { return nil }
                self.inputFormat = inFormat
                self.converter = AVAudioConverter(from: inFormat, to: outputFormat)
            }

            guard let converter = self.converter, let inFormat = self.inputFormat else { return nil }

            let frameCount = sampleBuffer.numSamples
            guard frameCount > 0 else { return nil }
            let audioFrameCount = AVAudioFrameCount(frameCount)

            // Create input buffer
            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: audioFrameCount) else { return nil }
            inputBuffer.frameLength = audioFrameCount

            // Extract audio data from sampleBuffer into inputBuffer
            let channelCount = Int(inFormat.channelCount)
            let bufferListSize = MemoryLayout<AudioBufferList>.size + (channelCount - 1) * MemoryLayout<AudioBuffer>.size
            let bufferListRaw = UnsafeMutableRawPointer.allocate(byteCount: bufferListSize, alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { bufferListRaw.deallocate() }

            let ablPointer = bufferListRaw.assumingMemoryBound(to: AudioBufferList.self)
            var blockBuffer: CMBlockBuffer?

            let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: ablPointer,
                bufferListSize: bufferListSize,
                blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil,
                flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                blockBufferOut: &blockBuffer
            )

            guard status == noErr else { return nil }

            let firstBufferPtr = withUnsafeMutablePointer(to: &ablPointer.pointee.mBuffers) { $0 }
            let buffers = UnsafeBufferPointer(start: firstBufferPtr, count: channelCount)

            if inFormat.isInterleaved {
                assertionFailure("SBAudioConverter: unexpected interleaved input format from ScreenCaptureKit")
                return nil
            } else {
                for i in 0..<channelCount {
                    if let dest = inputBuffer.floatChannelData?[i], let src = buffers[i].mData {
                        memcpy(dest, src, Int(buffers[i].mDataByteSize))
                    }
                }
            }

            // Perform conversion to outputFormat
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: audioFrameCount) else { return nil }

            var error: NSError?
            var inputConsumed = false
            let convertStatus = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                if inputConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                inputConsumed = true
                outStatus.pointee = .haveData
                return inputBuffer
            }

            if convertStatus == .error || error != nil {
                return nil
            }

            guard let channels = outputBuffer.int16ChannelData else { return nil }
            let dataSize = Int(outputBuffer.frameLength) * 4 // 2 channels * 2 bytes = 4 bytes per frame
            let rawPointer = UnsafeRawPointer(channels.pointee)
            return Data(bytes: rawPointer, count: dataSize)
        }
    }

    func convert(sampleBuffer: CMSampleBuffer) -> Data? {
        return converterState.convert(sampleBuffer: sampleBuffer)
    }
}
