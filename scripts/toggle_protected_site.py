#!/usr/bin/env python
"""Toggle the protected-site fixture's mode at runtime. No redeploy.

Usage:
    python scripts/toggle_protected_site.py healthy
    python scripts/toggle_protected_site.py slow
    python scripts/toggle_protected_site.py error

Takes effect within about 5 seconds - the fixture's SSM read cache
window (app.py's MODE_CACHE_SECONDS).
"""

import argparse
import json
import subprocess
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

    param_name = outputs["protected_site_mode_parameter"]
    region = outputs["region"]

    subprocess.run(
        [
            "aws", "ssm", "put-parameter",
            "--region", region,
            "--name", param_name,
            "--value", args.mode,
            "--overwrite",
        ],
        check=True,
    )
    print(f"Set {param_name} = {args.mode}")
    print("Takes effect within ~5 seconds - no redeploy, no restart.")


if __name__ == "__main__":
    main()
