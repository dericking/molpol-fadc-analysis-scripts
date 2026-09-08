#!/usr/bin/env python3
"""Fetch a per-run EPICS snapshot from MYA and write a typed text report.

Queries jlab_archiver_client Point (value at or before the given time) for
every confirmed column↔PV pair, coerces each value to Don's EPICS_data type,
and writes a TSV. Missing / disconnect / type-mismatch values are NULL.

Run this onsite (or on a host that can reach epicsweb.jlab.org/myquery).
Python ≥ 3.11 (use python3.12 on the JLab server). Does not write to hamoller.

Example:
  python3.12 fetch_epics_snapshot.py --time "2026-03-15 14:32:00" -o snapshot.txt
  python3.12 fetch_epics_snapshot.py --unix 1742058720 --run-number 12345
"""

from __future__ import annotations

import argparse
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, TextIO
from zoneinfo import ZoneInfo

from requests import RequestException

from epics_schema import (
    DEFAULT_MAP,
    DEFAULT_PROBLEMS_DIR,
    DEFAULT_SNAPSHOT_DIR,
    MappedColumn,
    coerce_value,
    load_mapped_columns,
)

PROBLEM_LEVELS = {
    "query_error": "ERROR",
    "type_mismatch": "ERROR",
    "overflow": "ERROR",
    "missing": "WARNING",
    "disconnect": "WARNING",
}

try:
    from jlab_archiver_client import Point, PointQuery
except ImportError:
    Point = None  # type: ignore[misc, assignment]
    PointQuery = None  # type: ignore[misc, assignment]

DEFAULT_TZ = "America/New_York"
NULL = "NULL"


@dataclass
class SnapshotRow:
    mapped: MappedColumn
    status: str
    coerced: Any
    raw: Any
    archive_time: str
    mya_datatype: str
    note: str


_TIME_FORMATS = (
    "%Y-%m-%d %H:%M:%S",
    "%Y-%m-%d %H:%M",
    "%a %b %d %H:%M:%S %Y",  # ctime: Mon Aug 17 15:43:02 2026
    "%a %b %d %H:%M:%S %Y %Z",
    "%a %b %d %I:%M:%S %p %Y",  # Thu Jul 10 12:08:06 PM 2025
    "%a %b %d %I:%M:%S %p %Z %Y",  # Thu Jul 10 12:08:06 PM EDT 2025
)


def parse_query_time(args: argparse.Namespace, tz_name: str) -> datetime:
    zone = ZoneInfo(tz_name)
    if args.time and args.unix is not None:
        raise SystemExit("Pass only one of --time or --unix")
    if args.unix is not None:
        return datetime.fromtimestamp(args.unix, tz=zone)
    if not args.time:
        raise SystemExit("Pass --time (JLab local / ISO) or --unix")
    text = args.time.strip()
    parsed: datetime | None = None
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        for fmt in _TIME_FORMATS:
            try:
                parsed = datetime.strptime(text, fmt)
                break
            except ValueError:
                continue
    if parsed is None:
        raise SystemExit(
            "Could not parse --time. Use 'YYYY-MM-DD HH:MM:SS', ISO, "
            "ctime like 'Mon Aug 17 15:43:02 2026', or "
            "'Thu Jul 10 12:08:06 PM EDT 2025' (JLab local)."
        )
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=zone)
    return parsed.astimezone(zone)


def to_mya_naive(dt: datetime) -> datetime:
    """MYA point queries take a naive local timestamp (JLab server time)."""
    if dt.tzinfo is None:
        return dt.replace(microsecond=0)
    return dt.astimezone(ZoneInfo(DEFAULT_TZ)).replace(tzinfo=None, microsecond=0)


