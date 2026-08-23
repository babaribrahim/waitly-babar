#!/usr/bin/env python
"""Continuously send real requests to the protected-site fixture.

Stands in for admitted-visitor traffic until the frontend exists. The
Queue Controller reads CloudWatch ALB metrics (TargetResponseTime,
HTTPCode_Target_5XX_Count) for the fixture's target group, and those
metrics only populate from real requests routed through the ALB's
listener - the ALB's own health checks don't count towards them. So
something has to actually call the fixture for there to be anything for
the Queue Controller to react to. This is that something.

Logs every request's outcome and latency, so the full chain is visible
live: this traffic hitting a struggling fixture -> CloudWatch metrics
degrading -> the Queue Controller cutting the admission rate. Watch this
output side by side with:
    aws logs tail /ecs/waitly-queue-controller --since 1m --follow

Usage:
    python scripts/probe_protected_site.py                    # 2 req/s, forever
    python scripts/probe_protected_site.py --rate 5            # 5 req/s
    python scripts/probe_protected_site.py --rate 1 --duration 120
"""

import argparse
import json
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
LIVE_DIR = REPO_ROOT / "infra" / "live"


def capture(cmd):
    result = subprocess.run(cmd, check=True, capture_output=True, text=True)
    return result.stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--rate", type=float, default=2.0, help="target requests per second (default: 2)")
    parser.add_argument("--duration", type=float, default=None, help="seconds to run for (default: forever, Ctrl+C to stop)")
    args = parser.parse_args()

    raw = capture(["terraform", f"-chdir={LIVE_DIR}", "output", "-json"])
    outputs = {k: v["value"] for k, v in json.loads(raw).items()}
    url = outputs["protected_site_url"]

    interval = 1.0 / args.rate
    start = time.time()
    sent = 0
    ok = 0
    errors = 0

    print(f"Probing {url} at ~{args.rate} req/s (Ctrl+C to stop)")
    print("Actual achieved rate will drop while the fixture is in 'slow' mode - that's expected, it's the point.\n")

    try:
        while args.duration is None or (time.time() - start) < args.duration:
            tick = time.time()
            req_start = time.time()
            try:
                with urllib.request.urlopen(url, timeout=15) as resp:
                    elapsed_ms = (time.time() - req_start) * 1000
                    print(f"{time.strftime('%H:%M:%S')}  GET {url} -> {resp.status}  ({elapsed_ms:.0f}ms)")
                    ok += 1
            except urllib.error.HTTPError as exc:
                elapsed_ms = (time.time() - req_start) * 1000
                print(f"{time.strftime('%H:%M:%S')}  GET {url} -> {exc.code}  ({elapsed_ms:.0f}ms)")
                errors += 1
            except Exception as exc:  # noqa: BLE001
                elapsed_ms = (time.time() - req_start) * 1000
                print(f"{time.strftime('%H:%M:%S')}  GET {url} -> ERROR {exc}  ({elapsed_ms:.0f}ms)")
                errors += 1

            sent += 1
            sleep_for = interval - (time.time() - tick)
            if sleep_for > 0:
                time.sleep(sleep_for)
    except KeyboardInterrupt:
        pass

    elapsed = time.time() - start
    print(f"\nSent {sent} requests over {elapsed:.0f}s ({ok} ok, {errors} errors, {sent / elapsed:.2f} req/s achieved)")


if __name__ == "__main__":
    main()
