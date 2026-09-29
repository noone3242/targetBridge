// Portions adapted from MonitorControl (https://github.com/MonitorControl/MonitorControl).
// Copyright © 2017 MonitorControl contributors.
// Licensed under the MIT License; see ThirdPartyNotices/MonitorControl-MIT.txt.

import CoreGraphics
import Foundation
import IOKit

enum TBPhysicalDisplayDDC {
    static let brightnessCommand: UInt8 = 0x10

    static func writePacket(command: UInt8, value: UInt16) -> [UInt8] {
        var packet: [UInt8] = [
            0x51,
            0x84,
            0x03,
            command,
            UInt8(value >> 8),
            UInt8(value & 0xff),
            0
        ]
        packet[6] = packet[0...5].reduce(UInt8(0x6e), ^)
        return packet
    }

    static func armPacket(payload: [UInt8]) -> [UInt8] {
        var packet = [
            UInt8(0x80 | (payload.count + 1)),
            UInt8(payload.count)
        ] + payload + [0]
        let checksumSeed: UInt8 =
            payload.count == 1 ? 0x6e : (0x6e ^ 0x51)
        packet[packet.count - 1] = packet.dropLast().reduce(
            checksumSeed,
            ^
        )
        return packet
    }

    static func normalizedBrightness(current: UInt16, maximum: UInt16) -> Double? {
        guard maximum > 0, current <= maximum else { return nil }
        return Double(current) / Double(maximum)
    }

    static func ddcValue(brightness: Double, maximum: UInt16) -> UInt16 {
        let clamped = min(max(brightness, 0), 1)
        return UInt16((clamped * Double(maximum)).rounded())
    }
}

#if arch(arm64)
final class TBArm64DDCService: @unchecked Sendable {
    static let sevenBitAddress: UInt8 = 0x37
    static let dataAddress: UInt8 = 0x51

    struct RegistryService {
        var edidUUID = ""
        var productName = ""
        var serialNumber: Int64 = 0
        var ioDisplayLocation = ""
        var service: IOAVService?
        var serviceLocation = 0
    }

    struct Match {
        let displayID: CGDirectDisplayID
        let service: IOAVService
        let serviceLocation: Int
        let score: Int
    }

    let service: IOAVService
    private(set) var maximumBrightness: UInt16

    init(service: IOAVService, maximumBrightness: UInt16) {
        self.service = service
        self.maximumBrightness = maximumBrightness
    }

    func readBrightness() -> Double? {
        guard let values = Self.read(
            service: service,
            command: TBPhysicalDisplayDDC.brightnessCommand
        ) else {
            return nil
        }
        maximumBrightness = values.maximum
        return TBPhysicalDisplayDDC.normalizedBrightness(
            current: values.current,
            maximum: values.maximum
        )
    }

    func writeBrightness(_ brightness: Double) -> Bool {
        let value = TBPhysicalDisplayDDC.ddcValue(
            brightness: brightness,
            maximum: maximumBrightness
        )
        return Self.write(
            service: service,
            command: TBPhysicalDisplayDDC.brightnessCommand,
            value: value
        )
    }

    static func matches(
        displayIDs: [CGDirectDisplayID]
    ) -> [CGDirectDisplayID: IOAVService] {
        let registryServices = registryServices()
        var candidates: [(Match, RegistryService)] = []

        for displayID in displayIDs {
            for registryService in registryServices {
                guard let service = registryService.service else { continue }
                let score = matchScore(
                    displayID: displayID,
                    registryService: registryService
                )
                guard score > 0 else { continue }
                candidates.append((
                    Match(
                        displayID: displayID,
                        service: service,
                        serviceLocation: registryService.serviceLocation,
                        score: score
                    ),
                    registryService
                ))
            }
        }

        var result: [CGDirectDisplayID: IOAVService] = [:]
        var usedDisplays = Set<CGDirectDisplayID>()
        var usedLocations = Set<Int>()
        for candidate in candidates.sorted(by: {
            $0.0.score > $1.0.score
        }) {
            let match = candidate.0
            guard !usedDisplays.contains(match.displayID),
                  !usedLocations.contains(match.serviceLocation)
            else {
                continue
            }
            result[match.displayID] = match.service
            usedDisplays.insert(match.displayID)
            usedLocations.insert(match.serviceLocation)
        }
        return result
    }

    static func read(
        service: IOAVService,
        command: UInt8
    ) -> (current: UInt16, maximum: UInt16)? {
        var request = TBPhysicalDisplayDDC.armPacket(payload: [command])
        var reply = [UInt8](repeating: 0, count: 11)
        guard communicate(
            service: service,
            request: &request,
            reply: &reply
        ) else {
            return nil
        }
        guard reply.count >= 11,
              reply[2] == 0x02,
              reply[3] == 0x00
        else {
            return nil
        }
        let maximum = UInt16(reply[6]) << 8 | UInt16(reply[7])
        let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
        guard maximum > 0, current <= maximum else { return nil }
        return (current, maximum)
    }

    static func write(
        service: IOAVService,
        command: UInt8,
        value: UInt16
    ) -> Bool {
        var request = TBPhysicalDisplayDDC.armPacket(payload: [
            command,
            UInt8(value >> 8),
            UInt8(value & 0xff)
        ])
        var noReply: [UInt8] = []
        return communicate(
            service: service,
            request: &request,
            reply: &noReply
        )
    }

