import XCTest

final class CLIFormatterTests: XCTestCase {
    private let sample = [
        AtermDevice(name: "WX5400HP", modeName: "ブリッジ", ip: "192.168.0.16", macAddress: "AA:BB:CC:00:11:22"),
        AtermDevice(name: "WG2600HS", modeName: "ローカルルータ", ip: "192.168.0.26", macAddress: nil),
    ]

    // MARK: - clean mode

    func testCleanModeIsTabSeparatedWithoutHeader() {
        let output = CLIFormatter.render(devices: sample, clean: true)
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0], "192.168.0.16\tWX5400HP\tブリッジ\tAA:BB:CC:00:11:22\thttp://192.168.0.16")
        // MAC 未解決は "-"
        XCTAssertEqual(lines[1], "192.168.0.26\tWG2600HS\tローカルルータ\t-\thttp://192.168.0.26")
    }

    func testCleanModeEmptyProducesNoOutput() {
        XCTAssertEqual(CLIFormatter.render(devices: [], clean: true), "")
    }

    // MARK: - default (human) mode

    func testDefaultModeContainsHeaderAndRows() {
        let output = CLIFormatter.render(devices: sample, clean: false)
        XCTAssertTrue(output.contains("機種名"))
        XCTAssertTrue(output.contains("動作モード"))
        XCTAssertTrue(output.contains("MACアドレス"))
        XCTAssertTrue(output.contains("WX5400HP"))
        XCTAssertTrue(output.contains("AA:BB:CC:00:11:22"))
        XCTAssertTrue(output.contains("http://192.168.0.26"))
    }

    func testDefaultModeEmptyShowsNotFoundHint() {
        let output = CLIFormatter.render(devices: [], clean: false)
        XCTAssertTrue(output.contains("見つかりませんでした"))
    }
}