def _event_value(event: dict[str, Any] | None) -> tuple[Any, str, str, str]:
    """Return (raw, archive_time, datatype, disconnect_or_empty note)."""
    if not event:
        return None, "", "", "empty MYA response"
    datatype = str(event.get("datatype") or "")
    data = event.get("data")
    if not isinstance(data, dict):
        return None, "", datatype, "no data object in MYA response"
    archive_time = str(data.get("d") or "")
    if "v" not in data:
        tag = data.get("t")
        if tag:
            return None, archive_time, datatype, f"non-update event: {tag}"
        return None, archive_time, datatype, "no value in MYA response"
    raw = data.get("v")
    if raw is None:
        tag = data.get("t")
        note = f"non-update event: {tag}" if tag else "MYA value is empty"
        return None, archive_time, datatype, note
    return raw, archive_time, datatype, ""


def query_point(
    mapped: MappedColumn,
    when: datetime,
    *,
    deployment: str,
    sig_figs: int,
    enums_as_strings: bool,
) -> SnapshotRow:
    query = PointQuery(
        channel=mapped.pv,
        time=when,
        deployment=deployment,
        sig_figs=sig_figs,
        enums_as_strings=enums_as_strings,
    )
    point = Point(query)
    try:
        point.run()
    except RequestException as exc:
        return SnapshotRow(
            mapped=mapped,
            status="query_error",
            coerced=None,
            raw=None,
            archive_time="",
            mya_datatype="",
            note=str(exc),
        )
    except Exception as exc:  # noqa: BLE001 — surface unexpected client errors
        return SnapshotRow(
            mapped=mapped,
            status="query_error",
            coerced=None,
            raw=None,
            archive_time="",
            mya_datatype="",
            note=f"{type(exc).__name__}: {exc}",
        )

    raw, archive_time, datatype, empty_note = _event_value(point.event)
    if raw is None:
        status = "disconnect" if empty_note.startswith("non-update") else "missing"
        return SnapshotRow(
            mapped=mapped,
            status=status,
            coerced=None,
            raw=None,
            archive_time=archive_time,
            mya_datatype=datatype,
            note=empty_note,
        )

    coerced = coerce_value(raw, mapped.sql_type)
    status = coerced.status if coerced.status != "empty" else "missing"
    if coerced.status == "ok":
        status = "ok"
    return SnapshotRow(
        mapped=mapped,
        status=status,
        coerced=coerced.value,
        raw=raw,
        archive_time=archive_time,
        mya_datatype=datatype,
        note=coerced.note,
    )


def fetch_rows(
    columns: list[MappedColumn],
    when: datetime,
    *,
    workers: int,
    deployment: str,
    sig_figs: int,
    enums_as_strings: bool,
) -> list[SnapshotRow]:
    rows: dict[str, SnapshotRow] = {}
    with ThreadPoolExecutor(max_workers=max(1, workers)) as pool:
        futures = {
            pool.submit(
                query_point,
                mapped,
                when,
                deployment=deployment,
                sig_figs=sig_figs,
                enums_as_strings=enums_as_strings,
            ): mapped.column
            for mapped in columns
        }
        for future in as_completed(futures):
            row = future.result()
            rows[row.mapped.column] = row
    return [rows[mapped.column] for mapped in columns]


def format_cell(value: Any) -> str:
    if value is None:
        return NULL
    if isinstance(value, float):
        return f"{value:.10g}"
    return str(value).replace("\t", " ").replace("\n", " ")


