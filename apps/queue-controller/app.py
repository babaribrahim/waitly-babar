"""Queue Controller - background AIMD loop, no public API surface.

Runs continuously on ECS Fargate. Every POLL_INTERVAL_SECONDS:
  1. Checks the protected site's health via CloudWatch (ALB target group
     latency + error rate).
  2. Decides the next admission rate with AIMD: healthy -> increase by a
     small fixed step, unhealthy -> cut the rate in half.
  3. Advances every room's admittedCount by that rate with a single
     atomic DynamoDB UpdateItem per room (not a per-visitor write).

/health exists only so the ALB target group (required by CodeDeploy's ECS
blue/green mechanism, even though nothing calls this service) and the
CodeDeploy validation hook have something to check. Nobody else calls
this service.

PROTECTED_SITE_LB_ARN_SUFFIX / PROTECTED_SITE_TARGET_GROUP_ARN_SUFFIX are
optional and unset until the protected-site fixture exists (a later
phase - see CLAUDE.md's build order). Until then the loop assumes healthy
and logs that it has no real target configured.

Every boto3 client/resource below gets an explicit, short timeout
(BOTO_CONFIG). Found the hard way: without one, a network call with no
route out (e.g. a missing VPC endpoint) can hang the whole loop
indefinitely with nothing logged at all - not even an exception - which
is a worse failure mode than an explicit, visible error. A short timeout
turns "silently stuck forever" into "logs a clear failure every
POLL_INTERVAL_SECONDS".
"""

import logging
import os
import threading
import time

import boto3
from botocore.config import Config
from fastapi import FastAPI

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("queue-controller")

TABLE_NAME = os.environ["TABLE_NAME"]
AWS_REGION = os.environ.get("AWS_REGION", "us-west-2")

POLL_INTERVAL_SECONDS = int(os.environ.get("POLL_INTERVAL_SECONDS", "5"))
INCREASE_STEP = int(os.environ.get("INCREASE_STEP", "5"))
MIN_RATE = int(os.environ.get("MIN_RATE", "1"))
LATENCY_THRESHOLD_MS = float(os.environ.get("LATENCY_THRESHOLD_MS", "1000"))
ERROR_COUNT_THRESHOLD = int(os.environ.get("ERROR_COUNT_THRESHOLD", "5"))

PROTECTED_SITE_LB_ARN_SUFFIX = os.environ.get("PROTECTED_SITE_LB_ARN_SUFFIX", "")
PROTECTED_SITE_TARGET_GROUP_ARN_SUFFIX = os.environ.get("PROTECTED_SITE_TARGET_GROUP_ARN_SUFFIX", "")

BOTO_CONFIG = Config(connect_timeout=5, read_timeout=10, retries={"max_attempts": 2})

dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION, config=BOTO_CONFIG)
table = dynamodb.Table(TABLE_NAME)
cloudwatch = boto3.client("cloudwatch", region_name=AWS_REGION, config=BOTO_CONFIG)

app = FastAPI(title="Waitly Queue Controller")

_state = {"lastRunAt": None, "healthy": None, "roomsUpdated": 0, "loopCount": 0}


def check_protected_site_health() -> bool:
    """True = healthy (or no fixture configured yet). False = unhealthy."""
    if not PROTECTED_SITE_LB_ARN_SUFFIX or not PROTECTED_SITE_TARGET_GROUP_ARN_SUFFIX:
        log.info("no protected-site target configured yet, assuming healthy")
        return True

    dimensions = [
        {"Name": "LoadBalancer", "Value": PROTECTED_SITE_LB_ARN_SUFFIX},
        {"Name": "TargetGroup", "Value": PROTECTED_SITE_TARGET_GROUP_ARN_SUFFIX},
    ]

    resp = cloudwatch.get_metric_data(
        StartTime=time.time() - 60,
        EndTime=time.time(),
        MetricDataQueries=[
            {
                "Id": "latency",
                "MetricStat": {
                    "Metric": {
                        "Namespace": "AWS/ApplicationELB",
                        "MetricName": "TargetResponseTime",
                        "Dimensions": dimensions,
                    },
                    "Period": 60,
                    "Stat": "Average",
                },
                "ReturnData": True,
            },
            {
                "Id": "errors",
                "MetricStat": {
                    "Metric": {
                        "Namespace": "AWS/ApplicationELB",
                        "MetricName": "HTTPCode_Target_5XX_Count",
                        "Dimensions": dimensions,
                    },
                    "Period": 60,
                    "Stat": "Sum",
                },
                "ReturnData": True,
            },
        ],
    )

    values_by_id = {r["Id"]: r["Values"] for r in resp["MetricDataResults"]}
    latency_ms = (values_by_id.get("latency") or [0.0])[0] * 1000
    error_count = (values_by_id.get("errors") or [0.0])[0]

    healthy = latency_ms <= LATENCY_THRESHOLD_MS and error_count <= ERROR_COUNT_THRESHOLD
    log.info(f"protected site: latency={latency_ms:.0f}ms errors={error_count:.0f} healthy={healthy}")
    return healthy


def scan_rooms():
    """Small-scale Scan, not a GSI query - fine at this project's scale.
    See CLAUDE.md's DynamoDB section on why no GSIs are used here."""
    resp = table.scan(FilterExpression="SK = :meta", ExpressionAttributeValues={":meta": "META"})
    return resp.get("Items", [])


def advance_room(room, healthy: bool) -> int:
    current_rate = int(room.get("targetRate") or MIN_RATE)
    if healthy:
        new_rate = current_rate + INCREASE_STEP
    else:
        new_rate = max(current_rate // 2, MIN_RATE)

    # One atomic UpdateItem: sets the new rate and advances admittedCount
    # by that same amount in a single call, not a per-visitor write.
    table.update_item(
        Key={"PK": room["PK"], "SK": "META"},
        UpdateExpression="SET targetRate = :rate ADD admittedCount :rate",
        ExpressionAttributeValues={":rate": new_rate},
    )
    return new_rate


def run_once():
    healthy = check_protected_site_health()
    rooms = scan_rooms()

    for room in rooms:
        new_rate = advance_room(room, healthy)
        log.info(f"{room['PK']}: rate -> {new_rate}")

    _state.update(lastRunAt=time.time(), healthy=healthy, roomsUpdated=len(rooms), loopCount=_state["loopCount"] + 1)


def loop_forever():
    while True:
        try:
            run_once()
        except Exception:
            log.exception("loop iteration failed")
        time.sleep(POLL_INTERVAL_SECONDS)


@app.on_event("startup")
def start_loop():
    threading.Thread(target=loop_forever, daemon=True).start()


@app.get("/health")
def health():
    return {"status": "ok", **_state}
