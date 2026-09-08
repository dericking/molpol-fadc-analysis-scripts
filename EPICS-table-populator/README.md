# Hall A Møller EPICS → hamoller insert

Fill `hamoller_db.EPICS_data` with a **per-run snapshot** of EPICS PVs from
the JLab MYA archiver. This is a **writer**. The FADC web dashboard is
read-only and must not grow insert logic, credentials with write access, or
archiver clients.

## Current status

`epics_column_pv_map.txt` is the **single source of truth** (column, PV,
SQL type, description). Fetch writes a full snapshot under `snapshots/`
and an unavailable-PV report under `snapshots/problems/`. Unavailable
PVs print as `FAIL` and become `NULL`; they do not abort the run.
`--insert` writes `EPICS_data` using the four names in
`epics_db.py` (`_ENV_NAMES`).

## How the scripts fit together

This directory is a small **writer stack**: map → archive query → typed
text backup → MariaDB. The pieces are meant to be reused. Swap the map
(and env names) for another table, or import the libraries from your
own CLI / cron / analysis job. Leave the FADC dashboard out of this
path; it stays SELECT-only.

```
epics_column_pv_map.txt          contract: column, PV, SQL type, description
        │
        ▼
epics_schema.py                  parse map, coerce scalars (no MYA, no DB)
        │
        ├──────────────────────────────┐
        ▼                              ▼
fetch_epics_snapshot.py         check_archived_pvs.py
  MYA Point (at or before t)      same query, problems file only
        │
        ├─ snapshots/snapshot_*.txt          full typed TSV (insert backup)
        └─ snapshots/problems/unavailable_*  FAIL rows
        │
        ├── --insert ──────────────────┐
        ▼                              ▼
insert_epics_snapshot.py            epics_db.py
  read a saved TSV                    connect, match live columns, INSERT/UPDATE
        │                              │
        └──────────────┬───────────────┘
                       ▼
                 hamoller_db.EPICS_data
                 (FK: run_number → Run_info)
```

| Layer | File | Job | Import if you build your own |
|---|---|---|---|
| Contract | `epics_column_pv_map.txt` | One row per column to fill. Comments (`#`) are skipped. | Point `--map` at your copy. |
| Types | `epics_schema.py` | `load_mapped_columns()`, `coerce_value()`. Empty / bad → `NULL`. | Yes. No network. |
| Archive | `fetch_epics_snapshot.py` | `Point` query, write snapshot + problems, optional `--insert`. | `fetch_rows()`, `parse_query_time()`, `SnapshotRow`. |
| Health | `check_archived_pvs.py` | Same MYA query; print `FAIL`; write problems file. Does not insert. | Optional cron check. |
| DB | `epics_db.py` | Env credentials, live `INFORMATION_SCHEMA`, insert/update. | `insert_epics_row()`. |
| Replay | `insert_epics_snapshot.py` | TSV → `insert_epics_row()`. No second MYA hit. | Use when hamoller was down. |

At runtime, this one command fills `EPICS_data` for a run (MYA snapshot
plus insert). `{DATE}` is the run start; `{RUN_NUMBER}` must already
exist in `Run_info`:

```tcsh
python fetch_epics_snapshot.py --time "{DATE}" --run-number {RUN_NUMBER} --insert
```

That is **write path A** (used for run 559). `--dry-run` does the same
without writing. `--force` overwrites an existing row.

**Write path B** — fetch now, insert later (or retry):

```tcsh
python fetch_epics_snapshot.py --time "..." --run-number N
python insert_epics_snapshot.py --snapshot snapshots/snapshot_runN_*.txt
```

Rules the stack already enforces (keep these if you fork it):

- Unavailable PVs print `FAIL` and become `NULL`. The row still writes.
- `Run_info` must already have that `run_number`.
- Existing `EPICS_data` rows are not overwritten unless `--force`.
- Columns missing on the live table are skipped. `COLUMN_ALIASES` in
  `epics_db.py` maps `epics_n_pass_halla` → `epics_n_pass` until the
  rename is applied.
