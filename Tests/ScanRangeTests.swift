import XCTest

final class ScanRangeTests: XCTestCase {
    func testSlash24ComputesFullHostRange() throws {
        let range = try XCTUnwrap(
            ScanRange.compute(interfaceName: "en0", localIP: "192.168.0.16", subnetMask: "255.255.255.0")
        )
        XCTAssertEqual(range.targets.count, 254)
        XCTAssertEqual(range.targets.first, "192.168.0.1")
        XCTAssertEqual(range.targets.last, "192.168.0.254")
        XCTAssertFalse(range.isTruncated)
        XCTAssertEqual(range.interfaceName, "en0")
        XCTAssertEqual(range.localIP, "192.168.0.16")
    }

    func testSlash25UpperHalfOffsetsNetworkPart() throws {
        // mask4 = 128, host .200 → net4 = 128 → .129-.254 (126 アドレス)
        let range = try XCTUnwrap(
            ScanRange.compute(interfaceName: "en0", localIP: "10.0.1.200", subnetMask: "255.255.255.128")
        )
        XCTAssertEqual(range.targets.count, 126)
        XCTAssertEqual(range.targets.first, "10.0.1.129")
        XCTAssertEqual(range.targets.last, "10.0.1.254")
        XCTAssertFalse(range.isTruncated)
    }

    func testSlash25LowerHalf() throws {
        let range = try XCTUnwrap(
            ScanRange.compute(interfaceName: "en0", localIP: "10.0.1.5", subnetMask: "255.255.255.128")
        )
        XCTAssertEqual(range.targets.count, 126)
        XCTAssertEqual(range.targets.first, "10.0.1.1")
        XCTAssertEqual(range.targets.last, "10.0.1.126")
    }

    func testWideMaskTruncatesTo254AndFlags() throws {
        let range = try XCTUnwrap(
            ScanRange.compute(interfaceName: "en1", localIP: "172.16.4.7", subnetMask: "255.255.0.0")
        )
        XCTAssertEqual(range.targets.count, 254)
        XCTAssertEqual(range.targets.first, "172.16.4.1")
        XCTAssertEqual(range.targets.last, "172.16.4.254")
        XCTAssertTrue(range.isTruncated)
    }

    func testInvalidInputsReturnNil() {
        XCTAssertNil(ScanRange.compute(interfaceName: "en0", localIP: "abc", subnetMask: "255.255.255.0"))
        XCTAssertNil(ScanRange.compute(interfaceName: "en0", localIP: "192.168.0.16", subnetMask: "255.255.255"))
        XCTAssertNil(ScanRange.compute(interfaceName: "en0", localIP: "300.168.0.16", subnetMask: "255.255.255.0"))
    }
}

final class IPv4Tests: XCTestCase {
    func testValidAddresses() {
        XCTAssertTrue(IPv4.isValid("192.168.0.1"))
        XCTAssertTrue(IPv4.isValid("0.0.0.0"))
        XCTAssertTrue(IPv4.isValid("255.255.255.255"))
    }

    func testInvalidAddresses() {
        XCTAssertFalse(IPv4.isValid("abc"))
        XCTAssertFalse(IPv4.isValid(""))
        XCTAssertFalse(IPv4.isValid("1.2.3"))
        XCTAssertFalse(IPv4.isValid("1.2.3.4.5"))
        XCTAssertFalse(IPv4.isValid("256.1.1.1"))
        XCTAssertFalse(IPv4.isValid("1.2.3.x"))
        XCTAssertFalse(IPv4.isValid("1.2.3."))
        XCTAssertFalse(IPv4.isValid(" 1.2.3.4"))
    }
}
