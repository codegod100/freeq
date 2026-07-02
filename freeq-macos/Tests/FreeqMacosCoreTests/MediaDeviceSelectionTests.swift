import XCTest
@testable import FreeqMacosCore

/// Tests for device-picker policy: which capture device to use given the
/// user's sticky preference and the currently-present hardware (hotplug).
final class MediaDeviceSelectionTests: XCTestCase {

    private let builtin = MediaDevice(id: "builtin-mic", name: "MacBook Pro Microphone")
    private let usb = MediaDevice(id: "usb-abc", name: "Shure MV7")

    func testNoPreferenceUsesSystemDefault() {
        XCTAssertNil(MediaDeviceSelection.resolve(preferredId: nil, devices: [builtin, usb]))
    }

    func testPreferredDevicePresentIsChosen() {
        XCTAssertEqual(
            MediaDeviceSelection.resolve(preferredId: "usb-abc", devices: [builtin, usb]),
            usb
        )
    }

    func testPreferredDeviceUnpluggedFallsBackToSystemDefault() {
        XCTAssertNil(MediaDeviceSelection.resolve(preferredId: "usb-abc", devices: [builtin]))
    }

    func testEmptyDeviceListFallsBackToSystemDefault() {
        XCTAssertNil(MediaDeviceSelection.resolve(preferredId: "usb-abc", devices: []))
    }

    func testDisplayListDedupesById() {
        let dup = MediaDevice(id: "usb-abc", name: "Shure MV7 (again)")
        let list = MediaDeviceSelection.displayList([builtin, usb, dup])
        XCTAssertEqual(list, [builtin, usb], "same UID must not appear twice")
    }

    func testDisplayListPreservesDiscoveryOrder() {
        let list = MediaDeviceSelection.displayList([usb, builtin])
        XCTAssertEqual(list, [usb, builtin])
    }

    func testDisplayListDropsBlankIds() {
        let ghost = MediaDevice(id: "", name: "Initializing…")
        XCTAssertEqual(MediaDeviceSelection.displayList([ghost, builtin]), [builtin])
    }
}
