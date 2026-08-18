import XCTest
@testable import ICloudTestFramework

final class CloudFaultInjectionTests: CloudTestBase {
    override var operationTimeout: TimeInterval { 5.0 }

    // MARK: - Fails N times then succeeds

    func testFailsTwiceThenSucceeds() async throws {
        let scenario = CloudFaultScenario()
            .failNext(.serverError(statusCode: 503), times: 2)
            .thenSucceed()
        await apiClient.install(scenario)

        for _ in 0..<2 {
            do {
                _ = try await apiClient.syncDocument(id: "flaky-doc", payload: [:])
                XCTFail("Expected injected serverError before recovery")
            } catch CloudAPIError.serverError(let statusCode, _) {
                XCTAssertEqual(statusCode, 503)
            }
        }

        let result = try await apiClient.syncDocument(id: "flaky-doc", payload: [:])
        XCTAssertEqual(result.status, .success, "Scenario should recover after 2 injected failures")
    }

    // MARK: - Offline until explicitly recovered

    func testStaysOfflineUntilExplicitlyRecovered() async throws {
        await apiClient.goOffline()

        for _ in 0..<3 {
            do {
                _ = try await apiClient.syncDocument(id: "offline-doc", payload: [:])
                XCTFail("Expected offline error while scenario is offline")
            } catch CloudAPIError.offline {
                // expected — offline persists across repeated calls until recovered
            }
        }

        await apiClient.recover()

        let result = try await apiClient.syncDocument(id: "offline-doc", payload: [:])
        XCTAssertEqual(result.status, .success, "Client should serve requests again after recover()")
    }

    // MARK: - 429 with documented retry-after semantic

    func test429RateLimitCarriesRetryAfter() async throws {
        let scenario = CloudFaultScenario()
            .failNext(.rateLimited(retryAfter: .seconds(30)))
        await apiClient.install(scenario)

        do {
            _ = try await apiClient.syncDocument(id: "throttled-doc", payload: [:])
            XCTFail("Expected rateLimited error")
        } catch CloudAPIError.rateLimited(let retryAfter) {
            XCTAssertEqual(retryAfter, 30.0, "retryAfter should carry the injected duration in seconds")
        }

        // FailureAnalyzer reuse: rate limiting is a transient infra condition, and retryable.
        XCTAssertTrue(CloudAPIError.rateLimited(retryAfter: 30).isRetryable)
        let category = await failureAnalyzer.categorize(error: CloudAPIError.rateLimited(retryAfter: 30))
        XCTAssertEqual(category, .infrastructure)
    }

    // MARK: - Partial batch failure

    func testPartialBatchFailureReportsPerItemOutcome() async throws {
        let scenario = CloudFaultScenario()
            .failingBatchItems(["doc-2"], with: .serverError(statusCode: 500))
        await apiClient.install(scenario)

        let batch = [
            CloudBatchDocument(id: "doc-1"),
            CloudBatchDocument(id: "doc-2"),
            CloudBatchDocument(id: "doc-3"),
        ]
        let result = try await apiClient.syncBatch(batch)

        XCTAssertEqual(result.status, .partialSuccess(count: 2, total: 3))
        XCTAssertEqual(Set(result.succeededIds), ["doc-1", "doc-3"])
        XCTAssertEqual(result.failedItems.map(\.id), ["doc-2"])

        guard case .failed(let error) = result.failedItems.first?.outcome else {
            XCTFail("Expected doc-2 to carry a failure outcome")
            return
        }
        XCTAssertEqual(error, CloudAPIError.serverError(statusCode: 500, body: "injected fault: 500"))
    }

    // MARK: - Determinism: injected latency never really sleeps

    func testInjectedLatencyDoesNotBlockWallClock() async throws {
        let clock = ManualFaultClock()
        await apiClient.install(clock: clock)

        let scenario = CloudFaultScenario()
            .latency(.seconds(30))
            .thenSucceed()
        await apiClient.install(scenario)

        let start = Date()
        let result = try await apiClient.syncDocument(id: "slow-doc", payload: [:])
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(result.status, .success)
        XCTAssertLessThan(elapsed, 1.0, "A 30s injected latency must not cause a real 30s wall-clock wait")

        let recorded = await clock.totalRequested
        XCTAssertEqual(recorded, .seconds(30), "Fake clock should record the requested delay even though it never sleeps")
    }

    // MARK: - Golden path: full usage example (read this as the docs)

    /// Demonstrates the fault-injection API end to end against `CloudAPIClient`.
    ///
    /// A `CloudFaultScenario` is a value type built by chaining fault conditions:
    /// ```swift
    /// let scenario = CloudFaultScenario()
    ///     .latency(.milliseconds(500))
    ///     .failNext(.rateLimited(retryAfter: .seconds(1)), times: 2)
    ///     .thenSucceed()
    ///
    /// await client.install(scenario)
    /// ```
    /// Installing a scenario replaces whatever was previously queued on the
    /// client. Each call into `CloudAPIClient` consumes exactly one queued
    /// step: first any configured latency is applied through the client's
    /// injectable clock (never a real `Task.sleep`/`sleep()` wall-clock
    /// wait), then the step either fails with the configured `CloudFault`
    /// or succeeds. Once the queue is empty, calls fall back to the
    /// client's normal mock behavior.
    ///
    /// This test is the "golden path" — copy this shape when writing a new
    /// fault-injection test: install a scenario, drive calls through
    /// `withRetry` (inherited from `CloudTestBase`), and assert both the
    /// failure path (captured by `FailureAnalyzer`) and eventual recovery.
    func testGoldenPathRetryThroughRateLimitingThenSucceed() async throws {
        // 1. Build a deterministic scenario: two 429s, then success.
        let scenario = CloudFaultScenario()
            .failNext(.rateLimited(retryAfter: .milliseconds(200)), times: 2)
            .thenSucceed()
        await apiClient.install(scenario)

        // 2. Drive the call through the framework's existing retry helper —
        //    fault injection composes with CloudTestBase, it doesn't replace it.
        var attempts = 0
        let result = try await withRetry(operation: "golden-path-sync") {
            attempts += 1
            return try await self.apiClient.syncDocument(id: "golden-doc", payload: ["k": "v"])
        }

        // 3. Assert the eventual recovery.
        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(attempts, 3, "2 injected rate-limit failures + 1 successful attempt")

        // 4. Assert the failure path was captured through the *existing*
        //    diagnostic system — no parallel reporting was introduced.
        let summary = await failureAnalyzer.summary()
        XCTAssertEqual(summary.byCategory[.infrastructure] ?? 0, 2)
        XCTAssertEqual(summary.byCategory[.product] ?? 0, 0)
    }
}