def write_report(
    out: TextIO,
    *,
    rows: list[SnapshotRow],
    query_time: datetime,
    mya_time: datetime,
    args: argparse.Namespace,
) -> None:
    counts: dict[str, int] = {}
    for row in rows:
        counts[row.status] = counts.get(row.status, 0) + 1

    utc = query_time.astimezone(timezone.utc)
    out.write("# MolPol EPICS snapshot (MYA point-in-time)\n")
    out.write(f"# query_time_local\t{query_time.isoformat()}\n")
    out.write(f"# query_time_utc\t{utc.isoformat()}\n")
    out.write(f"# mya_query_time\t{mya_time.strftime('%Y-%m-%d %H:%M:%S')} (naive JLab local)\n")
    out.write(f"# unix\t{int(query_time.timestamp())}\n")
    if args.run_number is not None:
        out.write(f"# run_number\t{args.run_number}\n")
    out.write(f"# deployment\t{args.deployment}\n")
    out.write(f"# pvs_requested\t{len(rows)}\n")
    for status in ("ok", "missing", "disconnect", "type_mismatch", "overflow", "query_error"):
        out.write(f"# {status}\t{counts.get(status, 0)}\n")
    out.write("#\n")
    out.write(
        "# column\tpv\tsql_type\tstatus\tcoerced_value\traw_value\t"
        "archive_time\tmya_datatype\tdescription\tnote\n"
    )
    for row in rows:
        mapped = row.mapped
        out.write(
            "\t".join(
                [
                    mapped.column,
                    mapped.pv,
                    mapped.sql_type.sql,
                    row.status,
                    format_cell(row.coerced),
                    format_cell(row.raw),
                    row.archive_time or NULL,
                    row.mya_datatype or NULL,
                    mapped.description.replace("\t", " "),
                    row.note.replace("\t", " ").replace("\n", " "),
                ]
            )
            + "\n"
        )


def snapshot_stem(query_time: datetime, run_number: int | None) -> str:
    stamp = query_time.strftime("%Y%m%d_%H%M%S")
    if run_number is not None:
        return f"run{run_number}_{stamp}"
    return stamp


def default_snapshot_paths(
    query_time: datetime, run_number: int | None
) -> tuple[Path, Path]:
    DEFAULT_SNAPSHOT_DIR.mkdir(parents=True, exist_ok=True)
    DEFAULT_PROBLEMS_DIR.mkdir(parents=True, exist_ok=True)
    stem = snapshot_stem(query_time, run_number)
    return (
        DEFAULT_SNAPSHOT_DIR / f"snapshot_{stem}.txt",
        DEFAULT_PROBLEMS_DIR / f"unavailable_{stem}.txt",
    )


def problem_rows(rows: list[SnapshotRow]) -> list[SnapshotRow]:
    return [row for row in rows if row.status in PROBLEM_LEVELS]


def write_unavailable_report(
    out: TextIO,
    *,
    rows: list[SnapshotRow],
    query_time: datetime,
    mya_time: datetime,
    run_number: int | None,
) -> None:
    problems = problem_rows(rows)
    out.write("# Unavailable / problem PVs from epics_column_pv_map.txt\n")
    out.write(f"# query_time_local\t{query_time.isoformat()}\n")
    out.write(f"# mya_query_time\t{mya_time.strftime('%Y-%m-%d %H:%M:%S')}\n")
    if run_number is not None:
        out.write(f"# run_number\t{run_number}\n")
    out.write(f"# problem_count\t{len(problems)}\n")
    out.write("#\n")
    out.write(
        f"{'level':<8}  {'status':<14}  {'column':<28}  {'pv':<32}  note\n"
    )
    for row in problems:
        level = PROBLEM_LEVELS[row.status]
        out.write(
            f"{level:<8}  {row.status:<14}  {row.mapped.column:<28}  "
            f"{row.mapped.pv:<32}  {row.note}\n"
        )


