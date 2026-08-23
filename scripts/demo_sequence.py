#!/usr/bin/env python
"""Run a scripted healthy -> bad -> healthy sequence against the
protected-site fixture, logging exact toggle timestamps.

A repeatable demo script, not just a one-off test: run this alongside
scripts/probe_protected_site.py (generates traffic) and
scripts/watch_room_rate.py (logs the room's targetRate over time) to
show the whole chain live - mode flips -> CloudWatch metrics degrade ->
Queue Controller cuts the rate -> mode recovers -> rate climbs again.

Usage:
    python scripts/demo_sequence.py --baseline 30 --hold 90 --recover 60
    python scripts/demo_sequence.py --bad-mode slow
"""

import argparse
import subprocess
import time
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent


def set_mode(mode):
    ts = time.strftime("%H:%M:%S")
    print(f"{ts}  >>> setting mode = {mode}")
    subprocess.run(["python", str(SCRIPT_DIR / "toggle_protected_site.py"), mode], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--baseline", type=float, default=30, help="seconds to hold healthy before flipping (default 30)")
    parser.add_argument("--hold", type=float, default=90, help="seconds to hold the bad mode (default 90)")
    parser.add_argument("--recover", type=float, default=60, help="seconds to hold healthy after recovering (default 60)")
    parser.add_argument("--bad-mode", default="error", choices=["slow", "error"])
    args = parser.parse_args()

    print(f"{time.strftime('%H:%M:%S')}  Phase: baseline (healthy) for {args.baseline}s")
    set_mode("healthy")
    time.sleep(args.baseline)

    print(f"{time.strftime('%H:%M:%S')}  Phase: {args.bad_mode} for {args.hold}s")
    set_mode(args.bad_mode)
    time.sleep(args.hold)

    print(f"{time.strftime('%H:%M:%S')}  Phase: recovery (healthy) for {args.recover}s")
    set_mode("healthy")
    time.sleep(args.recover)

    print(f"{time.strftime('%H:%M:%S')}  Done.")


if __name__ == "__main__":
    main()
