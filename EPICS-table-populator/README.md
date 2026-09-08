# Hall A Møller EPICS → hamoller insert

Fill `hamoller_db.EPICS_data` with a **per-run snapshot** of EPICS PVs from
the JLab MYA archiver. This is a **writer**. The FADC web dashboard is
read-only and must not grow insert logic, credentials with write access, or
archiver clients.

## Current status

Step 1 is in place: fetch a snapshot from MYA into a typed text file. There
is no MariaDB insert yet. A sample hamoller database can wait until the
snapshot looks right on the server — the TSV already checks Don's column
types.

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
# Inspect the 100 confirmed pairs without querying MYA
python fetch_epics_snapshot.py --list-map

# Value at or before a run start (JLab local time)
python fetch_epics_snapshot.py --time "2026-03-15 14:32:00" -o snapshot.txt

# Same, from Run_info.run_start_unix
python fetch_epics_snapshot.py --unix 1742058720 --run-number 12345 -o snapshot.txt

# Smoke test a handful of PVs
python fetch_epics_snapshot.py --time "2026-03-15 14:32:00" --limit 5 -o smoke.txt
```

`--time` without a timezone is `America/New_York`. The MYA **point** query
returns the event **at or before** that timestamp (same idea as the old ADC
`.set` print). Empty, disconnect, and type-mismatch values are written as
`NULL` plus a status/note — nothing is invented.

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

## What is already here

| File | Role |
|------|------|
| `epics_pv_list.txt` | Don’s PV list (name + `.set` print label). |
| `epics_column_pv_map.txt` | Tab-separated `EPICS_data` column → PV. Skip `#` and blank lines. **100 confirmed pairs.** Unmatched items are commented at the bottom — do not insert those until resolved. |
| `epics_column_types.txt` | Tab-separated column → Don’s SQL type (from the dashboard schema copy). |
| `epics_schema.py` | Map/type parser and light coerce (empty → `NULL`; no invented values). |
| `fetch_epics_snapshot.py` | MYA point query → typed TSV. No database writes. |
| `requirements.txt` | `jlab-archiver-client`. |

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
- **Text:** laser modes, `epics_n_pass`, `epics_ihwp`.
- **Flags:** target limit / home switches are `TINYINT(1)`.
- **Numeric:** everything else in the confirmed map (FLOAT / DECIMAL).

Store what MYA returns after a light coerce (empty / disconnect → `NULL`).
Do not invent values.

## Intended pipeline (first insert version)

Keep it boring. After the snapshot TSV looks right:

1. Read `epics_column_pv_map.txt` → `{column: pv}`.
2. Connect to MariaDB with a **dedicated writer** account (not the
   dashboard SELECT-only user). Database name on the live host is
   `hamoller_db` (Docker test DB is `app_db`).
3. Select candidate runs from `Run_info` (has start time; optionally
   skip rows that already have `EPICS_data`).
4. For each run, query MYA at `run_start` (unix → datetime). Log PVs
   that are missing, disconnected, or type-mismatch; leave those columns
   `NULL`.
5. Insert one row. Default: **do not overwrite** an existing
   `EPICS_data` row unless `--force` (or similar) is passed.
6. Dry-run mode that prints the row and never writes.

Develop and test inserts against a copy of the schema first, never against
live hamoller until the mapping and types are trusted.

## Open questions (do not guess)

**PVs on Don’s list with no `EPICS_data` column** — skip until Don adds
columns (schema is his):

- `MMSHLBPASS` / `MMSHLCPASS` / `MMSHLDPASS` (Hall B/C/D passes; table
  only has Hall A `epics_n_pass`)
- `MBD1H04HM` (MCZ1H04 **horizontal** corrector; table only has vertical
  `epics_mcz1h0v_cur` → `MBD1H04VM`)
- `pgunFreqDiv:A:frequencyVal` (HA RF frequency)
- `IGL0I00HVPSkVolts` (injector gun voltage)
- `HallAMolLock:Onoff` (beam-position lock)
- `psub_cx_pos` / `psub_cy_pos` (injector spot x/y)

**Table columns whose PVs are not on this list:**

- `epics_tgt_foil` — no `[PV:]` in the schema (“Target selection ID / state”)
- `epics_tgt_ladder_temp1/2/3` — schema PVs `hamolpol_tgt_ladder_temp1/2/3`
- `epics_tgt_motion_temp` — schema PV `hamolpol_tgt_lifter_temp`
- `epics_tgt_flange_temp` — schema PV `hamolpol_tgt_top_flange_temp`

Also decide: snapshot at **run start**, **mid-run**, or a small sample
across the run? Start is the `.set`-file analogue.

## Constraints

- Do not put hamoller passwords, hosts, or production account names in
  git. Env vars or a gitignored local config.
- Do not ALTER live `EPICS_data`. Propose new columns to Don; experiment
  on a local schema copy.
- Dashboard repo stays SELECT-only. This project is the writer.
- Some PVs may not be in MYA (new hamolpol names, target temps). A miss
  is `NULL` + a log line, not a failed run insert.

Related read-only UI: `MolPol-FADC-Web` (`detail_epics.php`). Live site
is a PHP 5.4 tree; this insert tool is Python 3.12 and does not deploy
there.
