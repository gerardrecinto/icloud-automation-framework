#!/usr/bin/env python3
"""
AI-assisted CI failure triage for iCloud test automation pipelines.
Parses XCTest result bundles (.xcresult) or plain log files,
categorizes failures by type, and generates actionable triage reports.

Leaves room for model-assisted failure explanation when pattern matching
alone is insufficient.
"""

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Optional


# Failure patterns ordered by specificity — first match wins.
TRIAGE_RULES: list[tuple[str, str, str]] = [
    # (regex pattern, category, short label)
    (r"Connection timed out|Network connection lost|NSURLErrorDomain.*-1001", "infrastructure", "network-timeout"),
    (r"DNS lookup failed|NSURLErrorDomain.*-1003",                           "infrastructure", "dns-failure"),
    (r"HTTP 50[0-9]",                                                          "infrastructure", "server-error"),
    (r"HTTP 401|HTTP 403|unauthorized|Unauthorized",                           "environment",   "auth-failure"),
    (r"setUp|setUpWithError|fixture|seed.*fail",                               "environment",   "setup-failure"),
    (r"XCTAssertEqual|XCTAssertTrue|XCTAssertNil|XCTFail.*expected",           "product",       "assertion-failure"),
    (r"version vector conflict|conflict-test-id",                              "product",       "conflict"),
    (r"not found|404|notFound",                                                "product",       "not-found"),
    (r"took.*budget|exceeded.*timeout|2x timeout",                             "product",       "perf-regression"),
    (r"attempt \d+.*retry|retried|transient",                                  "flaky",         "intermittent"),
    (r"ld: warning|build failed|compile error|Swift compilation",              "environment",   "build-failure"),
]


@dataclass
class TestFailure:
    test_name: str
    message: str
    category: str
    label: str
    file_path: str = ""
    line: int = 0
    duration_s: float = 0.0
    raw_lines: list[str] = field(default_factory=list)


@dataclass
class TriageReport:
    total_failures: int
    by_category: dict[str, int]
    actionable: list[TestFailure]
    flaky: list[TestFailure]
    infrastructure: list[TestFailure]
    signal_ratio: float
    summary_text: str


def categorize(message: str) -> tuple[str, str]:
    for pattern, category, label in TRIAGE_RULES:
        if re.search(pattern, message, re.IGNORECASE):
            return category, label
    return "unknown", "uncategorized"


def parse_xcresult(xcresult_path: str) -> list[TestFailure]:
    """Extract failures from .xcresult bundle using xcresulttool."""
    cmd = ["xcrun", "xcresulttool", "get", "--format", "json",
           "--path", xcresult_path]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if result.returncode != 0:
            print(f"xcresulttool error: {result.stderr}", file=sys.stderr)
            return []
        data = json.loads(result.stdout)
    except (FileNotFoundError, subprocess.TimeoutExpired, json.JSONDecodeError) as e:
        print(f"Failed to parse xcresult: {e}", file=sys.stderr)
        return []

    failures = []
    actions = data.get("actions", {}).get("_values", [])
    for action in actions:
        tests = action.get("actionResult", {}).get("testsRef", {})
        for suite in _walk_test_nodes(tests):
            if suite.get("testStatus", {}).get("_value") != "Failure":
                continue
            name = suite.get("identifier", {}).get("_value", "unknown")
            duration = float(suite.get("duration", {}).get("_value", 0))
            failure_summaries = suite.get("failureSummaries", {}).get("_values", [])
            for fs in failure_summaries:
                msg = fs.get("message", {}).get("_value", "")
                file_path = fs.get("fileName", {}).get("_value", "")
                line = int(fs.get("lineNumber", {}).get("_value", 0))
                cat, label = categorize(msg)
                failures.append(TestFailure(
                    test_name=name,
                    message=msg,
                    category=cat,
                    label=label,
                    file_path=file_path,
                    line=line,
                    duration_s=duration,
                ))
    return failures


def _walk_test_nodes(node: dict) -> list[dict]:
    results = []
    if isinstance(node, dict):
        if "testStatus" in node:
            results.append(node)
        for value in node.values():
            results.extend(_walk_test_nodes(value))
    elif isinstance(node, list):
        for item in node:
            results.extend(_walk_test_nodes(item))
    return results


