#!/usr/bin/env python
"""Reset a room's counters to a clean starting state, right before a demo.

Only nextNumber and admittedCount are reset to 0 - targetRate is left
alone deliberately, since the Queue Controller is always running and
will just readjust it on its next tick regardless (that's it working as
designed, not something to fight).

Run this as close as practical to the actual "visitor joins" demo beat,
not minutes/hours ahead: admittedCount keeps climbing the whole time the
room sits idle-but-healthy (unbounded AIMD growth, no ceiling), so a
visitor joining too long after a reset can land past the current
admittedCount and get admitted instantly - no visible "waiting" moment
for the audience to see.

Usage:
    python scripts/reset_demo_room.py <roomId>
"""

import argparse
import json
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
LIVE_DIR = REPO_ROOT / "infra" / "live"


def capture(cmd):
    result = subprocess.run(cmd, check=True, capture_output=True, text=True)
    return result.stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("room_id")
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
            "--update-expression", "SET nextNumber = :z, admittedCount = :z",
            "--expression-attribute-values", json.dumps({":z": {"N": "0"}}),
        ],
        check=True,
    )
    print(f"Reset ROOM#{args.room_id}: nextNumber=0, admittedCount=0")
    print("targetRate left as-is - the Queue Controller owns that value.")


if __name__ == "__main__":
    main()
