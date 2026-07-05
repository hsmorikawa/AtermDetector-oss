import XCTest

/// 固定 MAC を返す resolver (テスト用)。
private struct FakeMACResolver: MACResolving {
    var table: [String: String] = [:]

    func macAddress(for ip: String) -> String? {
        table[ip]
    }
}

final class AtermClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    private func makeClient(macTable: [String: String] = [:]) -> AtermClient {
        AtermClient(session: MockURLProtocol.makeSession(), macResolver: FakeMACResolver(table: macTable))
    }

    func testProbeDetectsAterm() async {
        MockURLProtocol.setHandler { _, body in
            if body?.contains("PRODUCT_NAME_GET") == true {
                return .init(body: Data("PRODUCT_NAME=WX5400HP\r\n".utf8))
            }
            return .init(body: Data("SYS_MODE=2\r\n".utf8))
        }
        let device = await makeClient().probe(ip: "192.168.0.10")
        XCTAssertEqual(device?.name, "WX5400HP")
        XCTAssertEqual(device?.modeName, "ローカルルータ")
        XCTAssertEqual(device?.ip, "192.168.0.10")
        XCTAssertEqual(device?.setupURL?.absoluteString, "http://192.168.0.10")
    }

    func testProbeFillsMACAddressFromResolver() async {
        MockURLProtocol.setHandler { _, body in
            if body?.contains("PRODUCT_NAME_GET") == true {
                return .init(body: Data("PRODUCT_NAME=WX5400HP".utf8))
            }
            return .init(body: Data("SYS_MODE=0".utf8))
        }
        let device = await makeClient(macTable: ["192.168.0.16": "AA:BB:CC:00:11:22"]).probe(ip: "192.168.0.16")
        XCTAssertEqual(device?.macAddress, "AA:BB:CC:00:11:22")
    }

    func testProbeMACAddressNilWhenUnresolved() async {
        MockURLProtocol.setHandler { _, body in
            if body?.contains("PRODUCT_NAME_GET") == true {
                return .init(body: Data("PRODUCT_NAME=WX5400HP".utf8))
            }
            return .init(body: Data("SYS_MODE=0".utf8))
        }
        let device = await makeClient().probe(ip: "192.168.0.16")
        XCTAssertEqual(device?.name, "WX5400HP")
        XCTAssertNil(device?.macAddress)
    }

    func testProbeRejectsNonAtermAndSkipsSysModeQuery() async {
        MockURLProtocol.setHandler { _, _ in
            .init(body: Data("<html>router top</html>".utf8))
        }
        let device = await makeClient().probe(ip: "192.168.0.20")
        XCTAssertNil(device)
        XCTAssertEqual(MockURLProtocol.recordedRequests().count, 1, "非 Aterm には SYS_MODE_GET を送らない")
    }

    func testProbeReturnsNilOnNetworkError() async {
        MockURLProtocol.setHandler { _, _ in
            .init(error: URLError(.timedOut))
        }
        let device = await makeClient().probe(ip: "192.168.0.30")
        XCTAssertNil(device)
    }

    func testProbeFallsBackToDashOnInvalidSysMode() async {
        MockURLProtocol.setHandler { _, body in
            if body?.contains("PRODUCT_NAME_GET") == true {
                return .init(body: Data("PRODUCT_NAME=WG1200HS".utf8))
            }
            return .init(error: URLError(.timedOut))
        }
        let device = await makeClient().probe(ip: "192.168.0.40")
        XCTAssertEqual(device?.name, "WG1200HS")
        XCTAssertEqual(device?.modeName, "-")
    }

    // MARK: - probeVerbose (単一 IP デバッグ)

    func testProbeVerboseReturnsRawResponsesForAterm() async {
        MockURLProtocol.setHandler { _, body in
            if body?.contains("PRODUCT_NAME_GET") == true {
                return .init(body: Data("PRODUCT_NAME=WX5400HP\r\n".utf8))
            }
            return .init(body: Data("SYS_MODE=0".utf8))
        }
        let result = await makeClient().probeVerbose(ip: "192.168.0.50")
        XCTAssertEqual(result.ip, "192.168.0.50")
        XCTAssertEqual(result.productNameRaw, "PRODUCT_NAME=WX5400HP\r\n")
        XCTAssertEqual(result.sysModeRaw, "SYS_MODE=0")
        XCTAssertEqual(result.device?.name, "WX5400HP")
        XCTAssertEqual(result.device?.modeName, "ブリッジ")
    }

    func testProbeVerboseNonAtermKeepsRawAndSkipsSysMode() async {
        MockURLProtocol.setHandler { _, _ in
            .init(body: Data("<html>router top</html>".utf8))
        }
        let result = await makeClient().probeVerbose(ip: "192.168.0.60")
        XCTAssertEqual(result.productNameRaw, "<html>router top</html>")
        XCTAssertNil(result.sysModeRaw)
        XCTAssertNil(result.device)
    }

    func testProbeVerboseNoResponse() async {
        MockURLProtocol.setHandler { _, _ in
            .init(error: URLError(.timedOut))
        }
        let result = await makeClient().probeVerbose(ip: "192.168.0.70")
        XCTAssertNil(result.productNameRaw)
        XCTAssertNil(result.sysModeRaw)
        XCTAssertNil(result.device)
    }

    func testRequestShape() async {
        MockURLProtocol.setHandler { _, _ in
            .init(body: Data("PRODUCT_NAME=WX11000T12".utf8))
        }
        _ = await makeClient().probe(ip: "192.168.10.1")
        let requests = MockURLProtocol.recordedRequests()
        guard let first = requests.first else {
            XCTFail("リクエストが記録されていない")
            return
        }
        XCTAssertEqual(first.request.url?.absoluteString, "http://192.168.10.1:80/aterm_httpif.cgi/getparamcmd_no_auth")
        XCTAssertEqual(first.request.httpMethod, "POST")
        XCTAssertEqual(first.request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(first.body, "REQ_ID=PRODUCT_NAME_GET")
    }
}
