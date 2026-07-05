import Foundation
import Observation
import os

/// スキャンの UI 状態機械 (data-model.md ScanState)。
enum ScanState: Equatable {
    case idle
    case scanning(done: Int, total: Int)
    case finished(count: Int)
    case failed(message: String)
}

/// スキャンの状態管理。UI 非依存 (SwiftUI からは @Observable として参照)。
@MainActor
@Observable
final class ScanViewModel {
    private(set) var state: ScanState = .idle
    private(set) var devices: [AtermDevice] = []
    private(set) var scanRange: ScanRange?
    private(set) var scanTask: Task<Void, Never>?

    var isScanning: Bool {
        if case .scanning = state { return true }
        return false
    }

    // MARK: - 単一 IP デバッグ検索

    private(set) var probeResult: ProbeResult?
    private(set) var probeError: String?
    private(set) var probeTask: Task<Void, Never>?
    private(set) var isProbing = false

    private static let logger = Logger(subsystem: "com.hsmorikawa.AtermDetector", category: "scan")

    private let networkInfo: any NetworkInfoProviding
    private let prober: any AtermProbing
    private let engine: ScanEngine

    init(
        networkInfo: any NetworkInfoProviding = SystemNetworkInfo(),
        prober: any AtermProbing = AtermClient(),
        maxConcurrent: Int = ScanEngine.defaultMaxConcurrent
    ) {
        self.networkInfo = networkInfo
        self.prober = prober
        self.engine = ScanEngine(prober: prober, maxConcurrent: maxConcurrent)
    }

    /// スキャン開始 (実行中の二重起動は無視)。範囲が導出できないときは failed。
    func startScan() {
        guard !isScanning else { return }
        guard let range = networkInfo.currentScanRange(), !range.targets.isEmpty else {
            state = .failed(message: "ネットワーク情報を取得できません。ネットワーク接続を確認してください。")
            return
        }
        scanRange = range
        devices = []
        state = .scanning(done: 0, total: range.targets.count)

        scanTask = Task { [weak self] in
            guard let self else { return }
            let found = await self.engine.scan(targets: range.targets) { done, total in
                Task { @MainActor in
                    guard self.isScanning else { return }
                    self.state = .scanning(done: done, total: total)
                }
            }
            guard !Task.isCancelled else { return }
            self.devices = found
            self.state = .finished(count: found.count)
            // 件数のみ debug ログ。機器名/IP/MAC は識別子のため永続ログに残さない
            Self.logger.debug("scan finished: \(found.count, privacy: .public) device(s)")
        }
    }

    /// 単一 IP へのデバッグプローブ。不正な IPv4 形式は実行せずエラー表示。
    func probeSingle(ip: String) {
        guard !isProbing else { return }
        let target = ip.trimmingCharacters(in: .whitespaces)
        probeResult = nil
        guard IPv4.isValid(target) else {
            probeError = "IPv4 アドレスの形式が不正です (例: 192.168.0.1)"
            return
        }
        probeError = nil
        isProbing = true
        probeTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.prober.probeVerbose(ip: target)
            guard !Task.isCancelled else { return }
            self.probeResult = result
            self.isProbing = false
        }
    }

    /// 単一 IP 検索の状態を破棄する (シートを閉じるとき)。
    func clearProbe() {
        probeTask?.cancel()
        probeTask = nil
        probeResult = nil
        probeError = nil
        isProbing = false
    }

    /// 進行中のスキャンを破棄する (ウィンドウクローズ時等)。
    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        if isScanning {
            state = .idle
        }
    }
}
