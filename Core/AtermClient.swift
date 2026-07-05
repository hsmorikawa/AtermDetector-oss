import Foundation

/// Aterm 検出プローブの抽象 (テストで fake に差し替える)。
protocol AtermProbing: Sendable {
    func probe(ip: String) async -> AtermDevice?
    func probeVerbose(ip: String) async -> ProbeResult
}

extension AtermProbing {
    /// 既定実装: 生応答なしで判定結果のみ返す (fake 用)。
    func probeVerbose(ip: String) async -> ProbeResult {
        await ProbeResult(ip: ip, productNameRaw: nil, sysModeRaw: nil, device: probe(ip: ip))
    }
}

/// HTTP で機器情報照会を行うプローバ。
/// 契約: specs/001-macos-aterm-app/contracts/aterm-probe-protocol.md
struct AtermClient: AtermProbing {
    static let requestTimeout: TimeInterval = 2
    static let endpointPath = "/aterm_httpif.cgi/getparamcmd_no_auth"

    let session: URLSession
    let port: Int
    let macResolver: any MACResolving

    init(session: URLSession, port: Int = 80, macResolver: any MACResolving = ArpTable()) {
        self.session = session
        self.port = port
        self.macResolver = macResolver
    }

    init(port: Int = 80) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Self.requestTimeout
        config.timeoutIntervalForResource = Self.requestTimeout
        config.httpMaximumConnectionsPerHost = 1
        self.init(session: URLSession(configuration: config), port: port)
    }

    /// 機種名照会に正しく応答したアドレスのみ Aterm として返す。
    func probe(ip: String) async -> AtermDevice? {
        await probeVerbose(ip: ip).device
    }

    /// 生応答つきプローブ (単一 IP デバッグ用)。非 Aterm には動作モード照会を送らない。
    func probeVerbose(ip: String) async -> ProbeResult {
        let nameRaw = await request(ip: ip, reqID: "PRODUCT_NAME_GET")
        guard let nameRaw, let name = AtermResponse.productName(from: nameRaw) else {
            return ProbeResult(ip: ip, productNameRaw: nameRaw, sysModeRaw: nil, device: nil)
        }
        let modeRaw = await request(ip: ip, reqID: "SYS_MODE_GET")
        let modeName = SysMode.name(for: modeRaw.flatMap(AtermResponse.sysModeIndex))
        // プローブ応答直後なら ARP テーブルに対象 IP のエントリが残っている
        let device = AtermDevice(name: name, modeName: modeName, ip: ip, macAddress: macResolver.macAddress(for: ip))
        return ProbeResult(ip: ip, productNameRaw: nameRaw, sysModeRaw: modeRaw, device: device)
    }

    /// 単一照会を送り、応答 body を返す (無応答・エラーは nil)。
    func request(ip: String, reqID: String) async -> String? {
        guard let url = URL(string: "http://\(ip):\(port)\(Self.endpointPath)") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("REQ_ID=\(reqID)".utf8)
        guard let (data, _) = try? await session.data(for: request) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
