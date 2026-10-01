import XCTest
@testable import TargetBridge

final class TBPhysicalDisplayBrightnessTests: XCTestCase {
    func testPhysicalDisplayFilterRejectsVirtualAndTargetBridgeDisplays() {
        XCTAssertTrue(
            TBPhysicalDisplayDiscovery.isPhysicalDisplay(
                vendor: 0x10AC,
                isVirtual: false,
                isAirPlay: false
            )
        )
        XCTAssertFalse(
            TBPhysicalDisplayDiscovery.isPhysicalDisplay(
                vendor: 0xEEEE,
                isVirtual: false,
                isAirPlay: false
            )
        )
        XCTAssertFalse(
            TBPhysicalDisplayDiscovery.isPhysicalDisplay(
                vendor: 0x10AC,
                isVirtual: true,
                isAirPlay: false
            )
        )
        XCTAssertFalse(
            TBPhysicalDisplayDiscovery.isPhysicalDisplay(
                vendor: 0x10AC,
                isVirtual: false,
                isAirPlay: true
            )
        )
    }

    func testStableIdentityPrefersSerialThenLocation() {
        XCTAssertEqual(
            TBPhysicalDisplayDiscovery.stableID(
                vendor: 1,
                model: 2,
                serial: 3,
                location: "ignored",
                displayID: 99
            ),
            "1-2-3"
        )
        XCTAssertEqual(
            TBPhysicalDisplayDiscovery.stableID(
                vendor: 1,
                model: 2,
                serial: 0,
                location: "port-4",
                displayID: 99
            ),
            "1-2-port-4"
        )
    }

    func testDDCBrightnessConversionClampsAndNormalizes() {
        XCTAssertEqual(
            TBPhysicalDisplayDDC.normalizedBrightness(
                current: 75,
                maximum: 100
            ),
            0.75
        )
        XCTAssertNil(
            TBPhysicalDisplayDDC.normalizedBrightness(
                current: 1,
                maximum: 0
            )
        )
        XCTAssertEqual(
            TBPhysicalDisplayDDC.ddcValue(
                brightness: -1,
                maximum: 100
            ),
            0
        )
        XCTAssertEqual(
            TBPhysicalDisplayDDC.ddcValue(
                brightness: 2,
                maximum: 100
            ),
            100
        )
    }

    func testDDCWritePacketHasValidChecksum() {
        let packet = TBPhysicalDisplayDDC.writePacket(
            command: TBPhysicalDisplayDDC.brightnessCommand,
            value: 50
        )
        XCTAssertEqual(packet.count, 7)
        XCTAssertEqual(packet[0...5].reduce(UInt8(0x6E), ^), packet[6])
    }

    func testArmPacketHasValidLengthAndChecksum() {
        let packet = TBPhysicalDisplayDDC.armPacket(
            payload: [TBPhysicalDisplayDDC.brightnessCommand, 0, 50]
        )
        XCTAssertEqual(packet[0], 0x84)
        XCTAssertEqual(packet[1], 3)
        XCTAssertEqual(
            packet.dropLast().reduce(UInt8(0x6E ^ 0x51), ^),
            packet.last
        )
    }

    func testWriterCoalescesToLatestBrightness() {
        let backend = MockBrightnessBackend()
        let writer = TBPhysicalDisplayBrightnessWriter(
            id: "display",
            backend: backend
        )
        let completed = expectation(description: "latest write completed")

        writer.schedule(brightness: 0.2) { _ in
            XCTFail("superseded write must not complete")
        }
        writer.schedule(brightness: 0.8) { success in
            XCTAssertTrue(success)
            completed.fulfill()
        }

        wait(for: [completed], timeout: 1)
        XCTAssertEqual(backend.values, [0.8])
    }

    func testWriterCancellationPreventsPendingHardwareWrite() {
        let backend = MockBrightnessBackend()
        let writer = TBPhysicalDisplayBrightnessWriter(
            id: "display",
            backend: backend
        )
        let completed = expectation(description: "cancelled write")
        completed.isInverted = true

        writer.schedule(brightness: 0.6) { _ in
            completed.fulfill()
        }
        writer.cancel()

        wait(for: [completed], timeout: 0.15)
        XCTAssertTrue(backend.values.isEmpty)
    }

    @MainActor
    func testMenuSliderUpdatesValueWithoutClosingMenuActionPath() {
        let device = TBPhysicalDisplayBrightnessDevice(
            id: "display",
            displayID: 1,
            name: "Color LCD",
            isBuiltIn: true,
            brightness: 0.41,
            confirmedBrightness: 0.41,
            availability: .native,
            isWriting: false
        )
        var received: Double?
        let view = TBMenuBrightnessSliderView(device: device) {
            received = $0
        }

        XCTAssertTrue(view.sliderEnabledForTesting)
        XCTAssertEqual(view.percentageTextForTesting, "41%")

        view.setBrightnessForTesting(0.73)

        XCTAssertEqual(received ?? -1, 0.73, accuracy: 0.0001)
        XCTAssertEqual(view.percentageTextForTesting, "73%")
    }

    @MainActor
    func testMenuSliderDisablesUnsupportedHardware() {
        let device = TBPhysicalDisplayBrightnessDevice(
            id: "unsupported",
            displayID: 2,
            name: "Unsupported",
            isBuiltIn: false,
            brightness: 1,
            confirmedBrightness: 1,
            availability: .unsupported,
            isWriting: false
        )
        let view = TBMenuBrightnessSliderView(device: device) { _ in
            XCTFail("disabled slider must not emit hardware writes")
        }

        XCTAssertFalse(view.sliderEnabledForTesting)
        XCTAssertEqual(view.percentageTextForTesting, "100%")
    }
}

private final class MockBrightnessBackend:
    TBPhysicalDisplayBrightnessBackend,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedValues: [Double] = []

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return storedValues
    }

    func readBrightness() -> Double? {
        values.last
    }

    func writeBrightness(_ brightness: Double) -> Bool {
        lock.lock()
        storedValues.append(brightness)
        lock.unlock()
        return true
    }
}
