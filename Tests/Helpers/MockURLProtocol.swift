import Foundation

/// URLSession をネットワークなしでテストするための URLProtocol mock。
/// リクエスト (URL + POST body) ごとに固定応答/エラーを返し、受信リクエストを記録する。
class MockURLProtocol: URLProtocol {
    struct Stub {
        var statusCode = 200
        var body: Data?
        var error: Error?
    }

    private nonisolated(unsafe) static var handler: (@Sendable (URLRequest, String?) -> Stub)?
    private nonisolated(unsafe) static var recorded: [(request: URLRequest, body: String?)] = []
    private static let lock = NSLock()

    static func setHandler(_ newHandler: @escaping @Sendable (URLRequest, String?) -> Stub) {
        lock.lock()
        defer { lock.unlock() }
        handler = newHandler
    }

    static func recordedRequests() -> [(request: URLRequest, body: String?)] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        handler = nil
        recorded = []
    }

    /// MockURLProtocol だけを使う URLSession を作る。
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = Self.bodyString(of: request)
        Self.lock.lock()
        Self.recorded.append((request, body))
        let handler = Self.handler
        Self.lock.unlock()

        guard let handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let stub = handler(request, body)
        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard let response = HTTPURLResponse(url: url, statusCode: stub.statusCode, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let data = stub.body {
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// POST body を取り出す (URLProtocol では httpBody が nil になり stream 経由になるため両対応)。
    private static func bodyString(of request: URLRequest) -> String? {
        if let body = request.httpBody {
            return String(data: body, encoding: .utf8)
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return String(data: data, encoding: .utf8)
    }
}
