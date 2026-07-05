import XCTest

final class SysModeTests: XCTestCase {
    func testKnownIndices() {
        XCTAssertEqual(SysMode.name(for: 0), "ブリッジ")
        XCTAssertEqual(SysMode.name(for: 1), "PPPoEルータ")
        XCTAssertEqual(SysMode.name(for: 2), "ローカルルータ")
        XCTAssertEqual(SysMode.name(for: 3), "無線LAN子機")
        XCTAssertEqual(SysMode.name(for: 4), "無線LAN中継機")
        XCTAssertEqual(SysMode.name(for: 5), "MAP-E")
        XCTAssertEqual(SysMode.name(for: 6), "464XLAT")
        XCTAssertEqual(SysMode.name(for: 7), "DS-Lite")
        XCTAssertEqual(SysMode.name(for: 8), "固定IP1")
        XCTAssertEqual(SysMode.name(for: 9), "複数固定IP")
        XCTAssertEqual(SysMode.name(for: 10), "メッシュ中継機")
    }

    func testOutOfRangeIndexFallsBackToDash() {
        XCTAssertEqual(SysMode.name(for: 11), "-")
        XCTAssertEqual(SysMode.name(for: 255), "-")
        XCTAssertEqual(SysMode.name(for: -1), "-")
    }

    func testNilIndexFallsBackToDash() {
        XCTAssertEqual(SysMode.name(for: nil), "-")
    }
}
