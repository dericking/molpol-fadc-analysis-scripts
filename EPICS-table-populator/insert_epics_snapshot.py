#!/usr/bin/env python3
"""Insert a saved EPICS snapshot TSV into hamoller_db.EPICS_data.

Reads snapshots/snapshot_*.txt (or any fetch TSV). Unavailable columns
are NULL. Missing live columns are skipped. Prints FAIL lines; does not
abort the row for those.

Credentials (dummy until set):

  setenv DB_HOST ""
  setenv DB_USER ""
  setenv DB_PASS ""
  setenv DB_NAME ""

  python insert_epics_snapshot.py --snapshot snapshots/snapshot_run12345_....txt
  python insert_epics_snapshot.py --snapshot ... --dry-run
  python insert_epics_snapshot.py --snapshot ... --force
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from epics_db import fail, insert_epics_row, snapshot_row_from_tsv
from fetch_epics_snapshot import SnapshotRow, print_unavailable_warnings, problem_rows


def parse_snapshot_tsv(path: Path) -> tuple[int | None, list[SnapshotRow]]:
    run_number: int | None = None
    rows: list[SnapshotRow] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("#"):
            body = line[1:].strip()
            if body.startswith("run_number\t"):
                text = body.split("\t", 1)[1].strip()
                if text:
                    run_number = int(text)
            continue
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 6:
            fail(f"bad snapshot line (need column, pv, type, status, value): {line!r}")
            continue
        column, pv, sql_type, status, coerced_text = parts[:5]
        description = parts[8] if len(parts) > 8 else ""
        note = parts[9] if len(parts) > 9 else ""
        rows.append(
            snapshot_row_from_tsv(
                column=column,
                pv=pv,
                sql_type=sql_type,
                status=status,
                coerced_text=coerced_text,
                note=note,
                description=description,
            )
        )
    return run_number, rows


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Insert one snapshot TSV into EPICS_data. Does not query MYA."
    )
    parser.add_argument(
        "--snapshot",
        required=True,
        type=Path,
        help="Path to snapshots/snapshot_*.txt from fetch_epics_snapshot.py.",
    )
    parser.add_argument(
        "--run-number",
        type=int,
        help="EPICS_data.run_number (default: # run_number in the snapshot header).",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print the SQL and do not write.",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Overwrite an existing EPICS_data row for this run.",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if not args.snapshot.is_file():
        fail(f"snapshot not found: {args.snapshot}")
        return 1

    header_run, rows = parse_snapshot_tsv(args.snapshot)
    run_number = args.run_number if args.run_number is not None else header_run
    if run_number is None:
        fail("pass --run-number (snapshot header has none)")
        return 1

    print_unavailable_warnings(rows, inserting=True)
    problems = problem_rows(rows)
    print(
        f"Read {args.snapshot}  ({len(rows)} PVs, {len(problems)} unavailable → NULL)",
        file=sys.stderr,
    )
    return insert_epics_row(
        run_number,
        rows,
        force=args.force,
        dry_run=args.dry_run,
    )


if __name__ == "__main__":
    raise SystemExit(main())
