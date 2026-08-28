"""
load_source.py — COPY one agency's CSV export into the raw schema.

WHAT THIS DOES
    Truncates the raw tables and loads the four CSVs from one agency directory
    into them, in a single transaction, then stamps each row with which file it
    came from and prints the resulting counts.

WHY IT TRUNCATES
    Only one agency's data is resident in raw at a time, by design. Raw is a
    landing zone for the export currently under examination, not an archive. If
    two agencies' rows were both sitting in raw.landlords, every model
    downstream would silently be doing cross-agency work before the layer that
    is supposed to do cross-agency work. Phase 2 changes what you load, not how
    much is loaded at once.
    ALTERNATIVE CONSIDERED: append, and discriminate on _source_file. Rejected
    for now — it makes every staging model carry a filter that is easy to
    forget in exactly one place, and the failure is silent double-counting.

WHY COPY AND NOT INSERT
    COPY is Postgres's bulk path: one statement, one parse, minimal round
    trips. It is also the thing a real load actually uses, so its failure modes
    — encoding, quoting, embedded newlines, header handling — are the failure
    modes worth meeting now rather than in production.

WHY THE COLUMN LIST IS DERIVED FROM THE CSV HEADER
    The header is read, lowercased, and checked against the columns Postgres
    reports for the table. If the generator adds a column and the DDL does not,
    the load fails loudly here with the offending name, rather than COPY
    matching columns by position and putting postcodes in the phone column.
    Positional matching is the classic silent loader bug.
"""

from __future__ import annotations

import argparse
import csv
import os
import sys
from pathlib import Path

import psycopg2

REPO_ROOT = Path(__file__).resolve().parents[1]

# Load order does not matter — raw has no foreign keys — but a fixed order
# keeps the printed output stable and diffable between runs.
TABLES = ["landlords", "properties", "tenancies", "payments"]

DSN = os.environ.get(
    "MERIDIAN_DSN",
    "postgresql://meridian:meridian@localhost:5434/meridian_crm",
)


def csv_columns(path: Path) -> list[str]:
    with path.open("r", encoding="utf-8", newline="") as f:
        header = next(csv.reader(f))
    return [c.strip().lower() for c in header]


def table_columns(cur, table: str) -> set[str]:
    cur.execute(
        "SELECT column_name FROM information_schema.columns "
        "WHERE table_schema = 'raw' AND table_name = %s",
        (table,),
    )
    return {r[0] for r in cur.fetchall()}


def load(conn, agency_dir: Path) -> dict[str, int]:
    counts: dict[str, int] = {}
    with conn.cursor() as cur:
        # One transaction for all four tables. A half-loaded raw schema is
        # worse than an empty one: dbt would run happily against it and every
        # number would be wrong in a way nothing flags.
        cur.execute("TRUNCATE {}".format(
            ", ".join(f"raw.{t}" for t in TABLES)))

        for table in TABLES:
            path = agency_dir / f"{table}.csv"
            if not path.exists():
                raise SystemExit(f"missing export file: {path}")

            cols = csv_columns(path)
            known = table_columns(cur, table)
            if not known:
                raise SystemExit(
                    f"raw.{table} does not exist — run the DDL first")
            unknown = [c for c in cols if c not in known]
            if unknown:
                raise SystemExit(
                    f"{path.name} has columns not present in raw.{table}: "
                    f"{unknown}. Update db/ddl/01_raw_schema.sql.")

            collist = ", ".join(cols)
            with path.open("r", encoding="utf-8", newline="") as f:
                cur.copy_expert(
                    f"COPY raw.{table} ({collist}) "
                    f"FROM STDIN WITH (FORMAT csv, HEADER true)",
                    f,
                )

            # _source_file is stamped after the fact rather than defaulted,
            # because the value depends on which export is being loaded and a
            # column default cannot know that.
            cur.execute(
                f"UPDATE raw.{table} SET _source_file = %s WHERE _source_file IS NULL",
                (f"{agency_dir.name}/{path.name}",),
            )
            cur.execute(f"SELECT count(*) FROM raw.{table}")
            counts[table] = cur.fetchone()[0]
    conn.commit()
    return counts


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--agency", default="harcourt_vine",
        help="directory name under data/source/ to load (one at a time)")
    parser.add_argument("--dsn", default=DSN)
    args = parser.parse_args()

    agency_dir = REPO_ROOT / "data" / "source" / args.agency
    if not agency_dir.is_dir():
        raise SystemExit(
            f"no export at {agency_dir} — run: python db/generate_source.py")

    try:
        conn = psycopg2.connect(args.dsn)
    except psycopg2.OperationalError as exc:
        print(f"could not connect: {exc}", file=sys.stderr)
        raise SystemExit(
            "is the database up? try: docker compose up -d")

    try:
        counts = load(conn, agency_dir)
    finally:
        conn.close()

    print(f"loaded : {agency_dir}")
    for table, n in counts.items():
        print(f"  raw.{table:<12} {n:>6,} rows")
    print(f"  {'TOTAL':<17} {sum(counts.values()):>6,} rows")


if __name__ == "__main__":
    main()
