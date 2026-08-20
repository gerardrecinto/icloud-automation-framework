"""Tests for scripts/triage.py — the CI failure triage engine.

Covers the categorization rules, report building, and the plain-text
xcodebuild log parser. The log parser tests use real `swift test`
output syntax (captured from this repo's own test run) since the
regexes there previously didn't match it at all.
"""

import triage


# --- categorize() ------------------------------------------------------

def test_categorize_network_timeout():
    cat, label = triage.categorize("Connection timed out after 30s")
    assert (cat, label) == ("infrastructure", "network-timeout")


def test_categorize_dns_failure():
    cat, label = triage.categorize("DNS lookup failed for api.icloud-staging.example.com")
    assert (cat, label) == ("infrastructure", "dns-failure")


def test_categorize_server_error():
    cat, label = triage.categorize("request failed with HTTP 503")
    assert (cat, label) == ("infrastructure", "server-error")


def test_categorize_auth_failure():
    cat, label = triage.categorize("HTTP 401 unauthorized")
    assert (cat, label) == ("environment", "auth-failure")


def test_categorize_setup_failure():
    cat, label = triage.categorize("setUpWithError threw: fixture seed failed")
    assert (cat, label) == ("environment", "setup-failure")


def test_categorize_assertion_failure():
    cat, label = triage.categorize("XCTAssertEqual failed: expected 200 got 404")
    assert (cat, label) == ("product", "assertion-failure")


def test_categorize_conflict():
    cat, label = triage.categorize("version vector conflict on document/note")
    assert (cat, label) == ("product", "conflict")


def test_categorize_not_found():
    # Falls through XCTAssert* and conflict rules first since those are
    # more specific and ordered earlier — this message matches neither,
    # so it lands on the not-found rule.
    cat, label = triage.categorize("resource notFound in staging index")
    assert (cat, label) == ("product", "not-found")


def test_categorize_perf_regression():
    cat, label = triage.categorize("operation took 2x timeout budget")
    assert (cat, label) == ("product", "perf-regression")


def test_categorize_intermittent():
    cat, label = triage.categorize("attempt 2 succeeded after retry, previously transient")
    assert (cat, label) == ("flaky", "intermittent")


def test_categorize_build_failure():
    cat, label = triage.categorize("Swift compilation error: cannot find type 'Foo'")
    assert (cat, label) == ("environment", "build-failure")


def test_categorize_unknown_falls_through():
    cat, label = triage.categorize("something completely unrelated happened")
    assert (cat, label) == ("unknown", "uncategorized")


def test_categorize_is_case_insensitive():
    cat, _ = triage.categorize("connection TIMED OUT talking to staging")
    assert cat == "infrastructure"


# --- build_report() -----------------------------------------------------

def _failure(category, label="x", test_name="t"):
    return triage.TestFailure(test_name=test_name, message="m", category=category, label=label)


def test_build_report_splits_actionable_flaky_infrastructure():
    failures = [
        _failure("product"),
        _failure("environment"),
        _failure("infrastructure"),
        _failure("flaky", test_name="syncDocument"),
    ]
    report = triage.build_report(failures)

    assert report.total_failures == 4
    assert len(report.actionable) == 2  # product + environment
    assert len(report.infrastructure) == 1
    assert len(report.flaky) == 1
    assert report.by_category == {"product": 1, "environment": 1, "infrastructure": 1, "flaky": 1}


def test_build_report_signal_ratio():
    failures = [_failure("product"), _failure("infrastructure"), _failure("infrastructure")]
    report = triage.build_report(failures)
    assert report.signal_ratio == 1 / 3


def test_build_report_empty_list_does_not_divide_by_zero():
    report = triage.build_report([])
    assert report.total_failures == 0
    assert report.signal_ratio == 0.0
    assert report.actionable == []


def test_build_report_summary_text_lists_flaky_ops():
    failures = [_failure("flaky", test_name="syncBatch")]
    report = triage.build_report(failures)
    assert "syncBatch" in report.summary_text
    assert "Signal ratio: 0%" in report.summary_text


# --- parse_log_file() ----------------------------------------------------

XCODEBUILD_LOG = """\
Test Case '-[ICloudTests.CloudSyncTests testSyncNewDocument]' started.
/repo/Tests/ICloudTests/CloudSyncTests.swift:42: error: XCTAssertEqual failed: ("200") is not equal to ("404")
Test Case '-[ICloudTests.CloudSyncTests testSyncNewDocument]' failed (0.086 seconds).
Test Case '-[ICloudTests.CloudSyncTests testDeleteDocument]' started.
Test Case '-[ICloudTests.CloudSyncTests testDeleteDocument]' passed (0.001 seconds).
Test Case '-[ICloudTests.CloudFaultInjectionTests testGoldenPath]' started.
/repo/Tests/ICloudTests/CloudFaultInjectionTests.swift:88: error: Connection timed out after 30s
Test Case '-[ICloudTests.CloudFaultInjectionTests testGoldenPath]' failed (30.004 seconds).
"""


def test_parse_log_file_extracts_real_swift_test_output(tmp_path):
    log_path = tmp_path / "xcodebuild.log"
    log_path.write_text(XCODEBUILD_LOG)

    failures = triage.parse_log_file(str(log_path))

    # Two failing tests; the passing testDeleteDocument in between must
    # not show up and must not get merged into either failure.
    assert len(failures) == 2

    first = failures[0]
    assert first.test_name == "ICloudTests.CloudSyncTests testSyncNewDocument"
    assert first.category == "product"
    assert first.label == "assertion-failure"
    assert first.file_path == "/repo/Tests/ICloudTests/CloudSyncTests.swift"
    assert first.line == 42
    assert first.duration_s == 0.086

    second = failures[1]
    assert second.test_name == "ICloudTests.CloudFaultInjectionTests testGoldenPath"
    assert second.category == "infrastructure"
    assert second.label == "network-timeout"
    assert second.duration_s == 30.004


def test_parse_log_file_returns_empty_for_all_passing(tmp_path):
    log_path = tmp_path / "xcodebuild.log"
    log_path.write_text(
        "Test Case '-[ICloudTests.CloudSyncTests testDeleteDocument]' started.\n"
        "Test Case '-[ICloudTests.CloudSyncTests testDeleteDocument]' passed (0.001 seconds).\n"
    )
    assert triage.parse_log_file(str(log_path)) == []
