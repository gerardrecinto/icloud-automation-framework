import XCTest
@testable import ICloudTestFramework

final class CloudSyncTests: CloudTestBase {
    override var operationTimeout: TimeInterval { 5.0 }

    func testSyncNewDocument() async throws {
        await assertCloudOperation("sync-new-doc") {
            try await self.apiClient.syncDocument(
                id: "test-doc-\(UUID().uuidString)",
                payload: ["title": "Test", "body": "content", "version": 1]
            )
        }
    }

    func testSyncDocumentWithEmptyIdFails() async throws {
        do {
            _ = try await apiClient.syncDocument(id: "", payload: ["key": "value"])
            XCTFail("Expected invalidData error for empty id")
        } catch CloudAPIError.invalidData(let field, _) {
            XCTAssertEqual(field, "id")
        }
    }

    func testConflictDetectedOnKnownId() async throws {
        do {
            _ = try await apiClient.syncDocument(
                id: "conflict-test-id",
                payload: ["version": 1]
            )
            XCTFail("Expected conflict error")
        } catch CloudAPIError.conflict(_, let detail) {
            XCTAssertFalse(detail.isEmpty, "Conflict detail should describe the conflict")
        }
    }

    func testSyncThenFetch() async throws {
        let docId = "fetch-test-\(UUID().uuidString)"
        let syncResult = try await apiClient.syncDocument(
            id: docId,
            payload: ["title": "Sync-then-fetch test"]
        )
        XCTAssertEqual(syncResult.status, .success)

        let (docs, cursor) = try await apiClient.fetchDocuments(limit: 50)
        XCTAssertNotNil(docs["items"])
        XCTAssertNil(cursor, "Mock returns no next page for small fetches")
    }

    func testPaginatedFetch() async throws {
        let (page1, cursor1) = try await apiClient.fetchDocuments(limit: 3)
        let items1 = page1["items"] as? [[String: Any]] ?? []
        XCTAssertFalse(items1.isEmpty)
        // Mock returns nil cursor — in staging this would return a cursor string
        _ = cursor1
    }

    func testDeleteDocument() async throws {
        let result = try await apiClient.deleteDocument(id: "doc-to-delete")
        XCTAssertEqual(result.status, .success)
    }

    func testClientConnectDisconnectLifecycle() async throws {
        let client = CloudAPIClient()
        try await client.connect()
        await client.disconnect()
    }

    func testPublicResultTypesAreUsableFromTests() {
        let partial = CloudOperationStatus.partialSuccess(count: 2, total: 3)
        XCTAssertNotEqual(partial, .success)

        let result = CloudOperationResult(
            status: .failed(reason: "synthetic"),
            metadata: ["source": "unit-test"],
            durationMs: 12.5
        )
        XCTAssertEqual(result.metadata["source"], "unit-test")
        XCTAssertEqual(result.durationMs, 12.5)
    }

    func testDeleteNotFoundThrows() async throws {
        do {
            _ = try await apiClient.deleteDocument(id: "not-found-id")
            XCTFail("Expected notFound error")
        } catch CloudAPIError.notFound(let resource) {
            XCTAssertTrue(resource.contains("not-found-id"))
        }
    }

    func testOperationCompletesWithinBudget() async throws {
        let start = Date()
        _ = try await apiClient.syncDocument(id: "timing-doc", payload: [:])
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, operationTimeout,
            "Operation took \(String(format: "%.3f", elapsed))s, budget \(operationTimeout)s")
    }

    func testRetryOnTransientError() async throws {
        // FailureAnalyzer captures retry attempts; verify no product failures
        // on operations that succeed after retry.
        var attempt = 0
        let result = try await withRetry(operation: "flaky-sync") {
            attempt += 1
            if attempt < 2 {
                throw CloudAPIError.timeout(after: 1.0) // retryable
            }
            return try await self.apiClient.syncDocument(id: "retry-doc", payload: [:])
        }
        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(attempt, 2)

        let summary = await failureAnalyzer.summary()
        XCTAssertEqual(summary.byCategory[.infrastructure] ?? 0, 1)
        XCTAssertEqual(summary.byCategory[.product] ?? 0, 0)
    }
}
