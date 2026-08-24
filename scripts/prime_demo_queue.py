#!/usr/bin/env python
"""Reset a room and pin its targetRate low, right before a demo.

Two things, back to back, in one command:
  1. Reset nextNumber/admittedCount to 0 (same effect as
     scripts/reset_demo_room.py, folded in here so there's one command).
  2. Pin targetRate to a low value via a direct DynamoDB SET - bypasses
     the Room Admin API's admin-key check entirely, one less thing to
     have ready.

Both writes happen in the same UpdateItem call, so there's no gap
between them for a Queue Controller tick to land in.

This does NOT seed a backlog - an earlier version of this script did,
looping real POST /join calls through Python's urllib. Deleted after
testing showed it was the wrong tool: isolated timing put urllib at
~600-700ms/call with no connection reuse, and under
ThreadPoolExecutor-style concurrency that degraded to an average of
6.8s/call (max 23.5s) - almost certainly per-connection setup overhead
and thread/GIL contention on the client side, not the Admission API or
DynamoDB (k6 sustained 60 req/s against the same endpoint for 45s
straight with 0% failures and a max latency of 6.76s). Use
scripts/k6_seed_backlog.js for seeding instead - see DEMO.md for the
full sequence.

Usage:
    python scripts/prime_demo_queue.py rEcu9I_C
    python scripts/prime_demo_queue.py rEcu9I_C --rate 2
"""

import argparse
import json
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
LIVE_DIR = REPO_ROOT / "infra" / "live"


def capture(cmd):
    return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("room_id")
    parser.add_argument("--rate", type=int, default=2, help="targetRate to pin (default 2)")
    args = parser.parse_args()

    raw = capture(["terraform", f"-chdir={LIVE_DIR}", "output", "-json"])
    outputs = {k: v["value"] for k, v in json.loads(raw).items()}
    table_name = outputs["dynamodb_table_name"]
    region = outputs["region"]

    subprocess.run(
        [
            "aws", "dynamodb", "update-item",
            "--region", region,
            "--table-name", table_name,
            "--key", json.dumps({"PK": {"S": f"ROOM#{args.room_id}"}, "SK": {"S": "META"}}),
            "--update-expression", "SET nextNumber = :z, admittedCount = :z, targetRate = :r",
            "--expression-attribute-values", json.dumps({":z": {"N": "0"}, ":r": {"N": str(args.rate)}}),
        ],
        check=True,
        capture_output=True,
    )
    print(f"Reset ROOM#{args.room_id}: nextNumber=0, admittedCount=0, targetRate={args.rate}")
    print("No backlog seeded - run scripts/k6_seed_backlog.js next. See DEMO.md.")


if __name__ == "__main__":
    main()
