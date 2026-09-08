#!/usr/bin/env python3
"""Warn about mapped PVs that MYA cannot serve at a given time.

Reads epics_column_pv_map.txt (the single source of truth), queries MYA
Point for each confirmed PV, prints ERROR/WARNING lines, and writes
snapshots/unavailable_<time>.txt. Does not write to hamoller.

  python check_archived_pvs.py --time "2025-07-10 12:08:06"
"""

from __future__ import annotations

import sys
from pathlib import Path

from epics_schema import load_mapped_columns
from fetch_epics_snapshot import (
    Point,
    build_parser,
    default_snapshot_paths,
    fetch_rows,
    parse_query_time,
    print_unavailable_warnings,
    problem_rows,
    to_mya_naive,
    write_unavailable_report,
)


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    parser.description = (
        "Report mapped PVs that are missing, disconnected, or not in MYA. "
        "Writes snapshots/unavailable_<time>.txt and prints ERROR/WARNING lines."
    )
    args = parser.parse_args(argv)
    columns = load_mapped_columns(args.map)

    if args.columns:
        wanted = {name.strip() for name in args.columns.split(",") if name.strip()}
        columns = [col for col in columns if col.column in wanted]
    if args.limit is not None:
        columns = columns[: args.limit]

    if Point is None:
        raise SystemExit(
            "jlab_archiver_client is not installed. "
            "Use python3.12, then: pip install -r requirements.txt"
        )

    query_time = parse_query_time(args, args.tz)
    mya_time = to_mya_naive(query_time)
    rows = fetch_rows(
        columns,
        mya_time,
        workers=args.workers,
        deployment=args.deployment,
        sig_figs=args.sig_figs,
        enums_as_strings=not args.enums_as_ints,
    )

    _, default_unavail = default_snapshot_paths(query_time, args.run_number)
    unavail_path = (
        Path(args.unavailable_output) if args.unavailable_output else default_unavail
    )
    unavail_path.parent.mkdir(parents=True, exist_ok=True)
    with unavail_path.open("w", encoding="utf-8") as handle:
        write_unavailable_report(
            handle,
            rows=rows,
            query_time=query_time,
            mya_time=mya_time,
            run_number=args.run_number,
        )
    print_unavailable_warnings(rows)
    problems = problem_rows(rows)
    print(
        f"Wrote {unavail_path}  ({len(problems)} problems of {len(rows)} mapped PVs)",
        file=sys.stderr,
    )
    return 1 if any(row.status == "query_error" for row in problems) else 0


if __name__ == "__main__":
    raise SystemExit(main())
