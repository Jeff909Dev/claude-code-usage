import Foundation
@testable import UsageCore

final class FakeHTTPClient: HTTPClient, @unchecked Sendable {
    struct Stub {
        var status: Int
        var body: Data
        var headers: [String: String] = [:]
    }

    static func json(_ status: Int, _ body: String, headers: [String: String] = [:]) -> Stub {
        Stub(status: status, body: Data(body.utf8), headers: headers)
    }

    private let lock = NSLock()
    private var queue: [Stub]
    private var recorded: [URLRequest] = []
    var onSend: (@Sendable (URLRequest) -> Void)?
    var error: (any Error)?

    init(_ stubs: [Stub]) { queue = stubs }

    var requests: [URLRequest] { lock.locked { recorded } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        onSend?(request)
        return try lock.locked {
            recorded.append(request)
            if let error { throw error }
            guard !queue.isEmpty else { throw URLError(.resourceUnavailable) }
            let stub = queue.removeFirst()
            let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1",
                                           headerFields: stub.headers)!
            return (stub.body, response)
        }
    }
}
