import Foundation

// Failure category enum drives triage routing:
// infrastructure failures page on-call; product failures go to dev team.
public enum FailureCategory: String, Sendable, CustomStringConvertible {
    case infrastructure  // DNS, timeout, TLS — not product bugs
    case product         // wrong data, incorrect behavior
    case flaky           // intermittent — needs retry budget review
    case environment     // test setup / data seeding failure
    case unknown

    public var description: String { rawValue }
    public var isActionable: Bool { self == .product || self == .environment }
}

public struct FailureRecord: Sendable {
    public let operation: String
    public let error: any Error
    public let category: FailureCategory
    public let attempt: Int
    public let timestamp: Date
    public let errorMessage: String

    public var isFlaky: Bool { attempt > 1 && category != .product }
}

// Actor — safe for concurrent test execution across multiple XCTest threads.
public actor FailureAnalyzer {
    private var records: [FailureRecord] = []

    // Categorize by error type + message patterns.
    // Rules map to real iCloud CI failure taxonomy.
    public func categorize(error: any Error) -> FailureCategory {
        let msg = String(describing: error).lowercased()

        if let apiError = error as? CloudAPIError {
            switch apiError {
            case .timeout:       return .infrastructure
            case .serverError:   return .infrastructure
            case .rateLimited:   return .infrastructure
            case .offline:       return .infrastructure
            case .unauthorized:  return .environment
            case .notFound:      return .product
            case .conflict:      return .product
            case .invalidData:   return .product
            }
        }

        // NSError / URLError patterns
        let nsErr = error as NSError
        let infraCodes: Set<Int> = [-1001, -1003, -1004, -1005, -1009, -1017]
        if nsErr.domain == NSURLErrorDomain && infraCodes.contains(nsErr.code) {
            return .infrastructure
        }

        // Text heuristics for uncategorized errors
        if msg.contains("timeout") || msg.contains("dns") || msg.contains("connection refused") {
            return .infrastructure
        }
        if msg.contains("setup") || msg.contains("seed") || msg.contains("fixture") {
            return .environment
        }
        if msg.contains("expected") || msg.contains("mismatch") || msg.contains("assertion") {
            return .product
        }

        return .unknown
    }

    public func record(operation: String, error: any Error, attempt: Int) async {
        let cat = categorize(error: error)
        let record = FailureRecord(
            operation: operation,
            error: error,
            category: cat,
            attempt: attempt,
            timestamp: Date(),
            errorMessage: String(describing: error)
        )
        records.append(record)
    }

    // Returns flaky ops: failed on attempt > 1 — used to tune retry budgets.
    public func flakyOperations() -> [String: Int] {
        var counts: [String: Int] = [:]
        for r in records where r.isFlaky {
            counts[r.operation, default: 0] += 1
        }
        return counts
    }

    public func summary() -> FailureSummary {
        var byCategory: [FailureCategory: Int] = [:]
        for r in records {
            byCategory[r.category, default: 0] += 1
        }
        return FailureSummary(
            total: records.count,
            byCategory: byCategory,
            flaky: flakyOperations()
        )
    }

    public func reset() {
        records.removeAll()
    }
}

public struct FailureSummary: Sendable {
    public let total: Int
    public let byCategory: [FailureCategory: Int]
    public let flaky: [String: Int]

    public var actionableCount: Int {
        (byCategory[.product] ?? 0) + (byCategory[.environment] ?? 0)
    }
}