def parse_log_file(log_path: str) -> list[TestFailure]:
    """Parse plain-text xcodebuild / XCTest log output."""
    failures: list[TestFailure] = []
    current_test: Optional[str] = None
    current_lines: list[str] = []

    test_start = re.compile(r"Test Case '-\[(\S+)\]' started")
    test_fail = re.compile(r"Test Case '-\[(\S+)\]' failed \((\d+\.\d+) seconds\)")
    assertion = re.compile(r"(.+):(\d+): error: (.+)")

    with open(log_path) as f:
        for line in f:
            line = line.rstrip()
            m = test_start.search(line)
            if m:
                current_test = m.group(1)
                current_lines = [line]
                continue

            if current_test:
                current_lines.append(line)

            m = test_fail.search(line)
            if m and current_test:
                duration = float(m.group(2))
                # find assertion message in collected lines
                msg = ""
                file_path = ""
                lineno = 0
                for cl in current_lines:
                    am = assertion.search(cl)
                    if am:
                        file_path = am.group(1)
                        lineno = int(am.group(2))
                        msg = am.group(3)
                        break

                if not msg:
                    msg = " ".join(current_lines[-3:])

                cat, label = categorize(msg)
                failures.append(TestFailure(
                    test_name=current_test,
                    message=msg,
                    category=cat,
                    label=label,
                    file_path=file_path,
                    line=lineno,
                    duration_s=duration,
                    raw_lines=current_lines[-5:],
                ))
                current_test = None
                current_lines = []

    return failures


def build_report(failures: list[TestFailure]) -> TriageReport:
    by_cat: dict[str, int] = {}
    for f in failures:
        by_cat[f.category] = by_cat.get(f.category, 0) + 1

    actionable = [f for f in failures if f.category in ("product", "environment")]
    flaky = [f for f in failures if f.category == "flaky"]
    infra = [f for f in failures if f.category == "infrastructure"]

    total = len(failures) or 1
    signal_ratio = len(actionable) / total

    lines = [f"Triage: {len(failures)} failures"]
    for cat, count in sorted(by_cat.items(), key=lambda x: -x[1]):
        lines.append(f"  {cat}: {count}")
    lines.append(f"Signal ratio: {signal_ratio:.0%} actionable")
    if flaky:
        lines.append(f"Flaky ops: {', '.join(set(f.test_name for f in flaky))}")

    return TriageReport(
        total_failures=len(failures),
        by_category=by_cat,
        actionable=actionable,
        flaky=flaky,
        infrastructure=infra,
        signal_ratio=signal_ratio,
        summary_text="\n".join(lines),
    )


def print_report(report: TriageReport, verbose: bool = False) -> None:
    print(report.summary_text)
    if report.actionable:
        print("\nActionable failures (product + environment):")
        for f in report.actionable:
            loc = f"{f.file_path}:{f.line}" if f.file_path else "unknown"
            print(f"  [{f.label}] {f.test_name}")
            print(f"    {loc}: {f.message[:120]}")
    if verbose and report.infrastructure:
        print("\nInfrastructure failures (not product bugs):")
        for f in report.infrastructure:
            print(f"  [{f.label}] {f.test_name}: {f.message[:80]}")


def main() -> None:
    parser = argparse.ArgumentParser(description="AI-assisted CI failure triage for iCloud tests")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_xcr = sub.add_parser("xcresult", help="Parse .xcresult bundle")
    p_xcr.add_argument("path", help=".xcresult path")
    p_xcr.add_argument("--json", action="store_true")
    p_xcr.add_argument("-v", "--verbose", action="store_true")

    p_log = sub.add_parser("log", help="Parse xcodebuild plain-text log")
    p_log.add_argument("path", help="Log file path")
    p_log.add_argument("--json", action="store_true")
    p_log.add_argument("-v", "--verbose", action="store_true")

    p_cat = sub.add_parser("categorize", help="Categorize a single failure message")
    p_cat.add_argument("message")

    args = parser.parse_args()

    if args.cmd in ("xcresult", "log"):
        if not Path(args.path).exists():
            sys.exit(f"Not found: {args.path}")
        failures = (parse_xcresult(args.path) if args.cmd == "xcresult"
                    else parse_log_file(args.path))
        report = build_report(failures)
        if args.json:
            print(json.dumps({
                "total": report.total_failures,
                "by_category": report.by_category,
                "signal_ratio": report.signal_ratio,
                "actionable": [asdict(f) for f in report.actionable],
            }, indent=2))
        else:
            print_report(report, verbose=args.verbose)
        sys.exit(1 if report.actionable else 0)

    elif args.cmd == "categorize":
        cat, label = categorize(args.message)
        print(f"{cat} / {label}")


if __name__ == "__main__":
    main()
