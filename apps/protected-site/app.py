"""Protected-site fixture - deliberately fragile demo prop.

NOT one of the three real microservices (see CLAUDE.md's demo/testing
section) - exists purely so the Queue Controller has something real to
react to. Reads its mode from a small DynamoDB config item
(PK=CONFIG#protected-site, SK=MODE) via a background thread that polls
every MODE_POLL_SECONDS. The request handler itself never touches
DynamoDB - it only reads an in-memory variable the thread updates. That
matters here specifically: this fixture's own response latency feeds
directly into the CloudWatch metrics the Queue Controller reads, so a
synchronous DB call on every request would pollute exactly the signal
this whole demo depends on. Same pattern as the Queue Controller's own
background AIMD loop.

  healthy - instant 200
  slow    - sleeps SLOW_DELAY_SECONDS, then 200
  error   - immediate 500

Runtime-togglable: mode changes take effect within about MODE_POLL_SECONDS,
no redeploy, no restart. Flip it with scripts/toggle_protected_site.py or
apps/demo-control/index.html - both go through the Room Admin API's
POST /demo/mode route, not this fixture directly (it has no admin route
of its own by design).

/health always responds instantly with 200 regardless of mode and never
touches DynamoDB either - that's the ALB target group's health check
path, kept immune on purpose: toggling to "slow"/"error" should simulate
a struggling app on its real traffic path, not get the task itself
killed and replaced by ECS.
"""

import os
import threading
import time

import boto3
from botocore.config import Config
from fastapi import FastAPI
from fastapi.responses import JSONResponse

TABLE_NAME = os.environ["TABLE_NAME"]
AWS_REGION = os.environ.get("AWS_REGION", "us-west-2")
SLOW_DELAY_SECONDS = float(os.environ.get("SLOW_DELAY_SECONDS", "3"))
MODE_POLL_SECONDS = float(os.environ.get("MODE_POLL_SECONDS", "5"))

MODE_KEY = {"PK": "CONFIG#protected-site", "SK": "MODE"}

# Explicit, short timeout so a network gap (e.g. a missing VPC endpoint)
# fails fast and loud instead of hanging the poll thread indefinitely -
# see apps/queue-controller/app.py's docstring for why this was added.
BOTO_CONFIG = Config(connect_timeout=5, read_timeout=10, retries={"max_attempts": 2})

dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION, config=BOTO_CONFIG)
table = dynamodb.Table(TABLE_NAME)

app = FastAPI(title="Waitly Protected Site Fixture")

_mode = "healthy"  # updated only by the background poll thread below


def poll_mode_forever():
    global _mode
    while True:
        try:
            resp = table.get_item(Key=MODE_KEY)
            item = resp.get("Item")
            if item and "mode" in item:
                _mode = item["mode"]
        except Exception as exc:  # noqa: BLE001 - keep serving the last-known mode
            print(f"failed to poll mode, keeping cached value '{_mode}': {exc}")
        time.sleep(MODE_POLL_SECONDS)


@app.on_event("startup")
def start_poll():
    threading.Thread(target=poll_mode_forever, daemon=True).start()


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/")
def index():
    mode = _mode  # no I/O on the request path - see module docstring

    if mode == "error":
        return JSONResponse(status_code=500, content={"mode": mode, "error": "simulated failure"})

    if mode == "slow":
        time.sleep(SLOW_DELAY_SECONDS)

    return {"mode": mode}
