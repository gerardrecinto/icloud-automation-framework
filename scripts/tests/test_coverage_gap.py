"""Tests for scripts/coverage_gap.py — the untested-public-symbol scanner."""

import coverage_gap


SOURCE_FILE = """\
import Foundation

public struct CloudBatchDocument: Sendable {
    public let id: String

    public init(id: String) {
        self.id = id
    }

    public func describe() -> String {
        "doc-\\(id)"
    }
}

struct InternalHelper {
    func helperOnly() -> Int { 1 }
}

public actor CloudAPIClient {
    public func syncDocument(id: String) async throws -> Bool {
        true
    }

    private func requireConnected() throws {}
}
"""

TEST_FILE = """\
import XCTest
@testable import ICloudTestFramework

final class CloudAPIClientTests: XCTestCase {
    func testSync() async throws {
        let client = CloudAPIClient()
        _ = try await client.syncDocument(id: "doc-1")
    }
}
"""


def _write(tmp_path, name, content):
    path = tmp_path / name
    path.write_text(content)
    return path


def test_extract_symbols_finds_public_and_internal(tmp_path):
    src_dir = tmp_path / "Sources"
    src_dir.mkdir()
    _write(src_dir, "Client.swift", SOURCE_FILE)

    symbols = coverage_gap.extract_symbols(str(src_dir))
    names = {s.name for s in symbols}

    assert "CloudBatchDocument" in names
    assert "CloudAPIClient" in names
    assert "InternalHelper" in names  # internal types are still extracted...

    internal_helper = next(s for s in symbols if s.name == "InternalHelper")
    assert internal_helper.is_public is False  # ...just flagged as not public

    public_client = next(s for s in symbols if s.name == "CloudAPIClient")
    assert public_client.is_public is True
    assert public_client.kind == "actor"


def test_extract_symbols_marks_public_funcs(tmp_path):
    src_dir = tmp_path / "Sources"
    src_dir.mkdir()
    _write(src_dir, "Client.swift", SOURCE_FILE)

    symbols = coverage_gap.extract_symbols(str(src_dir))
    sync_doc = next(s for s in symbols if s.name == "syncDocument")
    assert sync_doc.is_public is True

    # `private func` has no "private" alternative in func_pattern's access
    # modifier group, so it isn't captured as a symbol at all (not even
    # as internal) — private implementation details stay fully out of
    # the coverage-gap scan rather than showing up as false gaps.
    assert not any(s.name == "requireConnected" for s in symbols)


def test_find_gaps_excludes_symbols_referenced_in_tests(tmp_path):
    src_dir = tmp_path / "Sources"
    src_dir.mkdir()
    _write(src_dir, "Client.swift", SOURCE_FILE)
    test_dir = tmp_path / "Tests"
    test_dir.mkdir()
    _write(test_dir, "ClientTests.swift", TEST_FILE)

    symbols = coverage_gap.extract_symbols(str(src_dir))
    tested, _ = coverage_gap.extract_tested_names(str(test_dir))
    gaps = coverage_gap.find_gaps(symbols, tested)

    gap_names = {g.name for g in gaps}
    # CloudAPIClient and syncDocument are referenced in the test file.
    assert "CloudAPIClient" not in gap_names
    assert "syncDocument" not in gap_names
    # describe() and CloudBatchDocument are public but never referenced.
    assert "describe" in gap_names
    assert "CloudBatchDocument" in gap_names
    # Internal symbols never count as gaps regardless of test coverage.
    assert "helperOnly" not in gap_names


ENUM_SOURCE_FILE = """\
public enum SyncStrategy: String, Sendable {
    case lastWriterWins
    case firstWriterWins
}
"""

ENUM_TEST_FILE = """\
import XCTest

final class SyncStrategyTests: XCTestCase {
    func testFirstWriterWins() {
        let strategy: SyncStrategy = .firstWriterWins
        _ = strategy
    }
}
"""


def test_extract_enum_cases_maps_case_names_to_their_enum(tmp_path):
    src_dir = tmp_path / "Sources"
    src_dir.mkdir()
    _write(src_dir, "Strategy.swift", ENUM_SOURCE_FILE)

    cases = coverage_gap.extract_enum_cases(str(src_dir))

    assert cases["SyncStrategy"] == ["lastWriterWins", "firstWriterWins"]


def test_find_gaps_credits_enum_tested_only_through_implicit_member_syntax(tmp_path):
    # A test can exercise an enum purely through Swift's implicit member
    # syntax (`.firstWriterWins`) without the enum's own type name ever
    # appearing as a token in the test file, which used to make find_gaps
    # report the enum as untested even though a real test covers it.
    src_dir = tmp_path / "Sources"
    src_dir.mkdir()
    _write(src_dir, "Strategy.swift", ENUM_SOURCE_FILE)
    test_dir = tmp_path / "Tests"
    test_dir.mkdir()
    _write(test_dir, "StrategyTests.swift", ENUM_TEST_FILE)

    symbols = coverage_gap.extract_symbols(str(src_dir))
    tested, tested_members = coverage_gap.extract_tested_names(str(test_dir))
    for enum_name, case_names in coverage_gap.extract_enum_cases(str(src_dir)).items():
        if any(case in tested_members for case in case_names):
            tested.add(enum_name)
    gaps = coverage_gap.find_gaps(symbols, tested)

    assert "SyncStrategy" not in {g.name for g in gaps}


def test_compute_coverage_percentage(tmp_path):
    src_dir = tmp_path / "Sources"
    src_dir.mkdir()
    _write(src_dir, "Client.swift", SOURCE_FILE)
    test_dir = tmp_path / "Tests"
    test_dir.mkdir()
    _write(test_dir, "ClientTests.swift", TEST_FILE)

    symbols = coverage_gap.extract_symbols(str(src_dir))
    tested, _ = coverage_gap.extract_tested_names(str(test_dir))
    coverage = coverage_gap.compute_coverage(symbols, tested)

    public_syms = [s for s in symbols if s.is_public]
    covered = sum(1 for s in public_syms if s.name in tested)
    assert coverage == (covered / len(public_syms)) * 100


def test_compute_coverage_is_100_when_no_public_symbols(tmp_path):
    src_dir = tmp_path / "Sources"
    src_dir.mkdir()
    _write(src_dir, "Internal.swift", "struct OnlyInternal {\n    func hidden() {}\n}\n")

    symbols = coverage_gap.extract_symbols(str(src_dir))
    coverage = coverage_gap.compute_coverage(symbols, tested=set())
    assert coverage == 100.0
