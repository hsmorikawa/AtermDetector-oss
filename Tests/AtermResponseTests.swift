import XCTest

final class AtermResponseTests: XCTestCase {
    // MARK: - productName

    func testProductNameParsesValidResponse() {
        XCTAssertEqual(AtermResponse.productName(from: "PRODUCT_NAME=WX5400HP"), "WX5400HP")
    }

    func testProductNameStripsCRLF() {
        XCTAssertEqual(AtermResponse.productName(from: "PRODUCT_NAME=WG2600HS\r\n"), "WG2600HS")
    }

    func testProductNameRejectsEmptyValue() {
        XCTAssertNil(AtermResponse.productName(from: "PRODUCT_NAME="))
    }

    func testProductNameRejectsNonMatchingBody() {
        XCTAssertNil(AtermResponse.productName(from: "<html>Not Found</html>"))
        XCTAssertNil(AtermResponse.productName(from: ""))
    }

    func testProductNameRequiresPrefixMatch() {
        XCTAssertNil(AtermResponse.productName(from: "X_PRODUCT_NAME=WX5400HP"))
    }

    // MARK: - sysModeIndex

    func testSysModeIndexParsesValidResponse() {
        XCTAssertEqual(AtermResponse.sysModeIndex(from: "SYS_MODE=2"), 2)
        XCTAssertEqual(AtermResponse.sysModeIndex(from: "SYS_MODE=0\r\n"), 0)
    }

    func testSysModeIndexAllowsOutOfTableValues() {
        // 範囲判定は SysMode 側の責務。パースは整数ならそのまま返す
        XCTAssertEqual(AtermResponse.sysModeIndex(from: "SYS_MODE=12"), 12)
    }

    func testSysModeIndexRejectsNonInteger() {
        XCTAssertNil(AtermResponse.sysModeIndex(from: "SYS_MODE=abc"))
        XCTAssertNil(AtermResponse.sysModeIndex(from: "SYS_MODE="))
        XCTAssertNil(AtermResponse.sysModeIndex(from: ""))
        XCTAssertNil(AtermResponse.sysModeIndex(from: "no-equals-sign"))
    }
}