    private static func communicate(
        service: IOAVService,
        request: inout [UInt8],
        reply: inout [UInt8]
    ) -> Bool {
        for _ in 0..<3 {
            usleep(10_000)
            let writeResult = request.withUnsafeMutableBytes { bytes in
                IOAVServiceWriteI2C(
                    service,
                    UInt32(sevenBitAddress),
                    UInt32(dataAddress),
                    bytes.baseAddress,
                    UInt32(bytes.count)
                )
            }
            guard writeResult == KERN_SUCCESS else {
                usleep(20_000)
                continue
            }
            if reply.isEmpty {
                return true
            }
            usleep(50_000)
            let readResult = reply.withUnsafeMutableBytes { bytes in
                IOAVServiceReadI2C(
                    service,
                    UInt32(sevenBitAddress),
                    0,
                    bytes.baseAddress,
                    UInt32(bytes.count)
                )
            }
            guard readResult == KERN_SUCCESS,
                  reply.count >= 2,
                  reply.dropLast().reduce(UInt8(0x50), ^) == reply.last
            else {
                usleep(20_000)
                continue
            }
            return true
        }
        return false
    }

    private static func registryServices() -> [RegistryService] {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != IO_OBJECT_NULL else { return [] }
        defer { IOObjectRelease(root) }

        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(
            root,
            kIOServicePlane,
            IOOptionBits(kIORegistryIterateRecursively),
            &iterator
        ) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var services: [RegistryService] = []
        var current = RegistryService()
        var serviceLocation = 0

        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != IO_OBJECT_NULL else { break }
            defer { IOObjectRelease(entry) }

            var nameBuffer = [CChar](repeating: 0, count: 128)
            guard IORegistryEntryGetName(entry, &nameBuffer) == KERN_SUCCESS
            else {
                continue
            }
            let name = String(
                decoding: nameBuffer.prefix { $0 != 0 }.map {
                    UInt8(bitPattern: $0)
                },
                as: UTF8.self
            )

            if name.contains("AppleCLCD2") ||
                name.contains("IOMobileFramebufferShim") {
                current = displayProperties(entry: entry)
                serviceLocation += 1
                current.serviceLocation = serviceLocation
                continue
            }

            if name == "DCPAVServiceProxy" {
                guard let location = property(
                    entry: entry,
                    key: "Location"
                ) as? String,
                location == "External",
                let unmanagedService = IOAVServiceCreateWithService(
                    kCFAllocatorDefault,
                    entry
                )
                else {
                    continue
                }
                let service = unmanagedService.takeRetainedValue() as IOAVService
                current.service = service
                services.append(current)
            }
        }
        return services
    }

    private static func displayProperties(
        entry: io_service_t
    ) -> RegistryService {
        var result = RegistryService()
        result.edidUUID =
            property(entry: entry, key: "EDID UUID") as? String ?? ""

        var path = [CChar](
            repeating: 0,
            count: MemoryLayout<io_string_t>.size
        )
        if IORegistryEntryGetPath(
            entry,
            kIOServicePlane,
            &path
        ) == KERN_SUCCESS {
            result.ioDisplayLocation = String(
                decoding: path.prefix { $0 != 0 }.map {
                    UInt8(bitPattern: $0)
                },
                as: UTF8.self
            )
        }

        if let attributes = property(
            entry: entry,
            key: "DisplayAttributes"
        ) as? NSDictionary,
        let product = attributes["ProductAttributes"] as? NSDictionary {
            result.productName = product["ProductName"] as? String ?? ""
            result.serialNumber = product["SerialNumber"] as? Int64 ?? 0
        }
        return result
    }

    private static func property(
        entry: io_service_t,
        key: String
    ) -> Any? {
        guard let unmanaged = IORegistryEntryCreateCFProperty(
            entry,
            key as CFString,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively)
        ) else {
            return nil
        }
        return unmanaged.takeRetainedValue()
    }

    private static func matchScore(
        displayID: CGDirectDisplayID,
        registryService: RegistryService
    ) -> Int {
        guard let unmanagedInfo = CoreDisplay_DisplayCreateInfoDictionary(
            displayID
        ) else {
            return 0
        }
        let info = unmanagedInfo.takeRetainedValue() as NSDictionary

        var score = 0
        if let location = info[kIODisplayLocationKey] as? String,
           !registryService.ioDisplayLocation.isEmpty,
           location == registryService.ioDisplayLocation {
            score += 10
        }
        if let names = info["DisplayProductName"] as? [String: String],
           let name = names["en_US"] ?? names.first?.value,
           !registryService.productName.isEmpty,
           name.caseInsensitiveCompare(registryService.productName) == .orderedSame {
            score += 3
        }
        if let serial = info[kDisplaySerialNumber] as? Int64,
           registryService.serialNumber != 0,
           serial == registryService.serialNumber {
            score += 3
        }

        if let vendor = info[kDisplayVendorID] as? Int64,
           let product = info[kDisplayProductID] as? Int64,
           !registryService.edidUUID.isEmpty {
            let vendorText = String(
                format: "%04X",
                UInt16(clamping: vendor)
            )
            let productValue = UInt16(clamping: product)
            let productText = String(
                format: "%02X%02X",
                UInt8(productValue & 0xff),
                UInt8(productValue >> 8)
            )
            if registryService.edidUUID.hasPrefix(vendorText) {
                score += 1
            }
            if registryService.edidUUID.dropFirst(4).hasPrefix(productText) {
                score += 1
            }
        }
        return score
    }
}
#endif
