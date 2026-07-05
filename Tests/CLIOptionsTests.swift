import XCTest

final class CLIOptionsTests: XCTestCase {
    func testDefaultOptions() throws {
        let options = try CLIOptions.parse([])
        XCTAssertFalse(options.clean)
        XCTAssertNil(options.singleIP)
        XCTAssertFalse(options.showHelp)
    }

    func testCleanFlag() throws {
        XCTAssertTrue(try CLIOptions.parse(["--clean"]).clean)
    }

    func testSingleIP() throws {
        let options = try CLIOptions.parse(["--ip", "192.168.0.16"])
        XCTAssertEqual(options.singleIP, "192.168.0.16")
    }

    func testCleanAndSingleIPCombined() throws {
        let options = try CLIOptions.parse(["--ip", "192.168.0.16", "--clean"])
        XCTAssertTrue(options.clean)
        XCTAssertEqual(options.singleIP, "192.168.0.16")
    }

    func testHelpFlag() throws {
        XCTAssertTrue(try CLIOptions.parse(["--help"]).showHelp)
        XCTAssertTrue(try CLIOptions.parse(["-h"]).showHelp)
    }

    func testInvalidIPThrows() {
        XCTAssertThrowsError(try CLIOptions.parse(["--ip", "not-an-ip"])) { error in
            XCTAssertEqual(error as? CLIOptions.ParseError, .invalidIP("not-an-ip"))
        }
    }

    func testMissingIPValueThrows() {
        XCTAssertThrowsError(try CLIOptions.parse(["--ip"])) { error in
            XCTAssertEqual(error as? CLIOptions.ParseError, .missingValue("--ip"))
        }
    }

    func testUnknownFlagThrows() {
        XCTAssertThrowsError(try CLIOptions.parse(["--bogus"])) { error in
            XCTAssertEqual(error as? CLIOptions.ParseError, .unknownArgument("--bogus"))
        }
    }
}
