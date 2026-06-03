import Foundation
import XCTest

// Base class for iCloud integration tests.
// Provides shared setup/teardown, retry logic, and timing assertions
// that map to real CI signal quality requirements: flaky tests cost
// engineering time; this framework enforces stability budgets.
open class CloudTestBase: XCTestCase {
    public var apiClient: CloudAPIClient!
    public var failureAnalyzer: FailureAnalyzer!

    private var testStartTime: Date = Date()

    // Configurable per test class; override to tighten budget.
    open var maxRetries: Int { 3 }
    open var operationTimeout: TimeInterval { 10.0 }
    open var stabilityBudget: Double { 0.95 } // 95% pass rate over retry window

    override open func setUp() async throws {
        try await super.setUp()
        testStartTime = Date()
        apiClient = CloudAPIClient()
        failureAnalyzer = FailureAnalyzer()
        try await apiClient.connect()
    }

    override open func tearDown() async throws {
        let elapsed = Date().timeIntervalSince(testStartTime)
        // log slow tests so CI can surface timing regressions
        if elapsed > operationTimeout * 2 {
            XCTFail("Test exceeded 2x timeout budget: \(String(format: "%.2fs", elapsed))")
        }
        await apiClient.disconnect()
        try await super.tearDown()
    }

    // Retry wrapper with exponential backoff — isolates flaky network ops
    // from genuine failures in CI triage.
    public func withRetry<T>(
        operation: String,
        attempt: Int = 0,
        block: @escaping () async throws -> T
    ) async throws -> T {
        do {
            return try await block()
        } catch let error as CloudAPIError where error.isRetryable && attempt < maxRetries {
            await failureAnalyzer.record(operation: operation, error: error,
                                          attempt: attempt + 1)
            let delay = pow(2.0, Double(attempt)) * 0.1
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            return try await withRetry(operation: operation, attempt: attempt + 1, block: block)
        } catch {
            await failureAnalyzer.record(operation: operation, error: error,
                                          attempt: attempt + 1)
            throw error
        }
    }

    // Assert operation completes within budget and returns expected category.
    public func assertCloudOperation(
        _ operation: String,
        timeout: TimeInterval? = nil,
        block: @escaping () async throws -> CloudOperationResult
    ) async {
        let budget = timeout ?? operationTimeout
        let start = Date()
        do {
            let result = try await withTimeout(budget) { try await block() }
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(elapsed, budget,
                "\(operation) exceeded \(budget)s budget: \(String(format: "%.3fs", elapsed))")
            XCTAssertEqual(result.status, .success,
                "\(operation) returned non-success: \(result.status)")
        } catch {
            XCTFail("\(operation) threw: \(error)")
        }
    }

    private func withTimeout<T>(_ seconds: TimeInterval, block: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await block() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CloudAPIError.timeout(after: seconds)
            }
            guard let result = try await group.next() else {
                throw CloudAPIError.timeout(after: seconds)
            }
            group.cancelAll()
            return result
        }
    }
}