- Credentials are **server environment variables**, not files in git.
  Change the names in `_ENV_NAMES` (host, user, password, database).

To incorporate this in another project: copy the directory (or add it
as a git subtree), keep `epics_schema.py` / `epics_db.py` / the fetch
helpers as libraries, and replace `epics_column_pv_map.txt`. Your
wrapper only needs a run number and a start time. `--dry-run` prints
the SQL without writing.

## Fetch a snapshot (test onsite)

`jlab_archiver_client` needs Python ≥ 3.11. On the JLab server use **`python3.12`**
explicitly — do not rely on `python3`, which may point at a different
minor version. `python3.14` also meets the requirement, but 3.12 is the
safer pin for pandas/numpy wheels. Confirm with `python3.12 --version`.

Needs a host that can reach `epicsweb.jlab.org` (onsite; the client does
not support offsite auth).

**Shells by account** (do not mix them up):

| Account | Login shell | Venv activate |
|---------|-------------|----------------|
| `a-molana` (development on `aonl1`, etc.) | **tcsh** | `source .venv/bin/activate.csh` |
| `hamoller` | **bash** | `source .venv/bin/activate` |

A lot of existing a-molana tooling is tcsh-specific. Keep examples and
helper scripts working in tcsh when they will be run as `a-molana`.
Sourcing the bash `activate` script under tcsh fails with
`Badly placed ()'s`. Calling the venv binaries directly
(`.venv/bin/python`, `.venv/bin/pip`) works in either shell.

`python3.12 -m venv .venv` creates the environment **once**. After that,
each new login only needs activate. `exit` leaves the SSH session, not
the venv — use `deactivate` to drop back to the system Python.

```tcsh
# a-molana / tcsh — one-time setup
cd EPICS-table-populator
python3.12 -m venv .venv
source .venv/bin/activate.csh
python --version          # 3.12.x, not the system 3.9 python3
pip install -r requirements.txt
```

```tcsh
# a-molana / tcsh — each later login
cd EPICS-table-populator
source .venv/bin/activate.csh
```

```bash
# hamoller / bash
source .venv/bin/activate
```

If you would rather not activate at all:

```tcsh
.venv/bin/pip install -r requirements.txt
.venv/bin/python fetch_epics_snapshot.py --list-map
```

```tcsh
# Inspect the mapped pairs without querying MYA
python fetch_epics_snapshot.py --list-map

# Snapshot in snapshots/; problems in snapshots/problems/
python fetch_epics_snapshot.py --time "Thu Jul 10 12:08:06 PM EDT 2025" --run-number 12345

# Same, then insert (unavailable PVs → NULL)
python fetch_epics_snapshot.py --time "Thu Jul 10 12:08:06 PM EDT 2025" --run-number 12345 --insert --dry-run
python fetch_epics_snapshot.py --time "Thu Jul 10 12:08:06 PM EDT 2025" --run-number 12345 --insert

# Insert a snapshot already on disk
python insert_epics_snapshot.py --snapshot snapshots/snapshot_run12345_20250710_120806.txt --dry-run

# Warnings/errors only for mapped PVs MYA cannot serve
python check_archived_pvs.py --time "Thu Jul 10 12:08:06 PM EDT 2025"

# Same, from Run_info.run_start_unix
python fetch_epics_snapshot.py --unix 1742058720 --run-number 12345

# Smoke test a handful of PVs
python fetch_epics_snapshot.py --time "2025-07-10 12:08:06" --limit 5
```

`--time` without a timezone is `America/New_York`. The MYA **point** query
returns the event **at or before** that timestamp (same idea as the old ADC
`.set` print). Empty, disconnect, and type-mismatch values are written as
`NULL` plus a `FAIL` line — nothing is invented, and the process does not
exit for those.

## Database insert

Dummy env (fill these in before `--insert`; they start empty):

```tcsh
setenv DB_HOST ""
setenv DB_USER ""
setenv DB_PASS ""
setenv DB_NAME ""
```

