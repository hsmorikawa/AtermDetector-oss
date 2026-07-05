import XCTest

final class ScanEngineTests: XCTestCase {
    private func device(_ ip: String, name: String = "WX5400HP") -> AtermDevice {
        AtermDevice(name: name, modeName: "ブリッジ", ip: ip)
    }

    func testScanFindsDevicesSortedByLastOctet() async {
        let targets = (1 ... 254).map { "10.0.0.\($0)" }
        let prober = FakeProber(devices: [
            "10.0.0.200": device("10.0.0.200"),
            "10.0.0.3": device("10.0.0.3"),
            "10.0.0.45": device("10.0.0.45"),
        ])
        let engine = ScanEngine(prober: prober)
        let found = await engine.scan(targets: targets)
        XCTAssertEqual(found.map(\.ip), ["10.0.0.3", "10.0.0.45", "10.0.0.200"])
    }

    func testScanReportsProgressForEveryTarget() async {
        let targets = (1 ... 40).map { "10.0.0.\($0)" }
        let collector = ProgressCollector()
        let engine = ScanEngine(prober: FakeProber())
        _ = await engine.scan(targets: targets) { done, total in
            collector.append(done: done, total: total)
        }
        let values = collector.snapshot()
        XCTAssertEqual(values.count, 40)
        XCTAssertEqual(values.last?.done, 40)
        XCTAssertEqual(values.last?.total, 40)
    }

    func testScanEmptyTargetsReturnsEmpty() async {
        let engine = ScanEngine(prober: FakeProber())
        let found = await engine.scan(targets: [])
        XCTAssertTrue(found.isEmpty)
    }

    func testScanRespondsToCancellation() async {
        // 1 プローブ 0.5 秒 × 100 対象 (並列 32 なら完走まで ~2 秒) をすぐキャンセル →
        // 1 秒以内に返ることを確認
        let targets = (1 ... 100).map { "10.0.0.\($0)" }
        let engine = ScanEngine(prober: FakeProber(delayNanoseconds: 500_000_000))
        let start = Date()
        let task = Task { await engine.scan(targets: targets) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        _ = await task.value
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }
}
