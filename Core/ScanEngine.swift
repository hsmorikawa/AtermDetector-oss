import Foundation

/// 対象アドレス列への並列プローブ実行。
struct ScanEngine {
    static let defaultMaxConcurrent = 32

    let prober: any AtermProbing
    var maxConcurrent: Int = ScanEngine.defaultMaxConcurrent

    /// 全対象をプローブし、検出機器を最終オクテット昇順で返す。
    /// onProgress は 1 対象完了ごとに (完了数, 総数) で呼ばれる (呼び出しスレッドは任意)。
    func scan(
        targets: [String],
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [AtermDevice] {
        let total = targets.count
        guard total > 0 else { return [] }

        var found: [AtermDevice] = []
        var done = 0
        var iterator = targets.makeIterator()

        await withTaskGroup(of: AtermDevice?.self) { group in
            var active = 0
            while active < maxConcurrent, let ip = iterator.next() {
                group.addTask { await prober.probe(ip: ip) }
                active += 1
            }
            for await result in group {
                done += 1
                onProgress?(done, total)
                if let device = result {
                    found.append(device)
                }
                if !Task.isCancelled, let ip = iterator.next() {
                    group.addTask { await prober.probe(ip: ip) }
                }
            }
        }
        return found.sorted { $0.lastOctet < $1.lastOctet }
    }
}
