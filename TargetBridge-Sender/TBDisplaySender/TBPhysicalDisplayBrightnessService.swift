import AppKit
import CoreGraphics
import Foundation
import OSLog

enum TBPhysicalDisplayBrightnessAvailability: Equatable, Sendable {
    case native
    case ddc
    case unsupported
    case error(String)

    var isSupported: Bool {
        switch self {
        case .native, .ddc:
            return true
        case .unsupported, .error:
            return false
        }
    }
}

struct TBPhysicalDisplayBrightnessDevice: Identifiable, Equatable, Sendable {
    let id: String
    let displayID: CGDirectDisplayID
    let name: String
    let isBuiltIn: Bool
    var brightness: Double
    var confirmedBrightness: Double
    var availability: TBPhysicalDisplayBrightnessAvailability
    var isWriting: Bool
}

enum TBPhysicalDisplayDiscovery {
    static func isPhysicalDisplay(
        vendor: UInt32,
        isVirtual: Bool,
        isAirPlay: Bool
    ) -> Bool {
        vendor != 0xEEEE && !isVirtual && !isAirPlay
    }

    static func stableID(
        vendor: UInt32,
        model: UInt32,
        serial: UInt32,
        location: String,
        displayID: CGDirectDisplayID
    ) -> String {
        if serial != 0 {
            return "\(vendor)-\(model)-\(serial)"
        }
        if !location.isEmpty {
            return "\(vendor)-\(model)-\(location)"
        }
        return "\(vendor)-\(model)-display-\(displayID)"
    }
}

protocol TBPhysicalDisplayBrightnessBackend: AnyObject, Sendable {
    func readBrightness() -> Double?
    func writeBrightness(_ brightness: Double) -> Bool
}

final class TBNativeDisplayBrightnessBackend:
    TBPhysicalDisplayBrightnessBackend,
    @unchecked Sendable
{
    private let displayID: CGDirectDisplayID

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
    }

    func readBrightness() -> Double? {
        var value: Float = -1
        guard DisplayServicesGetBrightness(displayID, &value) == 0,
              value >= 0,
              value <= 1
        else {
            return nil
        }
        return Double(value)
    }

    func writeBrightness(_ brightness: Double) -> Bool {
        let value = Float(min(max(brightness, 0), 1))
        return DisplayServicesSetBrightness(displayID, value) == 0
    }
}

#if arch(arm64)
final class TBDDCDisplayBrightnessBackend:
    TBPhysicalDisplayBrightnessBackend,
    @unchecked Sendable
{
    private let ddc: TBArm64DDCService

    init(ddc: TBArm64DDCService) {
        self.ddc = ddc
    }

    func readBrightness() -> Double? {
        ddc.readBrightness()
    }

    func writeBrightness(_ brightness: Double) -> Bool {
        ddc.writeBrightness(brightness)
    }
}
#endif

final class TBPhysicalDisplayBrightnessWriter: @unchecked Sendable {
    private let backend: any TBPhysicalDisplayBrightnessBackend
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var generation = 0

    init(
        id: String,
        backend: any TBPhysicalDisplayBrightnessBackend
    ) {
        self.backend = backend
        queue = DispatchQueue(
            label: "com.targetbridge.sender.brightness.\(id)",
            qos: .userInitiated
        )
    }

    func schedule(
        brightness: Double,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        lock.lock()
        generation &+= 1
        let scheduledGeneration = generation
        lock.unlock()

        queue.asyncAfter(deadline: .now() + 0.05) { [self] in
            lock.lock()
            let isLatest = generation == scheduledGeneration
            lock.unlock()
            guard isLatest else { return }

            let success = backend.writeBrightness(brightness)
            completion(success)
        }
    }

    func cancel() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }
}

private struct TBPhysicalDisplayProbe: @unchecked Sendable {
    let device: TBPhysicalDisplayBrightnessDevice
    let backend: (any TBPhysicalDisplayBrightnessBackend)?
}

@MainActor
final class TBPhysicalDisplayBrightnessService: ObservableObject {
    static let shared = TBPhysicalDisplayBrightnessService()
    private static let log = Logger(
        subsystem: "com.targetbridge.sender",
        category: "brightness"
    )

