import Foundation

public enum CloudAPIError: Error, Sendable, Equatable {
    case timeout(after: TimeInterval)
    case serverError(statusCode: Int, body: String)
    case unauthorized(reason: String)
    case notFound(resource: String)
    case conflict(resource: String, detail: String)
    case invalidData(field: String, detail: String)
    // 429-style throttling. retryAfter mirrors the server's Retry-After
    // hint (in seconds) so callers can back off deterministically instead
    // of guessing.
    case rateLimited(retryAfter: TimeInterval)
    // Fault-injection offline mode — client is intentionally unreachable
    // until CloudAPIClient.recover() is called.
    case offline

    var isRetryable: Bool {
        switch self {
        case .timeout, .serverError, .rateLimited: return true
        default: return false
        }
    }
}

public enum CloudOperationStatus: Equatable, Sendable {
    case success
    case partialSuccess(count: Int, total: Int)
    case failed(reason: String)
}

public struct CloudOperationResult: Sendable {
    public let status: CloudOperationStatus
    public let metadata: [String: String]
    public let durationMs: Double

    public init(status: CloudOperationStatus,
                metadata: [String: String] = [:],
                durationMs: Double = 0) {
        self.status = status
        self.metadata = metadata
        self.durationMs = durationMs
    }
}

// Lightweight mock iCloud API client for automation tests.
// In production CI, swap baseURL + authToken to hit staging endpoints.
public actor CloudAPIClient {
    private let session: URLSession
    private var isConnected = false

    public var baseURL: URL = URL(string: "https://api.icloud-staging.example.com/v1")!
    public var authToken: String = ""

    // Simulated latency for mock mode — mirrors observed P50 staging latency.
    public var simulatedLatencyMs: Double = 80

    // When true, responses come from in-memory stubs (no network required).
    public var mockMode: Bool = true

    // Fault injection state — see CloudFaultInjection.swift. Empty scenario
    // + SystemFaultClock is a no-op, so normal (non-test) use is unaffected.
    private var faultScenario = CloudFaultScenario()
    private var faultClock: any FaultInjectionClock = SystemFaultClock()

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Installs a fault scenario, replacing whatever was previously queued.
    public func install(_ scenario: CloudFaultScenario) {
        faultScenario = scenario
    }

    /// Installs a clock for injected-latency delays. Tests should install
    /// `ManualFaultClock`; production/staging use keeps the default
    /// `SystemFaultClock`.
    public func install(clock: any FaultInjectionClock) {
        faultClock = clock
    }

    /// Puts the client into a persistent offline state — every call fails
    /// with `.offline` until `recover()` is called. Does not touch any
    /// already-queued fault steps.
    public func goOffline() {
        faultScenario = faultScenario.goOffline()
    }

    /// Ends fault-injected offline mode.
    public func recover() {
        faultScenario = faultScenario.recovered()
    }

    // Consumes one queued fault step (if any) before an operation runs.
    // Offline takes priority and never consumes the queue.
    private func applyFaultInjection() async throws {
        if faultScenario.isOffline {
            throw CloudAPIError.offline
        }
        guard let step = faultScenario.dequeueStep() else { return }
        if step.latency > .zero {
            try await faultClock.sleep(for: step.latency)
        }
        switch step.outcome {
        case .succeed:
            return
        case .fail(let fault):
            throw fault.makeError(afterLatency: step.latency)
        }
    }

    public func connect() async throws {
        // In mock mode, skip real handshake but validate config.
        guard !authToken.isEmpty || mockMode else {
            throw CloudAPIError.unauthorized(reason: "authToken not set")
        }
        isConnected = true
    }

    public func disconnect() async {
        isConnected = false
    }

    // Sync a document. Returns result with conflict detection.
    public func syncDocument(id: String, payload: [String: Any]) async throws -> CloudOperationResult {
        let start = Date()
        try requireConnected()
        try await applyFaultInjection()

        if mockMode {
            try await simulatedDelay()
            if id.isEmpty {
                throw CloudAPIError.invalidData(field: "id", detail: "must not be empty")
            }
            if id == "conflict-test-id" {
                throw CloudAPIError.conflict(resource: "document/\(id)",
                                              detail: "version vector conflict")
            }
            let ms = Date().timeIntervalSince(start) * 1000
            return CloudOperationResult(status: .success,
                                         metadata: ["documentId": id, "version": "42"],
                                         durationMs: ms)
        }

        let url = baseURL.appending(path: "documents/\(id)")
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        req.timeoutInterval = 10

        let (data, response) = try await session.data(for: req)
        let ms = Date().timeIntervalSince(start) * 1000
        return try parseResponse(data: data, response: response, durationMs: ms)
    }

    // Fetch documents with optional cursor for pagination.
    public func fetchDocuments(cursor: String? = nil, limit: Int = 50) async throws -> ([String: Any], String?) {
        try requireConnected()
        try await applyFaultInjection()
        if mockMode {
            try await simulatedDelay()
            let docs: [String: Any] = [
                "items": (0..<min(limit, 5)).map { ["id": "doc-\($0)", "version": 1] },
                "count": min(limit, 5),
            ]
            return (docs, nil) // nil cursor = no more pages
        }
        var components = URLComponents(url: baseURL.appending(path: "documents"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor {
            components.queryItems?.append(URLQueryItem(name: "cursor", value: cursor))
        }
        var req = URLRequest(url: components.url!)
        req.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        _ = try parseResponse(data: data, response: response, durationMs: 0)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return (json, json["cursor"] as? String)
    }

    public func deleteDocument(id: String) async throws -> CloudOperationResult {
        try requireConnected()
        try await applyFaultInjection()
        if mockMode {
            try await simulatedDelay()
            if id == "not-found-id" {
                throw CloudAPIError.notFound(resource: "document/\(id)")
            }
            return CloudOperationResult(status: .success, metadata: ["deleted": id])
        }
        let url = baseURL.appending(path: "documents/\(id)")
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        return try parseResponse(data: data, response: response, durationMs: 0)
    }

    // Sync a batch of documents, reporting a per-item outcome. Lets tests
    // exercise partial-batch-failure fault injection (some ids fail, the
    // rest succeed) via CloudFaultScenario.failingBatchItems(_:with:).
    public func syncBatch(_ documents: [CloudBatchDocument]) async throws -> CloudBatchResult {
        try requireConnected()
        if faultScenario.isOffline {
            throw CloudAPIError.offline
        }
        var items: [CloudBatchItemResult] = []
        items.reserveCapacity(documents.count)
        for doc in documents {
            if let fault = faultScenario.batchFault(for: doc.id) {
                items.append(CloudBatchItemResult(id: doc.id, outcome: .failed(fault.makeError(afterLatency: .zero))))
            } else {
                items.append(CloudBatchItemResult(id: doc.id, outcome: .success))
            }
        }
        return CloudBatchResult(items: items)
    }

    private func requireConnected() throws {
        guard isConnected else {
            throw CloudAPIError.unauthorized(reason: "client not connected — call connect() first")
        }
    }

    private func simulatedDelay() async throws {
        let ns = UInt64((simulatedLatencyMs / 1000) * 1_000_000_000)
        try await Task.sleep(nanoseconds: ns)
    }

    private func parseResponse(data: Data, response: URLResponse, durationMs: Double) throws -> CloudOperationResult {
        guard let http = response as? HTTPURLResponse else {
            throw CloudAPIError.serverError(statusCode: -1, body: "non-HTTP response")
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        switch http.statusCode {
        case 200...204:
            return CloudOperationResult(status: .success, durationMs: durationMs)
        case 401, 403:
            throw CloudAPIError.unauthorized(reason: body)
        case 404:
            throw CloudAPIError.notFound(resource: body)
        case 409:
            throw CloudAPIError.conflict(resource: "", detail: body)
        case 500...599:
            throw CloudAPIError.serverError(statusCode: http.statusCode, body: body)
        default:
            throw CloudAPIError.serverError(statusCode: http.statusCode, body: body)
        }
    }
}
