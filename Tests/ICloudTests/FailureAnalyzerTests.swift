import XCTest
@testable import ICloudTestFramework

final class FailureAnalyzerTests: XCTestCase {
    var analyzer: FailureAnalyzer!

    override func setUp() {
        analyzer = FailureAnalyzer()
    }

    func testCategorizesTimeoutAsInfrastructure() async {
        let cat = await analyzer.categorize(error: CloudAPIError.timeout(after: 5.0))
        XCTAssertEqual(cat, .infrastructure)
    }

    func testCategorizesServerErrorAsInfrastructure() async {
        let cat = await analyzer.categorize(error: CloudAPIError.serverError(statusCode: 503, body: ""))
        XCTAssertEqual(cat, .infrastructure)
    }

    func testCategorizesNotFoundAsProduct() async {
        let cat = await analyzer.categorize(error: CloudAPIError.notFound(resource: "doc/abc"))
        XCTAssertEqual(cat, .product)
    }

    func testCategorizesConflictAsProduct() async {
        let cat = await analyzer.categorize(error: CloudAPIError.conflict(resource: "doc/abc", detail: "vec"))
        XCTAssertEqual(cat, .product)
    }

    func testCategorizesUnauthorizedAsEnvironment() async {
        let cat = await analyzer.categorize(error: CloudAPIError.unauthorized(reason: "no token"))
        XCTAssertEqual(cat, .environment)
    }

    func testCategorizesInvalidDataAsProduct() async {
        let cat = await analyzer.categorize(error: CloudAPIError.invalidData(field: "id", detail: "empty"))
        XCTAssertEqual(cat, .product)
    }

    func testSummaryCountsByCategory() async {
        await analyzer.record(operation: "op1", error: CloudAPIError.timeout(after: 1), attempt: 1)
        await analyzer.record(operation: "op2", error: CloudAPIError.notFound(resource: "x"), attempt: 1)
        await analyzer.record(operation: "op3", error: CloudAPIError.conflict(resource: "y", detail: ""), attempt: 2)

        let summary = await analyzer.summary()
        XCTAssertEqual(summary.total, 3)
        XCTAssertEqual(summary.byCategory[.infrastructure], 1)
        XCTAssertEqual(summary.byCategory[.product], 2)
    }

    func testFlakyOperationDetection() async {
        // attempt > 1 = flaky
        await analyzer.record(operation: "sync-doc", error: CloudAPIError.timeout(after: 1), attempt: 2)
        await analyzer.record(operation: "sync-doc", error: CloudAPIError.timeout(after: 1), attempt: 3)
        await analyzer.record(operation: "delete-doc", error: CloudAPIError.serverError(statusCode: 500, body: ""), attempt: 1)

        let flaky = await analyzer.flakyOperations()
        XCTAssertEqual(flaky["sync-doc"], 2)
        XCTAssertNil(flaky["delete-doc"], "attempt=1 is not flaky")
    }

    func testActionableCountExcludesInfrastructure() async {
        await analyzer.record(operation: "op1", error: CloudAPIError.timeout(after: 1), attempt: 1)
        await analyzer.record(operation: "op2", error: CloudAPIError.notFound(resource: "x"), attempt: 1)
        await analyzer.record(operation: "op3", error: CloudAPIError.unauthorized(reason: "env"), attempt: 1)

        let summary = await analyzer.summary()
        // product + environment = actionable; infrastructure = not
        XCTAssertEqual(summary.actionableCount, 2)
    }

    func testResetClearsRecords() async {
        await analyzer.record(operation: "op1", error: CloudAPIError.timeout(after: 1), attempt: 1)
        await analyzer.reset()
        let summary = await analyzer.summary()
        XCTAssertEqual(summary.total, 0)
    }

    func testPublicFailureTypesAreUsableFromTests() {
        let record = FailureRecord(
            operation: "sync-doc",
            error: CloudAPIError.timeout(after: 1),
            category: FailureCategory.infrastructure,
            attempt: 2,
            timestamp: Date(),
            errorMessage: "timeout"
        )
        XCTAssertTrue(record.isFlaky)

        let summary = FailureSummary(
            total: 1,
            byCategory: [.environment: 1],
            flaky: ["sync-doc": 1]
        )
        XCTAssertEqual(summary.actionableCount, 1)
    }
}
