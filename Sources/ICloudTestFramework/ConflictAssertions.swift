import XCTest

// Custom assertions for ConflictScenarioResult, matching the style of
// CloudTestBase's existing assertCloudOperation: name the thing being
// checked so a failing conflict test reads as a sentence, not a bare
// XCTAssertEqual on an internal dictionary.

public func XCTAssertConflictResolved(
    _ result: ConflictScenarioResult,
    document: String,
    resolvesTo expected: String,
    strategy: ConflictResolutionStrategy = .lastWriterWins,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(
        result.resolvedValue(for: document), expected,
        "expected \(strategy) to resolve \"\(document)\" to \"\(expected)\", got \(result.resolvedValue(for: document).map { "\"\($0)\"" } ?? "nil")",
        file: file, line: line
    )
}

public func XCTAssertNoConflicts(
    _ result: ConflictScenarioResult,
    document: String? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let relevant = document.map(result.conflicts(for:)) ?? result.conflicts
    XCTAssertTrue(
        relevant.isEmpty,
        "expected no conflicts\(document.map { " for \"\($0)\"" } ?? ""), got \(relevant.count): \(relevant)",
        file: file, line: line
    )
}

public func XCTAssertConflictCount(
    _ result: ConflictScenarioResult,
    document: String,
    expected: Int,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(
        result.conflicts(for: document).count, expected,
        "expected \(expected) conflict(s) for \"\(document)\", got \(result.conflicts(for: document).count)",
        file: file, line: line
    )
}