```bash
export DB_HOST=""
export DB_USER=""
export DB_PASS=""
export DB_NAME=""
```

`--insert` requires `--run-number` and a matching `Run_info` row. Existing
`EPICS_data` rows are left alone unless `--force`. Columns that are not on
the live table are skipped (`FAIL`); `epics_n_pass_halla` writes
`epics_n_pass` if that is still the live name.

```tcsh
python fetch_epics_snapshot.py --time "Thu Jul 10 12:08:06 PM EDT 2025" --run-number 12345 --insert --dry-run
python insert_epics_snapshot.py --snapshot snapshots/snapshot_run12345_20250710_120806.txt --force
```

Every fetch writes two text files (gitignored `*.txt`):

- `snapshots/snapshot_<time>.txt` — full typed TSV (backup if hamoller is down)
- `snapshots/problems/unavailable_<time>.txt` — ERROR/WARNING rows only

`check_archived_pvs.py` writes the problems file and prints those lines
to the terminal. Unavailable PVs print as `FAIL` and do not exit the
process. `query_error` means the name is not in MYA; `disconnect` means
the IOC was down at that time.

Output TSV columns: `column`, `pv`, `sql_type`, `status`, `coerced_value`,
`raw_value`, `archive_time`, `mya_datatype`, `description`, `note`.

Statuses to scan after a test run: `ok`, `missing`, `disconnect`,
`type_mismatch`, `overflow`, `query_error`.

## Goal

For each `Run_info.run_number` that has a start time and no (or stale)
`EPICS_data` row:

1. Look up the run window (`run_start_unix` / `run_end_unix`, or the
   datetime stamps).
2. Query MYA for the mapped PVs at a chosen time in that window
   (default: value **at or before run start**).
3. `INSERT` (or guarded `UPDATE`) one `EPICS_data` row keyed by `run_number`.

`EPICS_data.run_number` FKs to `Run_info`. A run row must exist first.
`last_updated` is a table timestamp — do not treat it as a PV.

## Why a Python client, not the CLI

