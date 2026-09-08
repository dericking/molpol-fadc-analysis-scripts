"""Parse the EPICS column↔PV map and coerce MYA values to Don's EPICS_data types."""

from __future__ import annotations

import math
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
DEFAULT_MAP = HERE / "epics_column_pv_map.txt"
DEFAULT_TYPES = HERE / "epics_column_types.txt"

_SQL_RE = re.compile(
    r"^(?P<base>FLOAT|DECIMAL|DOUBLE|TINYINT|INT|VARCHAR|CHAR)"
    r"(?:\((?P<args>[^)]+)\))?$",
    re.IGNORECASE,
)

_TRUE = {"1", "true", "t", "on", "yes"}
_FALSE = {"0", "false", "f", "off", "no"}


@dataclass(frozen=True)
class ColumnType:
    sql: str
    kind: str  # float | decimal | flag | text
    max_length: int | None = None


@dataclass(frozen=True)
class MappedColumn:
    column: str
    pv: str
    description: str
    sql_type: ColumnType


@dataclass(frozen=True)
class CoercedValue:
    value: Any
    status: str  # ok | empty | type_mismatch | overflow
    note: str = ""


def _skip_line(line: str) -> bool:
    stripped = line.strip()
    return not stripped or stripped.startswith("#")


def load_column_pv_map(path: Path = DEFAULT_MAP) -> list[tuple[str, str, str]]:
    """Return (column, pv, description) for confirmed map rows."""
    rows: list[tuple[str, str, str]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if _skip_line(line):
            continue
        parts = line.split("\t")
        if len(parts) < 2:
            raise ValueError(f"Bad map line (need column and PV): {line!r}")
        column = parts[0].strip()
        pv = parts[1].strip()
        description = parts[2].strip() if len(parts) > 2 else ""
        rows.append((column, pv, description))
    return rows


def parse_sql_type(sql: str) -> ColumnType:
    match = _SQL_RE.match(sql.strip())
    if not match:
        raise ValueError(f"Unrecognized SQL type: {sql!r}")
    base = match.group("base").upper()
    args = match.group("args")
    if base in {"FLOAT", "DOUBLE"}:
        return ColumnType(sql=sql.strip(), kind="float")
    if base == "DECIMAL":
        return ColumnType(sql=sql.strip(), kind="decimal")
    if base == "TINYINT":
        return ColumnType(sql=sql.strip(), kind="flag")
    if base == "INT":
        return ColumnType(sql=sql.strip(), kind="integer")
    if base in {"VARCHAR", "CHAR"}:
        max_length = int(args) if args else None
        return ColumnType(sql=sql.strip(), kind="text", max_length=max_length)
    raise ValueError(f"Unsupported SQL type: {sql!r}")


def load_column_types(path: Path = DEFAULT_TYPES) -> dict[str, ColumnType]:
    types: dict[str, ColumnType] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if _skip_line(line):
            continue
        parts = line.split("\t")
        if len(parts) < 2:
            raise ValueError(f"Bad type line (need column and SQL type): {line!r}")
        types[parts[0].strip()] = parse_sql_type(parts[1].strip())
    return types


def load_mapped_columns(
    map_path: Path = DEFAULT_MAP,
    types_path: Path = DEFAULT_TYPES,
) -> list[MappedColumn]:
    types = load_column_types(types_path)
    mapped: list[MappedColumn] = []
    missing: list[str] = []
    for column, pv, description in load_column_pv_map(map_path):
        sql_type = types.get(column)
        if sql_type is None:
            missing.append(column)
            continue
        mapped.append(
            MappedColumn(
                column=column,
                pv=pv,
                description=description,
                sql_type=sql_type,
            )
        )
    if missing:
        raise ValueError(
            "Columns in the PV map have no SQL type in "
            f"{types_path.name}: {', '.join(missing)}"
        )
    extra = sorted(set(types) - {row.column for row in mapped})
    if extra:
        raise ValueError(
            "SQL types file has columns not in the PV map: " + ", ".join(extra)
        )
    return mapped


def coerce_value(raw: Any, sql_type: ColumnType) -> CoercedValue:
    """Light coerce of a MYA scalar into Don's column type. Empty → NULL."""
    if raw is None:
        return CoercedValue(None, "empty", "MYA value is empty")
    if isinstance(raw, str) and not raw.strip():
        return CoercedValue(None, "empty", "MYA value is blank")
    if isinstance(raw, (list, tuple, dict)):
        return CoercedValue(None, "type_mismatch", "expected a scalar, got a vector/object")

    if sql_type.kind in {"float", "decimal"}:
        return _coerce_number(raw)
    if sql_type.kind == "flag":
        return _coerce_flag(raw)
    if sql_type.kind == "integer":
        return _coerce_integer(raw)
    if sql_type.kind == "text":
        return _coerce_text(raw, sql_type.max_length)
    return CoercedValue(None, "type_mismatch", f"unknown kind {sql_type.kind}")


def _coerce_number(raw: Any) -> CoercedValue:
    if isinstance(raw, bool):
        return CoercedValue(None, "type_mismatch", "boolean is not a numeric PV value")
    if isinstance(raw, (int, float)):
        number = float(raw)
    else:
        text = str(raw).strip()
        try:
            number = float(text)
        except ValueError:
            return CoercedValue(None, "type_mismatch", f"not numeric: {text!r}")
    if not math.isfinite(number):
        return CoercedValue(None, "type_mismatch", "non-finite number")
    return CoercedValue(number, "ok")


def _coerce_integer(raw: Any) -> CoercedValue:
    number = _coerce_number(raw)
    if number.status != "ok":
        return number
    value = number.value
    if not float(value).is_integer():
        return CoercedValue(None, "type_mismatch", f"not an integer: {value}")
    return CoercedValue(int(value), "ok")


def _coerce_flag(raw: Any) -> CoercedValue:
    if isinstance(raw, bool):
        return CoercedValue(int(raw), "ok")
    if isinstance(raw, (int, float)) and not isinstance(raw, bool):
        if raw in (0, 1, 0.0, 1.0):
            return CoercedValue(int(raw), "ok")
        return CoercedValue(None, "type_mismatch", f"flag not 0/1: {raw}")
    text = str(raw).strip().lower()
    if text in _TRUE:
        return CoercedValue(1, "ok")
    if text in _FALSE:
        return CoercedValue(0, "ok")
    return CoercedValue(None, "type_mismatch", f"flag not 0/1: {raw!r}")


def _coerce_text(raw: Any, max_length: int | None) -> CoercedValue:
    if isinstance(raw, bool):
        text = "1" if raw else "0"
    elif isinstance(raw, float) and raw.is_integer():
        text = str(int(raw))
    else:
        text = str(raw).strip()
    if not text:
        return CoercedValue(None, "empty", "MYA value is blank")
    if max_length is not None and len(text) > max_length:
        return CoercedValue(
            None,
            "overflow",
            f"length {len(text)} exceeds VARCHAR({max_length})",
        )
    return CoercedValue(text, "ok")
