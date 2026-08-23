#!/usr/bin/env python
"""Poll a room's targetRate/admittedCount at a fixed interval, timestamped.

A time series, not a before/after snapshot - meant to run alongside
scripts/demo_sequence.py and scripts/probe_protected_site.py so the full
mode-flip -> CloudWatch-metrics -> Queue-Controller-reaction chain is
visible with real timestamps to correlate against.

Usage:
    python scripts/watch_room_rate.py demo --interval 3 --duration 300
"""

import argparse
import json
import subprocess
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
LIVE_DIR = REPO_ROOT / "infra" / "live"


def capture(cmd):
    result = subprocess.run(cmd, check=True, capture_output=True, text=True)
    return result.stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("room_id")
    parser.add_argument("--interval", type=float, default=3.0, help="seconds between samples (default 3)")
    parser.add_argument("--duration", type=float, default=None, help="seconds to run for (default: forever, Ctrl+C to stop)")
    args = parser.parse_args()

    raw = capture(["terraform", f"-chdir={LIVE_DIR}", "output", "-json"])
    outputs = {k: v["value"] for k, v in json.loads(raw).items()}
    table_name = outputs["dynamodb_table_name"]
    region = outputs["region"]

    start = time.time()
    print(f"Watching ROOM#{args.room_id} every {args.interval}s")

    try:
        while args.duration is None or (time.time() - start) < args.duration:
            key = json.dumps({"PK": {"S": f"ROOM#{args.room_id}"}, "SK": {"S": "META"}})
            raw_item = capture(
                [
                    "aws", "dynamodb", "get-item",
                    "--region", region,
                    "--table-name", table_name,
                    "--key", key,
                    "--output", "json",
                ]
            )
            item = json.loads(raw_item).get("Item", {})
            rate = item.get("targetRate", {}).get("N", "?")
            admitted = item.get("admittedCount", {}).get("N", "?")
            print(f"{time.strftime('%H:%M:%S')}  targetRate={rate}  admittedCount={admitted}")
            time.sleep(args.interval)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