    @Published private(set) var displays: [TBPhysicalDisplayBrightnessDevice] = []
    @Published private(set) var isRefreshing = false

    private var writers: [String: TBPhysicalDisplayBrightnessWriter] = [:]
    private let probeQueue = DispatchQueue(
        label: "com.targetbridge.sender.brightness.probe",
        qos: .utility
    )
    private var refreshGeneration = 0
    private var wakeObserver: NSObjectProtocol?

    nonisolated(unsafe) private static let displayReconfigurationCallback:
        CGDisplayReconfigurationCallBack = { _, flags, userInfo in
            guard !flags.contains(.beginConfigurationFlag),
                  let userInfo
            else {
                return
            }
            let service = Unmanaged<TBPhysicalDisplayBrightnessService>
                .fromOpaque(userInfo)
                .takeUnretainedValue()
            Task { @MainActor in
                service.refresh()
            }
        }

    private init() {
        CGDisplayRegisterReconfigurationCallback(
            Self.displayReconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        refresh()
    }

    func refresh() {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        isRefreshing = true

        probeQueue.async {
            let probes = Self.probeDisplays()
            Task { @MainActor [weak self] in
                guard let self, generation == refreshGeneration else { return }
                apply(probes)
            }
        }
    }

    func setBrightness(_ brightness: Double, for id: String) {
        let clamped = min(max(brightness, 0), 1)
        guard let index = displays.firstIndex(where: { $0.id == id }),
              displays[index].availability.isSupported,
              let writer = writers[id]
        else {
            return
        }

        displays[index].brightness = clamped
        displays[index].isWriting = true
        writer.schedule(brightness: clamped) { [weak self] success in
            Task { @MainActor [weak self] in
                guard let self,
                      writers[id] === writer,
                      let currentIndex = displays.firstIndex(
                        where: { $0.id == id }
                      )
                else {
                    return
                }
                displays[currentIndex].isWriting = false
                if success {
                    displays[currentIndex].confirmedBrightness = clamped
                    Self.log.info(
                        "write succeeded id=\(id, privacy: .public) value=\(Int((clamped * 100).rounded()), privacy: .public)%"
                    )
                } else {
                    displays[currentIndex].brightness =
                        displays[currentIndex].confirmedBrightness
                    displays[currentIndex].availability =
                        .error("Hardware brightness write failed")
                    Self.log.error(
                        "write failed id=\(id, privacy: .public)"
                    )
                }
            }
        }
    }

    private func apply(_ probes: [TBPhysicalDisplayProbe]) {
        for writer in writers.values {
            writer.cancel()
        }
        writers.removeAll(keepingCapacity: true)

        displays = probes.map(\.device)
        for probe in probes {
            Self.log.info(
                "detected id=\(probe.device.id, privacy: .public) displayID=\(probe.device.displayID, privacy: .public) name=\(probe.device.name, privacy: .public) backend=\(Self.backendDescription(probe.device.availability), privacy: .public) brightness=\(Int((probe.device.brightness * 100).rounded()), privacy: .public)%"
            )
            guard let backend = probe.backend else { continue }
            writers[probe.device.id] = TBPhysicalDisplayBrightnessWriter(
                id: probe.device.id,
                backend: backend
            )
        }
        isRefreshing = false
    }

    nonisolated private static func backendDescription(
        _ availability: TBPhysicalDisplayBrightnessAvailability
    ) -> String {
        switch availability {
        case .native:
            return "native"
        case .ddc:
            return "ddc"
        case .unsupported:
            return "unsupported"
        case .error:
            return "error"
        }
    }

    nonisolated private static func probeDisplays() -> [TBPhysicalDisplayProbe] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success,
              count > 0
        else {
            return []
        }
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(
            count,
            &displayIDs,
            &count
        ) == .success else {
            return []
        }
        displayIDs = Array(displayIDs.prefix(Int(count))).filter { $0 != 0 }

        let physicalIDs = displayIDs.filter(isPhysicalDisplay)
        let externalIDs = physicalIDs.filter { CGDisplayIsBuiltin($0) == 0 }

        #if arch(arm64)
        let armServices = TBArm64DDCService.matches(displayIDs: externalIDs)
        #endif

        return physicalIDs.map { displayID in
            let info = displayInfo(displayID)
            let vendor = CGDisplayVendorNumber(displayID)
            let model = CGDisplayModelNumber(displayID)
            let serial = CGDisplaySerialNumber(displayID)
            let id = TBPhysicalDisplayDiscovery.stableID(
                vendor: vendor,
                model: model,
                serial: serial,
                location: info.location,
                displayID: displayID
            )
            let isBuiltIn = CGDisplayIsBuiltin(displayID) != 0

            let nativeBackend = TBNativeDisplayBrightnessBackend(
                displayID: displayID
            )
            if let brightness = nativeBackend.readBrightness() {
                return TBPhysicalDisplayProbe(
                    device: TBPhysicalDisplayBrightnessDevice(
                        id: id,
                        displayID: displayID,
                        name: info.name,
                        isBuiltIn: isBuiltIn,
                        brightness: brightness,
                        confirmedBrightness: brightness,
                        availability: .native,
                        isWriting: false
                    ),
                    backend: nativeBackend
                )
            }

            #if arch(arm64)
            if let service = armServices[displayID],
               let values = TBArm64DDCService.read(
                service: service,
                command: TBPhysicalDisplayDDC.brightnessCommand
               ),
               let brightness = TBPhysicalDisplayDDC.normalizedBrightness(
                current: values.current,
                maximum: values.maximum
               ) {
                let ddc = TBArm64DDCService(
                    service: service,
                    maximumBrightness: values.maximum
                )
                return TBPhysicalDisplayProbe(
                    device: TBPhysicalDisplayBrightnessDevice(
                        id: id,
                        displayID: displayID,
                        name: info.name,
                        isBuiltIn: false,
                        brightness: brightness,
                        confirmedBrightness: brightness,
                        availability: .ddc,
                        isWriting: false
                    ),
                    backend: TBDDCDisplayBrightnessBackend(ddc: ddc)
                )
            }
            #endif

            return TBPhysicalDisplayProbe(
                device: TBPhysicalDisplayBrightnessDevice(
                    id: id,
                    displayID: displayID,
                    name: info.name,
                    isBuiltIn: isBuiltIn,
                    brightness: 1,
                    confirmedBrightness: 1,
                    availability: .unsupported,
                    isWriting: false
                ),
                backend: nil
            )
        }
        .sorted {
            if $0.device.isBuiltIn != $1.device.isBuiltIn {
                return $0.device.isBuiltIn
            }
            return $0.device.name.localizedStandardCompare(
                $1.device.name
            ) == .orderedAscending
        }
    }

    nonisolated private static func isPhysicalDisplay(
        _ displayID: CGDirectDisplayID
    ) -> Bool {
        let info = displayInfo(displayID)
        return TBPhysicalDisplayDiscovery.isPhysicalDisplay(
            vendor: CGDisplayVendorNumber(displayID),
            isVirtual: info.isVirtual,
            isAirPlay: info.isAirPlay
        )
    }

    nonisolated private static func displayInfo(
        _ displayID: CGDirectDisplayID
    ) -> (
        name: String,
        location: String,
        isVirtual: Bool,
        isAirPlay: Bool
    ) {
        let dictionary = CoreDisplay_DisplayCreateInfoDictionary(displayID)?
            .takeRetainedValue() as NSDictionary?
        let names = dictionary?["DisplayProductName"] as? [String: String]
        let name =
            names?[Locale.current.identifier] ??
            names?["en_US"] ??
            names?.first?.value ??
            "Display \(displayID)"
        return (
            name,
            dictionary?[kIODisplayLocationKey] as? String ?? "",
            dictionary?["kCGDisplayIsVirtualDevice"] as? Bool ?? false,
            dictionary?["kCGDisplayIsAirPlay"] as? Bool ?? false
        )
    }
}
