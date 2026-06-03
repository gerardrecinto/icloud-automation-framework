#!/usr/bin/env python3
"""
Test coverage gap analyzer for Swift automation frameworks.
Scans source files for public functions/methods and cross-references
against test files to find untested surface area.
"""

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass
class Symbol:
    name: str
    file_path: str
    line: int
    kind: str  # "func" | "class" | "actor"
    is_public: bool


def extract_symbols(source_dir: str) -> list[Symbol]:
    symbols = []
    func_pattern = re.compile(
        r"^\s*(public|open|internal)?\s*(func|class func|static func)\s+(\w+)\s*[\(<]",
        re.MULTILINE,
    )
    type_pattern = re.compile(
        r"^\s*(public|open)?\s*(class|struct|actor|enum)\s+(\w+)",
        re.MULTILINE,
    )

    for path in sorted(Path(source_dir).rglob("*.swift")):
        content = path.read_text(encoding="utf-8")
        for m in func_pattern.finditer(content):
            access = m.group(1) or "internal"
            symbols.append(Symbol(
                name=m.group(3),
                file_path=str(path),
                line=content[: m.start()].count("\n") + 1,
                kind="func",
                is_public=access in ("public", "open"),
            ))
        for m in type_pattern.finditer(content):
            access = m.group(1) or "internal"
            symbols.append(Symbol(
                name=m.group(3),
                file_path=str(path),
                line=content[: m.start()].count("\n") + 1,
                kind=m.group(2),
                is_public=access in ("public", "open"),
            ))
    return symbols


def extract_tested_names(test_dir: str) -> set[str]:
    tested: set[str] = set()
    call_pattern = re.compile(r"\b(\w+)\s*\(")
    type_ref = re.compile(r"\b([A-Z]\w+)\b")

    for path in Path(test_dir).rglob("*.swift"):
        content = path.read_text(encoding="utf-8")
        for m in call_pattern.finditer(content):
            tested.add(m.group(1))
        for m in type_ref.finditer(content):
            tested.add(m.group(1))
    return tested


def find_gaps(symbols: list[Symbol], tested: set[str]) -> list[Symbol]:
    # Only public symbols matter for coverage gap analysis
    return [s for s in symbols if s.is_public and s.name not in tested]


def compute_coverage(symbols: list[Symbol], tested: set[str]) -> float:
    public_syms = [s for s in symbols if s.is_public]
    if not public_syms:
        return 100.0
    covered = sum(1 for s in public_syms if s.name in tested)
    return (covered / len(public_syms)) * 100


def main() -> None:
    parser = argparse.ArgumentParser(description="Swift test coverage gap analyzer")
    parser.add_argument("--source", required=True, help="Source directory")
    parser.add_argument("--tests", required=True, help="Tests directory")
    parser.add_argument("--min-coverage", type=float, default=80.0,
                        help="Minimum coverage %% required (default: 80)")
    parser.add_argument("--show-gaps", action="store_true",
                        help="List untested public symbols")
    args = parser.parse_args()

    symbols = extract_symbols(args.source)
    tested = extract_tested_names(args.tests)
    coverage = compute_coverage(symbols, tested)
    gaps = find_gaps(symbols, tested)

    print(f"Public symbols: {sum(1 for s in symbols if s.is_public)}")
    print(f"Coverage:       {coverage:.1f}%  (threshold: {args.min_coverage}%)")
    print(f"Gaps:           {len(gaps)} untested public symbols")

    if args.show_gaps and gaps:
        print("\nUntested public symbols:")
        for g in gaps[:20]:
            print(f"  {g.kind} {g.name}  ({Path(g.file_path).name}:{g.line})")
        if len(gaps) > 20:
            print(f"  ... and {len(gaps) - 20} more")

    if coverage < args.min_coverage:
        print(f"\nFAIL: coverage {coverage:.1f}% < minimum {args.min_coverage}%")
        sys.exit(1)
    else:
        print(f"\nPASS: coverage {coverage:.1f}% >= minimum {args.min_coverage}%")


if __name__ == "__main__":
    main()
