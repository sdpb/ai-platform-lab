"""Apply the supplied SQL migrations under one PostgreSQL advisory lock."""
import argparse
import os
from pathlib import Path

import psycopg

parser = argparse.ArgumentParser()
parser.add_argument("--through", choices=["001", "002", "003"], default="001")
args = parser.parse_args()
with psycopg.connect(os.environ["DATABASE_URL"]) as conn:
    conn.execute("SELECT pg_advisory_xact_lock(724019)")
    for path in sorted(Path("db/migrations").glob("*.sql")):
        if path.name[:3] <= args.through:
            conn.execute(path.read_text())
            print(f"Applied {path.name}")
