#!/usr/bin/env python
"""Toggle the protected-site fixture's mode at runtime. No redeploy.

Usage:
    python scripts/toggle_protected_site.py healthy
    python scripts/toggle_protected_site.py slow
    python scripts/toggle_protected_site.py error

Calls the Room Admin API's POST /demo/mode route - the same one
apps/demo-control/index.html uses - rather than writing DynamoDB
directly. One code path for "how the mode changes", not two.

Takes effect within a few seconds - the fixture's background poll
interval (app.py's MODE_POLL_SECONDS, default 5s).
"""

import argparse
import json
import subprocess
import urllib.error
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
LIVE_DIR = REPO_ROOT / "infra" / "live"

VALID_MODES = ["healthy", "slow", "error"]


def capture(cmd):
    result = subprocess.run(cmd, check=True, capture_output=True, text=True)
    return result.stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("mode", choices=VALID_MODES)
    args = parser.parse_args()

    raw = capture(["terraform", f"-chdir={LIVE_DIR}", "output", "-json"])
    outputs = {k: v["value"] for k, v in json.loads(raw).items()}
    api_base = outputs["room_admin_api"]["api_endpoint"].rstrip("/")

    req = urllib.request.Request(
        f"{api_base}/demo/mode",
        method="POST",
        data=json.dumps({"mode": args.mode}).encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            print(resp.read().decode())
    except urllib.error.HTTPError as exc:
        print(f"Request failed: HTTP {exc.code} {exc.read().decode()}")
        raise SystemExit(1)

    print("Takes effect within a few seconds - no redeploy, no restart.")


if __name__ == "__main__":
    main()
