"""MariaDB helper for writing one EPICS_data row.

Credentials come from the four names in _ENV_NAMES (host, user, password,
database). Those are the variable names on the server, not the values.

Unavailable PVs stay NULL. Missing live columns are skipped. Neither
aborts the insert.
"""

from __future__ import annotations

import os
import re
import sys
from dataclasses import dataclass
from typing import Any, Iterable

from epics_schema import MappedColumn, coerce_value, parse_sql_type

# Live hamoller still has epics_n_pass until the proposed rename is applied.
COLUMN_ALIASES = {
    "epics_n_pass_halla": "epics_n_pass",
}

_IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
# Server env var names, in order: host, user, password, database.
_ENV_NAMES = ("DB_HOST", "DB_USER", "DB_PASS", "DB_NAME")


@dataclass(frozen=True)
class DbConfig:
    host: str
    user: str
    password: str
    database: str

    def missing(self) -> list[str]:
        values = (self.host, self.user, self.password, self.database)
        return [name for name, value in zip(_ENV_NAMES, values) if not value]

    def summary(self) -> str:
        return f"{self.user}@{self.host}/{self.database}"


def load_db_config() -> DbConfig:
    host_var, user_var, pass_var, name_var = _ENV_NAMES
    return DbConfig(
        host=os.environ.get(host_var, ""),
        user=os.environ.get(user_var, ""),
        password=os.environ.get(pass_var, ""),
        database=os.environ.get(name_var, ""),
    )


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)


def _ident(name: str) -> str:
    if not _IDENT.fullmatch(name):
        raise ValueError(f"unsafe SQL identifier: {name!r}")
    return f"`{name}`"


def connect(config: DbConfig):
    try:
        import pymysql
    except ImportError as exc:
        raise SystemExit(
            "PyMySQL is not installed. "
            "Use python3.12, then: pip install -r requirements.txt"
        ) from exc
    return pymysql.connect(
        host=config.host,
        user=config.user,
        password=config.password,
        database=config.database,
        charset="utf8mb4",
        autocommit=False,
        connect_timeout=10,
    )


def live_epics_columns(cursor) -> set[str]:
    cursor.execute(
        "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS "
        "WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'EPICS_data'"
    )
    return {row[0] for row in cursor.fetchall()}


def run_exists(cursor, table: str, run_number: int) -> bool:
    cursor.execute(
        f"SELECT 1 FROM {_ident(table)} WHERE run_number = %s LIMIT 1",
        (run_number,),
    )
    return cursor.fetchone() is not None


def resolve_live_column(mapped_name: str, live: set[str]) -> str | None:
    if mapped_name in live:
        return mapped_name
    alias = COLUMN_ALIASES.get(mapped_name)
    if alias and alias in live:
        return alias
    return None


def values_for_insert(
    rows: Iterable[Any],
    live: set[str],
) -> tuple[list[str], list[Any]]:
    """Map snapshot rows onto live EPICS_data columns. Unavailable → NULL."""
    columns: list[str] = []
    values: list[Any] = []
    used_live: set[str] = set()
    for row in rows:
        mapped: MappedColumn = row.mapped
        live_name = resolve_live_column(mapped.column, live)
        if live_name is None:
            fail(
                f"{mapped.column}  {mapped.pv}  not in EPICS_data; skipping"
            )
            continue
        if live_name in used_live:
            fail(
                f"{mapped.column}  {mapped.pv}  live column {live_name} "
                "already filled; skipping"
            )
            continue
        if live_name != mapped.column:
            fail(
                f"{mapped.column} not in EPICS_data; writing {live_name}"
            )
        value = row.coerced if row.status == "ok" else None
        columns.append(live_name)
        values.append(value)
        used_live.add(live_name)
    return columns, values


def insert_epics_row(
    run_number: int,
    rows: list[Any],
    *,
    force: bool = False,
    dry_run: bool = False,
) -> int:
    """Insert or update one EPICS_data row. Returns 0 on success / skip."""
    config = load_db_config()
    missing = config.missing()
    if missing:
        fail(
            "database env not set: "
            + ", ".join(missing)
            + "  (setenv " + " / ".join(_ENV_NAMES) + ")"
        )
        return 1

    try:
        connection = connect(config)
    except Exception as exc:  # noqa: BLE001 — print, do not traceback to the user
        fail(f"could not connect to {config.summary()}: {exc}")
        return 1

    action = "write"
    try:
        with connection.cursor() as cursor:
            live = live_epics_columns(cursor)
            if "run_number" not in live:
                fail("EPICS_data has no run_number column")
                return 1
            if not run_exists(cursor, "Run_info", run_number):
                fail(f"run {run_number} is not in Run_info; no insert")
                return 1

            columns, values = values_for_insert(rows, live)
            if not columns:
                fail("no mapped columns exist on EPICS_data; no insert")
                return 1

            exists = run_exists(cursor, "EPICS_data", run_number)
            if exists and not force:
                fail(
                    f"EPICS_data already has run {run_number}; "
                    "pass --force to overwrite"
                )
                return 1

            if exists:
                assignments = ", ".join(f"{_ident(name)} = %s" for name in columns)
                sql = (
                    f"UPDATE EPICS_data SET {assignments} "
                    f"WHERE run_number = %s"
                )
                params = [*values, run_number]
                action = "update"
            else:
                col_sql = ", ".join(
                    _ident(name) for name in ("run_number", *columns)
                )
                placeholders = ", ".join(["%s"] * (1 + len(columns)))
                sql = f"INSERT INTO EPICS_data ({col_sql}) VALUES ({placeholders})"
                params = [run_number, *values]
                action = "insert"

            nulls = sum(value is None for value in values)
            print(
                f"{'[dry-run] ' if dry_run else ''}"
                f"{action} run {run_number}  "
                f"{len(columns)} columns, {nulls} NULL  ({config.summary()})",
                file=sys.stderr,
            )
            if dry_run:
                print(sql, file=sys.stderr)
                return 0
            cursor.execute(sql, params)
        connection.commit()
    except Exception as exc:  # noqa: BLE001
        connection.rollback()
        fail(f"{action} failed: {exc}")
        return 1
    finally:
        connection.close()
    return 0


def snapshot_row_from_tsv(
    column: str,
    pv: str,
    sql_type: str,
    status: str,
    coerced_text: str,
    note: str,
    description: str,
):
    """Build a fetch-compatible row from a snapshot TSV line."""
    from fetch_epics_snapshot import SnapshotRow

    mapped = MappedColumn(
        column=column,
        pv=pv,
        description=description,
        sql_type=parse_sql_type(sql_type),
    )
    if coerced_text in ("", "NULL") or status != "ok":
        coerced = None
    else:
        parsed = coerce_value(coerced_text, mapped.sql_type)
        coerced = parsed.value if parsed.status == "ok" else None
        if parsed.status != "ok":
            status = parsed.status
            note = parsed.note or note
    return SnapshotRow(
        mapped=mapped,
        status=status,
        coerced=coerced,
        raw=None,
        archive_time="",
        mya_datatype="",
        note=note,
    )
