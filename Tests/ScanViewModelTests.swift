import XCTest

@MainActor
final class ScanViewModelTests: XCTestCase {
    private func makeRange(_ targets: [String]) -> ScanRange {
        ScanRange(
            interfaceName: "en0",
            localIP: "10.0.0.5",
            subnetMask: "255.255.255.0",
            targets: targets,
            isTruncated: false
        )
    }

    private func device(_ ip: String) -> AtermDevice {
        AtermDevice(name: "WX5400HP", modeName: "ブリッジ", ip: ip)
    }

    func testStartScanFindsDevicesAndFinishes() async {
        let targets = ["10.0.0.1", "10.0.0.2", "10.0.0.3"]
        let viewModel = ScanViewModel(
            networkInfo: FakeNetworkInfo(range: makeRange(targets)),
            prober: FakeProber(devices: ["10.0.0.2": device("10.0.0.2")])
        )
        viewModel.startScan()
        XCTAssertTrue(viewModel.isScanning)
        await viewModel.scanTask?.value
        XCTAssertEqual(viewModel.state, .finished(count: 1))
        XCTAssertEqual(viewModel.devices.map(\.ip), ["10.0.0.2"])
        XCTAssertEqual(viewModel.scanRange?.targets.count, 3)
    }

    func testStartScanFailsWhenNetworkInfoUnavailable() {
        let viewModel = ScanViewModel(
            networkInfo: FakeNetworkInfo(range: nil),
            prober: FakeProber()
        )
        viewModel.startScan()
        guard case .failed = viewModel.state else {
            XCTFail("failed 状態になるべき: \(viewModel.state)")
            return
        }
        XCTAssertTrue(viewModel.devices.isEmpty)
        XCTAssertNil(viewModel.scanTask)
    }

    func testStartScanIgnoredWhileScanning() async {
        let targets = (1 ... 4).map { "10.0.0.\($0)" }
        let prober = CountingProber(delayNanoseconds: 100_000_000)
        let viewModel = ScanViewModel(
            networkInfo: FakeNetworkInfo(range: makeRange(targets)),
            prober: prober
        )
        viewModel.startScan()
        viewModel.startScan() // 実行中の二重起動は無視される
        await viewModel.scanTask?.value
        let count = await prober.probeCount
        XCTAssertEqual(count, 4)
    }

    func testRescanAfterFinishClearsAndRunsAgain() async {
        let targets = ["10.0.0.1", "10.0.0.2"]
        let prober = CountingProber()
        let viewModel = ScanViewModel(
            networkInfo: FakeNetworkInfo(range: makeRange(targets)),
            prober: prober
        )
        viewModel.startScan()
        await viewModel.scanTask?.value
        XCTAssertEqual(viewModel.state, .finished(count: 0))

        viewModel.startScan() // 完了後の再スキャンは許可される
        XCTAssertTrue(viewModel.isScanning)
        await viewModel.scanTask?.value
        let count = await prober.probeCount
        XCTAssertEqual(count, 4, "2 対象 × 2 回スキャン")
    }

    func testProbeSingleRejectsInvalidInput() {
        let viewModel = ScanViewModel(
            networkInfo: FakeNetworkInfo(range: nil),
            prober: FakeProber()
        )
        viewModel.probeSingle(ip: "abc")
        XCTAssertNotNil(viewModel.probeError)
        XCTAssertNil(viewModel.probeTask)
        XCTAssertNil(viewModel.probeResult)
    }

    func testProbeSingleReturnsResult() async {
        let viewModel = ScanViewModel(
            networkInfo: FakeNetworkInfo(range: nil),
            prober: FakeProber(devices: ["10.0.0.2": device("10.0.0.2")])
        )
        viewModel.probeSingle(ip: " 10.0.0.2 ") // 前後空白は許容 (trim)
        await viewModel.probeTask?.value
        XCTAssertNil(viewModel.probeError)
        XCTAssertEqual(viewModel.probeResult?.device?.ip, "10.0.0.2")
        XCTAssertFalse(viewModel.isProbing)
    }

    func testFinishedZeroKeepsEmptyDevices() async {
        let viewModel = ScanViewModel(
            networkInfo: FakeNetworkInfo(range: makeRange(["10.0.0.9"])),
            prober: FakeProber()
        )
        viewModel.startScan()
        await viewModel.scanTask?.value
        XCTAssertEqual(viewModel.state, .finished(count: 0))
        XCTAssertTrue(viewModel.devices.isEmpty)
    }
}
