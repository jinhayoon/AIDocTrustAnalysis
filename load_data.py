"""
load_qp.py  —  Load the raw QuestionPro export (QP.csv) into Postgres.

This loads ONE file into ONE staging table (qp_raw) using Postgres COPY,
the fast, idiomatic bulk-load path. Computing scale scores and splitting
into the clean normalized tables happens afterwards, in SQL.

Workflow (matches your SQLTools setup):
    1. Run schema_raw.sql in SQLTools (or pass --run-schema here).
    2. Set the PG* environment variables to match your SQLTools connection.
    3. python load_qp.py            # loads QP.csv from the current folder
       python load_qp.py --csv path/to/QP.csv --run-schema

Env vars (with defaults):
    PGHOST=localhost  PGPORT=5432  PGDATABASE=trust  PGUSER=postgres  PGPASSWORD=

Requires:  pip install psycopg2-binary
"""

import argparse
import csv
import os
from pathlib import Path

import psycopg2

DEFAULT_CSV = "/Users/jinhayoon/Desktop/AIDocTrustAnalysis/QP.csv"
DEFAULT_SCHEMA = '/Users/jinhayoon/Library/Application Support/vscode-sqltools/session/conn.session.sql'
TABLE = "qp_raw"


def connect():
    return psycopg2.connect(
        host=os.getenv("PGHOST", "localhost"),
        port=os.getenv("PGPORT", "5432"),
        dbname=os.getenv("PGDATABASE", "trust"),
        user=os.getenv("PGUSER", "postgres"),
        password=os.getenv("PGPASSWORD", ""),
    )


def read_header(csv_path):
    # utf-8-sig strips the BOM QuestionPro writes at the very start of the file.
    with open(csv_path, encoding="utf-8-sig", newline="") as f:
        return next(csv.reader(f))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", default=DEFAULT_CSV)
    ap.add_argument("--schema", default=DEFAULT_SCHEMA)
    ap.add_argument("--run-schema", action="store_true",
                    help="execute schema_raw.sql first (drops & recreates qp_raw)")
    args = ap.parse_args()

    header = read_header(args.csv)
    # Column names are unquoted, so Postgres folds them to lower case to match
    # the (also unquoted) columns created by schema_raw.sql. Listing them
    # explicitly makes the load robust to any future column reordering.
    col_list = ", ".join(header)

    conn = connect()
    conn.autocommit = False
    try:
        with conn.cursor() as cur:
            if args.run_schema:
                print(f"Running {args.schema} ...")
                cur.execute(Path(args.schema).read_text(encoding="utf-8"))

            # TRUNCATE first so re-running the loader is idempotent (no dup PIDs).
            cur.execute(f"TRUNCATE {TABLE}")

            copy_sql = (
                f"COPY {TABLE} ({col_list}) "
                "FROM STDIN WITH (FORMAT csv, HEADER true, NULL '')"
            )
            # utf-8-sig again so the streamed header line carries no BOM.
            # COPY ... HEADER true skips that first line; NULL '' turns empty
            # cells (dropouts, the conditional ECZEMA_SEV question) into SQL NULL.
            with open(args.csv, encoding="utf-8-sig") as f:
                cur.copy_expert(copy_sql, f)

            cur.execute(f"SELECT COUNT(*) FROM {TABLE}")
            n = cur.fetchone()[0]

        conn.commit()
        print(f"Loaded {n} rows into {TABLE}. Committed.")
    except Exception:
        conn.rollback()
        print("Rolled back due to error.")
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    main()