def print_unavailable_warnings(rows: list[SnapshotRow]) -> None:
    for row in problem_rows(rows):
        level = PROBLEM_LEVELS[row.status]
        print(
            f"{level}: {row.status}  {row.mapped.column}  {row.mapped.pv}  {row.note}",
            file=sys.stderr,
        )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Query MYA for one EPICS_data snapshot at (or before) a run start "
            "and write a typed TSV. Does not insert into MariaDB."
        )
    )
    parser.add_argument(
        "--time",
        help=(
            "Run start as 'YYYY-MM-DD HH:MM:SS', ISO, ctime, or "
            "12-hour with optional TZ ('Thu Jul 10 12:08:06 PM EDT 2025'). "
            "Naive times are JLab local."
        ),
    )
    parser.add_argument(
        "--unix",
        type=int,
        help="Run start as Unix seconds (converted to America/New_York).",
    )
    parser.add_argument(
        "--tz",
        default=DEFAULT_TZ,
        help=f"Timezone for naive --time and --unix (default: {DEFAULT_TZ}).",
    )
    parser.add_argument("--run-number", type=int, help="Optional run number for the report header.")
    parser.add_argument(
        "-o",
        "--output",
        help="Full snapshot TSV path (default: snapshots/snapshot_<time>.txt).",
    )
    parser.add_argument(
        "--unavailable-output",
        help=(
            "Warning/error report path "
            "(default: snapshots/problems/unavailable_<time>.txt)."
        ),
    )
    parser.add_argument("--map", type=Path, default=DEFAULT_MAP, help="Column↔PV map.")
    parser.add_argument(
        "--limit",
        type=int,
        help="Query only the first N mapped PVs (smoke test).",
    )
    parser.add_argument(
        "--columns",
        help="Comma-separated EPICS_data column names to query (subset).",
    )
    parser.add_argument("--workers", type=int, default=8, help="Parallel Point queries (default: 8).")
    parser.add_argument("--deployment", default="history", help="MYA deployment (default: history).")
    parser.add_argument(
        "--sig-figs",
        type=int,
        default=10,
        help="Significant figures requested from myquery (default: 10).",
    )
    parser.add_argument(
        "--enums-as-ints",
        action="store_true",
        help="Ask MYA for enum integers instead of labels (default: labels).",
    )
    parser.add_argument(
        "--list-map",
        action="store_true",
        help="Print the confirmed column↔PV map and exit (no MYA query).",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    columns = load_mapped_columns(args.map)

    if args.columns:
        wanted = {name.strip() for name in args.columns.split(",") if name.strip()}
        unknown = wanted - {col.column for col in columns}
        if unknown:
            parser.error("Unknown --columns: " + ", ".join(sorted(unknown)))
        columns = [col for col in columns if col.column in wanted]
    if args.limit is not None:
        columns = columns[: args.limit]

    if args.list_map:
        print(f"# {len(columns)} confirmed column↔PV pairs")
        print("column\tpv\tsql_type\tdescription")
        for col in columns:
            print(f"{col.column}\t{col.pv}\t{col.sql_type.sql}\t{col.description}")
        return 0

    if Point is None or PointQuery is None:
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

    default_snap, default_unavail = default_snapshot_paths(query_time, args.run_number)
    out_path = Path(args.output) if args.output else default_snap
    unavail_path = (
        Path(args.unavailable_output) if args.unavailable_output else default_unavail
    )
    out_path.parent.mkdir(parents=True, exist_ok=True)
    unavail_path.parent.mkdir(parents=True, exist_ok=True)

    with out_path.open("w", encoding="utf-8") as handle:
        write_report(
            handle,
            rows=rows,
            query_time=query_time,
            mya_time=mya_time,
            args=args,
        )
    with unavail_path.open("w", encoding="utf-8") as handle:
        write_unavailable_report(
            handle,
            rows=rows,
            query_time=query_time,
            mya_time=mya_time,
            run_number=args.run_number,
        )
    print_unavailable_warnings(rows)

    counts: dict[str, int] = {}
    for row in rows:
        counts[row.status] = counts.get(row.status, 0) + 1
    summary = ", ".join(
        f"{status}={counts.get(status, 0)}"
        for status in ("ok", "missing", "disconnect", "type_mismatch", "overflow", "query_error")
    )
    print(f"Wrote {out_path}  ({len(rows)} PVs; {summary})", file=sys.stderr)
    print(f"Wrote {unavail_path}  ({len(problem_rows(rows))} problems)", file=sys.stderr)
    return 0 if counts.get("query_error", 0) == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
