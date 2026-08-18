import Foundation

// Deterministic fault-injection primitives for CloudAPIClient.
//
// Tests build a CloudFaultScenario (a plain value type) describing what
// should happen on the next N calls — latency, an HTTP-style failure, an
// offline period — then install it on the client. The client consumes one
// queued step per call; once the queue is empty it falls back to its
// normal mock behavior. All timing goes through an injectable
// FaultInjectionClock so tests never pay real wall-clock cost and never
// race against a timer.

// MARK: - Clock abstraction

/// Stands in for wall-clock delay so fault injection stays deterministic.
/// Production code gets `SystemFaultClock` (real `Task.sleep`); tests
/// install `ManualFaultClock`, which records the requested delay but never
/// actually suspends.
public protocol FaultInjectionClock: Sendable {
    func sleep(for duration: Duration) async throws
}

/// Default clock — used when no fake clock has been installed. Delegates
/// to a real suspension so production/staging runs behave normally.
public struct SystemFaultClock: FaultInjectionClock {
    public init() {}

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

/// Fake clock for tests. Records total requested delay instead of
/// suspending, so a test can assert "500ms of latency was injected"
/// without the test taking 500ms.
public actor ManualFaultClock: FaultInjectionClock {
    public private(set) var totalRequested: Duration = .zero

    public init() {}

    public func sleep(for duration: Duration) async throws {
        totalRequested += duration
    }
}

// MARK: - Fault vocabulary

/// A single injectable failure condition, mapped to a `CloudAPIError` when
/// consumed by the client.
public enum CloudFault: Sendable, Equatable {
    case serverError(statusCode: Int)
    case rateLimited(retryAfter: Duration)
    case timeout

    /// Converts this fault into the concrete error `CloudAPIClient` throws.
    /// `afterLatency` is echoed into `.timeout(after:)` so the error
    /// reflects however much (simulated) time elapsed before it fired.
    func makeError(afterLatency latency: Duration) -> CloudAPIError {
        switch self {
        case .serverError(let statusCode):
            return .serverError(statusCode: statusCode, body: "injected fault: \(statusCode)")
        case .rateLimited(let retryAfter):
            return .rateLimited(retryAfter: retryAfter.timeIntervalValue)
        case .timeout:
            return .timeout(after: latency.timeIntervalValue)
        }
    }
}

struct CloudFaultStep: Sendable {
    var latency: Duration
    var outcome: CloudFaultOutcome
}

enum CloudFaultOutcome: Sendable {
    case succeed
    case fail(CloudFault)
}

// MARK: - Scenario (value type, chainable builder)

/// Describes a deterministic sequence of fault conditions to apply to the
/// next calls made against `CloudAPIClient`. Value type — install a
/// snapshot on the client with `client.install(scenario)`; building a new
/// scenario never mutates one already installed.
///
/// ```swift
/// let scenario = CloudFaultScenario()
///     .latency(.milliseconds(500))
///     .failNext(.rateLimited(retryAfter: .seconds(1)), times: 2)
///     .thenSucceed()
///
/// await client.install(scenario)
/// ```
public struct CloudFaultScenario: Sendable {
    private var pendingLatency: Duration = .zero
    private var steps: [CloudFaultStep] = []
    private var batchFailures: [String: CloudFault] = [:]

    /// Whether the scenario models a persistent offline period. Unlike the
    /// step queue, this isn't consumed per-call — it stays in effect until
    /// `.recovered()` is chained (or `client.recover()` is called directly).
    public private(set) var isOffline: Bool = false

    public init() {}

    /// Sets the delay applied to the *next* chained step (`failNext` or
    /// `thenSucceed`). Consumed through the client's installed clock —
    /// never a real sleep.
    public func latency(_ duration: Duration) -> CloudFaultScenario {
        var copy = self
        copy.pendingLatency = duration
        return copy
    }

    /// Queues `times` consecutive failures with the given fault. Any
    /// pending `.latency(...)` is applied to each queued failure, then
    /// cleared.
    public func failNext(_ fault: CloudFault, times: Int = 1) -> CloudFaultScenario {
        var copy = self
        for _ in 0..<times {
            copy.steps.append(CloudFaultStep(latency: copy.pendingLatency, outcome: .fail(fault)))
        }
        copy.pendingLatency = .zero
        return copy
    }

    /// Queues `times` consecutive successful steps. Useful after
    /// `failNext(...)` to make the eventual recovery explicit and
    /// self-documenting at the call site.
    public func thenSucceed(times: Int = 1) -> CloudFaultScenario {
        var copy = self
        for _ in 0..<times {
            copy.steps.append(CloudFaultStep(latency: copy.pendingLatency, outcome: .succeed))
        }
        copy.pendingLatency = .zero
        return copy
    }

    /// Marks the scenario offline. Every call fails with `.offline` and
    /// the step queue is left untouched (nothing is consumed) until
    /// `.recovered()`.
    public func goOffline() -> CloudFaultScenario {
        var copy = self
        copy.isOffline = true
        return copy
    }

    /// Clears the offline flag, restoring normal step consumption.
    public func recovered() -> CloudFaultScenario {
        var copy = self
        copy.isOffline = false
        return copy
    }

    /// Marks specific batch item ids to fail on the next `syncBatch(_:)`
    /// call, so a test can assert both the failing and succeeding items
    /// of the same batch.
    public func failingBatchItems(_ ids: Set<String>, with fault: CloudFault = .serverError(statusCode: 500)) -> CloudFaultScenario {
        var copy = self
        for id in ids {
            copy.batchFailures[id] = fault
        }
        return copy
    }

    mutating func dequeueStep() -> CloudFaultStep? {
        guard !steps.isEmpty else { return nil }
        return steps.removeFirst()
    }

    func batchFault(for id: String) -> CloudFault? {
        batchFailures[id]
    }
}

// MARK: - Batch API (needed to model partial failures)

/// A single document submitted as part of a batch sync. Kept
/// fully-Sendable (`[String: String]` rather than `[String: Any]`) so
/// batches can cross the CloudAPIClient actor boundary cleanly.
public struct CloudBatchDocument: Sendable {
    public let id: String
    public let payload: [String: String]

    public init(id: String, payload: [String: String] = [:]) {
        self.id = id
        self.payload = payload
    }
}

public enum CloudBatchItemOutcome: Sendable, Equatable {
    case success
    case failed(CloudAPIError)
}

public struct CloudBatchItemResult: Sendable, Equatable {
    public let id: String
    public let outcome: CloudBatchItemOutcome
}

public struct CloudBatchResult: Sendable {
    public let items: [CloudBatchItemResult]

    public init(items: [CloudBatchItemResult]) {
        self.items = items
    }

    public var succeededIds: [String] {
        items.filter { $0.outcome == .success }.map(\.id)
    }

    public var failedItems: [CloudBatchItemResult] {
        items.filter { $0.outcome != .success }
    }

    /// Rolls up per-item outcomes into the existing `CloudOperationStatus`
    /// vocabulary — `.partialSuccess` already exists in `CloudAPIClient.swift`
    /// for exactly this case, so batching reuses it rather than adding a
    /// parallel status type.
    public var status: CloudOperationStatus {
        let total = items.count
        let succeeded = succeededIds.count
        if total == 0 || succeeded == total { return .success }
        if succeeded == 0 { return .failed(reason: "all \(total) batch items failed") }
        return .partialSuccess(count: succeeded, total: total)
    }
}

// MARK: - Duration -> TimeInterval

extension Duration {
    var timeIntervalValue: TimeInterval {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1_000_000_000_000_000_000
    }
}
