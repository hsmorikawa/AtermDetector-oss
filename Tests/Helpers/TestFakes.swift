import Foundation

/// 固定応答プローバ。
struct FakeProber: AtermProbing {
    var devices: [String: AtermDevice] = [:]
    var delayNanoseconds: UInt64 = 0

    func probe(ip: String) async -> AtermDevice? {
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return devices[ip]
    }
}

/// 呼び出し回数を数えるプローバ。
actor CountingProber: AtermProbing {
    private(set) var probeCount = 0
    let delayNanoseconds: UInt64
    let devices: [String: AtermDevice]

    init(devices: [String: AtermDevice] = [:], delayNanoseconds: UInt64 = 0) {
        self.devices = devices
        self.delayNanoseconds = delayNanoseconds
    }

    func probe(ip: String) async -> AtermDevice? {
        probeCount += 1
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return devices[ip]
    }
}

/// 起動直後のローカルネットワーク権限レースを模擬するプローバ。
/// 最初の `activateAfter` 回の probe は nil を返し (= 権限有効化前で空振り)、
/// それ以降のみ devices を返す (= 再スキャンで検出できる)。
actor RaceProber: AtermProbing {
    private var calls = 0
    let activateAfter: Int
    let devices: [String: AtermDevice]

    init(devices: [String: AtermDevice], activateAfter: Int) {
        self.devices = devices
        self.activateAfter = activateAfter
    }

    func probe(ip: String) async -> AtermDevice? {
        calls += 1
        if calls <= activateAfter { return nil }
        return devices[ip]
    }
}

/// 固定のスキャン範囲を返すネットワーク情報。
struct FakeNetworkInfo: NetworkInfoProviding {
    var range: ScanRange?

    func currentScanRange() -> ScanRange? {
        range
    }
}

/// 進捗コールバック記録用。
final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(done: Int, total: Int)] = []

    func append(done: Int, total: Int) {
        lock.lock()
        defer { lock.unlock() }
        values.append((done, total))
    }

    func snapshot() -> [(done: Int, total: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