Don’s PV list is the labels from the old ADC `.set` print. Historically
people pulled those with `myget` / `mysampler` / similar command-line
tools. At the end of Spring 2026 Adam Carpenter released
[`jlab-archiver-client`](https://pypi.org/project/jlab-archiver-client/)
(`jlab_archiver_client` on PyPI, Python ≥ 3.11): a library over the
**myquery** web service. Use that instead of shelling out.

- Docs: https://jeffersonlab.github.io/jlab_archiver_client/
- Source: https://github.com/JeffersonLab/jlab_archiver_client
- Install: `pip install jlab_archiver_client`
- Defaults to the CEBAF **read-only history** myquery
  (`epicsweb.jlab.org`, https). Offsite auth is **not** supported in the
  package — run this onsite (or on a host that can reach myquery without
  extra auth).
- Not for mission-critical ops; fine for a run-log snapshot.

The fetch script uses **`Point` / `PointQuery`** (one event at or before a
timestamp). **`Channel`** can still be used later to check which unmatched
PVs are actually archived.

```python
from jlab_archiver_client import Point, PointQuery
from datetime import datetime

query = PointQuery(channel="HALLA:p", time=run_start)
point = Point(query)
point.run()
# point.event['data']['v']  — value
# point.event['data']['d']  — archive timestamp
```

## File inventory

See **How the scripts fit together** for how these call each other.

| File | Role |
|------|------|
| `epics_pv_list.txt` | Don’s original PV list (name + `.set` print label). Reference only. |
| `schema/don_set_up_mariadb.original.sh` | Don’s `set_up_mariadb.sh` as downloaded from hamoller_analysis_tools. Reference only. |
| `schema/don_set_up_mariadb.proposed.sh` | Same script with EPICS_data updates to send Don (`[PV: …]` comments kept). |
| `epics_column_pv_map.txt` | **Base file** for fetch/insert. Space-aligned `column`, `pv`, `sql_type`, `description`. Matches the proposed schema (live hamoller still has `epics_n_pass` until Don applies it). |
| `epics_schema.py` | Map parser and light coerce (empty → `NULL`; no invented values). |
| `fetch_epics_snapshot.py` | MYA point query → snapshot TSV + problems file. `--insert` writes `EPICS_data`. |
| `insert_epics_snapshot.py` | Insert a saved `snapshots/snapshot_*.txt` into `EPICS_data`. |
| `epics_db.py` | MariaDB connect/insert. Reads `DB_HOST` / `DB_USER` / `DB_PASS` / `DB_NAME`. |
| `check_archived_pvs.py` | Prints `FAIL` for mapped PVs MYA cannot serve; writes `snapshots/problems/unavailable_*.txt`. |
| `snapshots/` | Typed snapshot TSVs (gitignored `*.txt`). |
| `snapshots/problems/` | Unavailable / error reports (gitignored `*.txt`). |
| `requirements.txt` | `jlab-archiver-client`, `PyMySQL`. |

Mapping was matched against `EPICS_data` `COLUMN_COMMENT` `[PV: …]` values
in the dashboard’s Docker schema copy (`docker/init/01_schema.sql` in
`MolPol-FADC-Web`). Live schema is Don’s; if a column name or type drifts,
trust `INFORMATION_SCHEMA` on hamoller.

### Types the insert script must respect

From old `.set` prints and the schema:

- **Text:** `HELPATTERNd` → `epics_hel_pattern` (`VARCHAR`; e.g. `Quartet`).
  The PV-list label “Helicity Mode ON/OFF Random/Toggle” is the print
  header, not the value.
- **Text:** `HELDELAYd` → `epics_hel_delay` (`VARCHAR`; e.g. `8 windows`).
- **Text:** laser modes, `epics_n_pass_halla` (and hall b/c/d), `epics_ihwp`.
- **Flags:** target limit / home switches are `TINYINT(1)`.
- **Numeric:** everything else in the confirmed map (FLOAT / DECIMAL).

Store what MYA returns after a light coerce (empty / disconnect → `NULL`).
Do not invent values.

## Intended pipeline

The stack above is the first insert version. Per run: map → MYA Point at
run start → snapshot TSV + problems file → one `EPICS_data` row. Use
`--dry-run` before a write; `--force` only to replace an existing row.

## Open questions (do not guess)

**Proposed `EPICS_data` columns** (in `schema/don_set_up_mariadb.proposed.sh`;
do not ALTER live hamoller until Don applies them):

- Rename `epics_n_pass` → `epics_n_pass_halla`; add `epics_n_pass_hallb/c/d`
- Accelerator: `epics_ha_rf_freq`, `epics_gun_kV`, `epics_inj_spot_x/y`
- After BPMs: `-- Beamline Locks` / `epics_mol_lock`
- After vertical corrector: `epics_mcz1h0h_cur`

**Table columns whose PVs are not on this list:**

- `epics_tgt_foil` — no `[PV:]` in the schema (“Target selection ID / state”)
- `epics_tgt_ladder_temp1/2/3` — schema PVs `hamolpol_tgt_ladder_temp1/2/3`
- `epics_tgt_motion_temp` — schema PV `hamolpol_tgt_lifter_temp`
- `epics_tgt_flange_temp` — schema PV `hamolpol_tgt_top_flange_temp`

Also decide: snapshot at **run start**, **mid-run**, or a small sample
across the run? Start is the `.set`-file analogue.

## Constraints

- Credentials live in `DB_HOST` / `DB_USER` / `DB_PASS` / `DB_NAME`, not in git.
- Do not ALTER live `EPICS_data`. Propose new columns to Don; experiment
  on a local schema copy.
- Dashboard repo stays SELECT-only. This project is the writer.
- Some PVs may not be in MYA (new hamolpol names, target temps). A miss
  is `NULL` + a log line, not a failed run insert.

Related read-only UI: `MolPol-FADC-Web` (`detail_epics.php`). Live site
is a PHP 5.4 tree; this insert tool is Python 3.12 and does not deploy
there.
