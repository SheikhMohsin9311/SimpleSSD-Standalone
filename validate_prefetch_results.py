#!/usr/bin/env python3
"""Validate prefetch statistics emitted by one or more simulator logs."""

import argparse
import math
import sys
from pathlib import Path


REQUIRED = (
    "page_mapping.cmt.prefetch_insertions",
    "page_mapping.cmt.prefetch_hits",
    "page_mapping.cmt.prefetch_evicted_unused",
    "page_mapping.cmt.prefetch_triggers",
    "page_mapping.cmt.prefetch_accuracy_percent",
    "page_mapping.cmt.prefetch_pollution_percent",
    "page_mapping.cmt.prefetch_coverage_percent",
    "page_mapping.cmt.prefetch_avg_batch_size",
)


def parse_log(path):
    values = {}
    with path.open(encoding="utf-8") as stream:
        for line in stream:
            fields = line.split()
            if len(fields) < 2:
                continue
            try:
                values[fields[0]] = float(fields[1])
            except ValueError:
                continue
    return values


def check_log(path, require_activity):
    values = parse_log(path)
    errors = []
    missing = [key for key in REQUIRED if key not in values]
    if missing:
        errors.append("missing metrics: " + ", ".join(missing))
        return errors

    insertions = values[REQUIRED[0]]
    hits = values[REQUIRED[1]]
    unused = values[REQUIRED[2]]
    triggers = values[REQUIRED[3]]
    if hits + unused > insertions:
        errors.append("prefetch hits plus unused evictions exceed insertions")
    if insertions > 0 and triggers == 0:
        errors.append("insertions are nonzero but triggers are zero")
    if triggers > 0 and values[REQUIRED[7]] <= 0:
        errors.append("triggers are nonzero but average batch size is not positive")
    for key in REQUIRED[4:7]:
        value = values[key]
        if not math.isfinite(value) or value < 0 or value > 100:
            errors.append(f"{key} is outside [0, 100]: {value}")
    if require_activity and insertions == 0:
        errors.append("prefetch-on run produced no insertions")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("logs", nargs="+", type=Path)
    parser.add_argument(
        "--require-activity",
        action="store_true",
        help="require at least one prefetch insertion in every supplied log",
    )
    parser.add_argument(
        "--check-off-runs",
        action="store_true",
        help="require zero prefetch counters for files whose name contains prefOFF",
    )
    args = parser.parse_args()

    failed = False
    for path in args.logs:
        if not path.is_file() or path.stat().st_size == 0:
            print(f"FAIL {path}: missing or empty log")
            failed = True
            continue
        errors = check_log(path, args.require_activity)
        if args.check_off_runs and "prefOFF" in path.name:
            values = parse_log(path)
            for key in REQUIRED[:4]:
                if values.get(key, 0) != 0:
                    errors.append(f"prefOFF has nonzero {key}: {values[key]}")
        if errors:
            print(f"FAIL {path}: " + "; ".join(errors))
            failed = True
        else:
            print(f"PASS {path}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())