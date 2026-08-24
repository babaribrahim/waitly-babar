"""Room Admin API - AWS Lambda behind API Gateway (HTTP API).

For event organizers, not visitors. Low traffic, no VPC (reaches DynamoDB
directly). Plain stdlib handler, no framework - a Lambda this small and
infrequently invoked doesn't need one, and it keeps cold starts minimal.

Routes (dispatched on API Gateway's routeKey, payload format 2.0):
  POST  /rooms            create a room, returns the admin key ONCE
  GET   /rooms            list all rooms (name/id only, no auth)
  GET   /rooms/{roomId}   live stats, requires X-Admin-Key
  PATCH /rooms/{roomId}   update targetRate, requires X-Admin-Key
  GET   /demo/status      demo-control page only, see below
  POST  /demo/mode        demo-control page only, see below
  POST  /demo/reset       demo-control page only, see below

Auth is a simple admin-key-hash check per room (CLAUDE.md is explicit this
is proportionate to project scope, not a full auth system) - only the
SHA-256 hash is ever stored; the raw key is returned exactly once, at
creation time, and never persisted.

The /demo/* routes exist only for apps/demo-control/index.html, a
standalone page (not part of the real product UI) that lets a demo
operator toggle the protected-site fixture's mode and watch the
most-recently-created room's targetRate react, without typing AWS CLI
commands live. The mode itself lives as one item in this same DynamoDB table
(PK=CONFIG#protected-site, SK=MODE) - this Lambda already has table-wide
read/write permission, so no separate permission was needed for it.
Deliberately unauthenticated, same "proportionate to scope" reasoning as
GET /rooms.
"""

import hashlib
import hmac
import json
import os
import secrets
import time
from datetime import datetime, timezone

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

TABLE_NAME = os.environ["TABLE_NAME"]
AWS_REGION = os.environ.get("AWS_REGION", "us-west-2")

# Same ALB/target-group the Queue Controller polls (queue_controller.tf
# passes it the identical two values) - unset until the protected-site
# fixture exists, same pattern as that service's own env vars.
PROTECTED_SITE_LB_ARN_SUFFIX = os.environ.get("PROTECTED_SITE_LB_ARN_SUFFIX", "")
PROTECTED_SITE_TARGET_GROUP_ARN_SUFFIX = os.environ.get("PROTECTED_SITE_TARGET_GROUP_ARN_SUFFIX", "")

# Unset until the frontend phase exists - publicLink is null until then,
# no code change needed later, just set this env var on the function.
FRONTEND_BASE_URL = os.environ.get("FRONTEND_BASE_URL", "")

# Must match the Queue Controller's POLL_INTERVAL_SECONDS for avgWaitSeconds
# to be a meaningful estimate - both default to 5s.
POLL_INTERVAL_SECONDS = int(os.environ.get("POLL_INTERVAL_SECONDS", "5"))

VALID_MODES = {"healthy", "slow", "error"}
MODE_KEY = {"PK": "CONFIG#protected-site", "SK": "MODE"}

# Explicit, short timeout so a network gap fails fast and loud instead of
# hanging silently - see apps/queue-controller/app.py's docstring for why.
# Lambda's own function timeout (10s) would eventually kill a hung
# invocation anyway, but this makes the failure a clear, logged
# exception rather than an opaque platform-level timeout.
BOTO_CONFIG = Config(connect_timeout=3, read_timeout=5, retries={"max_attempts": 1})

dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION, config=BOTO_CONFIG)
table = dynamodb.Table(TABLE_NAME)
cloudwatch = boto3.client("cloudwatch", region_name=AWS_REGION, config=BOTO_CONFIG)


def _response(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def _hash_key(raw_key: str) -> str:
    return hashlib.sha256(raw_key.encode()).hexdigest()


def _headers_lower(event):
    return {k.lower(): v for k, v in (event.get("headers") or {}).items()}


def _check_admin_key(room, event) -> bool:
    provided = _headers_lower(event).get("x-admin-key", "")
    expected = room.get("adminKeyHash", "")
    if not provided or not expected:
        return False
    return hmac.compare_digest(_hash_key(provided), expected)


def _get_room(room_id):
    resp = table.get_item(Key={"PK": f"ROOM#{room_id}", "SK": "META"})
    return resp.get("Item")


def create_room(event):
    body = json.loads(event.get("body") or "{}")
    name = body.get("name")
    protected_url = body.get("protectedUrl")
    target_rate = int(body.get("targetRate", 1))

    if not name or not protected_url:
        return _response(400, {"error": "name and protectedUrl are required"})
    if target_rate < 1:
        return _response(400, {"error": "targetRate must be at least 1"})

    admin_key = secrets.token_urlsafe(24)
    item_base = {
        "SK": "META",
        "name": name,
        "protectedUrl": protected_url,
        "targetRate": target_rate,
        "nextNumber": 0,
        "admittedCount": 0,
        "adminKeyHash": _hash_key(admin_key),
        "createdAt": datetime.now(timezone.utc).isoformat(),
    }

    # Random id, so a collision is exceedingly unlikely - retry a couple
    # times anyway rather than assume it can never happen.
    for _ in range(3):
        room_id = secrets.token_urlsafe(6)
        try:
            table.put_item(
                Item={"PK": f"ROOM#{room_id}", **item_base},
                ConditionExpression="attribute_not_exists(PK)",
            )
            break
        except ClientError as exc:
            if exc.response["Error"]["Code"] != "ConditionalCheckFailedException":
                raise
    else:
        return _response(500, {"error": "could not allocate a room id, try again"})

    public_link = f"{FRONTEND_BASE_URL}/room/{room_id}" if FRONTEND_BASE_URL else None

    return _response(201, {
        "roomId": room_id,
        "adminKey": admin_key,
        "publicLink": public_link,
    })


def list_rooms(event):
    # Deliberately unauthenticated: no owner/tenant model exists in the
    # schema, so anyone can enumerate all rooms. Known and accepted at
    # this project's scope, see the comment in room_admin_api.tf.
    resp = table.scan(FilterExpression="SK = :meta", ExpressionAttributeValues={":meta": "META"})
    rooms = [
        {
            "roomId": item["PK"].split("#", 1)[1],
            "name": item.get("name"),
            "createdAt": item.get("createdAt"),
        }
        for item in resp.get("Items", [])
    ]
    return _response(200, {"rooms": rooms})


def get_room_stats(event):
    room_id = event["pathParameters"]["roomId"]
    room = _get_room(room_id)
    if not room:
        return _response(404, {"error": "room not found"})
    if not _check_admin_key(room, event):
        return _response(401, {"error": "invalid or missing admin key"})

    next_number = int(room.get("nextNumber", 0))
    admitted_count = int(room.get("admittedCount", 0))
    target_rate = int(room.get("targetRate", 0))
    waiting = max(next_number - admitted_count, 0)

    # Rough estimate, not a measured value: at the current rate, how long
    # would someone at the back of the line wait. Good enough for a demo
    # dashboard stat, not a promise.
    avg_wait_seconds = round((waiting / target_rate) * POLL_INTERVAL_SECONDS) if target_rate > 0 else None

    return _response(200, {
        "roomId": room_id,
        "name": room.get("name"),
        "waiting": waiting,
        "admittedCount": admitted_count,
        "targetRate": target_rate,
        "avgWaitSeconds": avg_wait_seconds,
    })


def update_room(event):
    room_id = event["pathParameters"]["roomId"]
    room = _get_room(room_id)
    if not room:
        return _response(404, {"error": "room not found"})
    if not _check_admin_key(room, event):
        return _response(401, {"error": "invalid or missing admin key"})

    body = json.loads(event.get("body") or "{}")
    if "targetRate" not in body:
        return _response(400, {"error": "targetRate is required"})

    new_rate = int(body["targetRate"])
    if new_rate < 1:
        return _response(400, {"error": "targetRate must be at least 1"})

    table.update_item(
        Key={"PK": f"ROOM#{room_id}", "SK": "META"},
        UpdateExpression="SET targetRate = :r",
        ExpressionAttributeValues={":r": new_rate},
    )

    return _response(200, {"roomId": room_id, "targetRate": new_rate})


def _most_recent_room():
    # Tracks whichever room was created most recently, not a fixed id -
    # so demo-control automatically follows whatever room a presenter
    # just created live, with nothing to keep in sync by hand.
    resp = table.scan(FilterExpression="SK = :meta", ExpressionAttributeValues={":meta": "META"})
    items = resp.get("Items", [])
    return max(items, key=lambda r: r.get("createdAt", ""), default=None)


def _recent_traffic_request_count():
    """Sum of real requests the protected-site ALB target group has seen in
    the last 60s, or None if the fixture isn't configured yet.

    Toggling the fixture's mode only changes how it *responds* - it does
    nothing on its own to make any request happen. The Queue Controller's
    AIMD loop only ever sees "unhealthy" from actual routed requests
    landing on this target group (CloudWatch's TargetResponseTime /
    HTTPCode_Target_5XX_Count don't populate from the ALB's own health
    checks - see CLAUDE.md's demo/testing section and
    scripts/probe_protected_site.py's docstring). With zero requests,
    GetMetricData returns no datapoints at all, and the controller's own
    `(values_by_id.get(...) or [0.0])[0]` fallback reads that as "0ms
    latency, 0 errors" - i.e. healthy - regardless of which mode is set.
    Surfacing the request count directly is what makes that gap visible
    instead of looking like a broken controller.
    """
    if not PROTECTED_SITE_LB_ARN_SUFFIX or not PROTECTED_SITE_TARGET_GROUP_ARN_SUFFIX:
        return None

    dimensions = [
        {"Name": "LoadBalancer", "Value": PROTECTED_SITE_LB_ARN_SUFFIX},
        {"Name": "TargetGroup", "Value": PROTECTED_SITE_TARGET_GROUP_ARN_SUFFIX},
    ]
    try:
        resp = cloudwatch.get_metric_data(
            StartTime=time.time() - 60,
            EndTime=time.time(),
            MetricDataQueries=[{
                "Id": "requests",
                "MetricStat": {
                    "Metric": {
                        "Namespace": "AWS/ApplicationELB",
                        "MetricName": "RequestCount",
                        "Dimensions": dimensions,
                    },
                    "Period": 60,
                    "Stat": "Sum",
                },
                "ReturnData": True,
            }],
        )
        values = resp["MetricDataResults"][0]["Values"]
        return int(values[0]) if values else 0
    except ClientError as exc:
        print(f"failed to read traffic metric: {exc}")
        return None


def demo_status(event):
    # Deliberately unauthenticated demo-only endpoint - see module docstring.
    mode = "unknown"
    try:
        resp = table.get_item(Key=MODE_KEY)
        item = resp.get("Item")
        if item and "mode" in item:
            mode = item["mode"]
    except ClientError as exc:
        print(f"failed to read mode: {exc}")

    room = _most_recent_room()

    room_stats = None
    if room:
        next_number = int(room.get("nextNumber", 0))
        admitted_count = int(room.get("admittedCount", 0))
        room_stats = {
            "roomId": room["PK"].split("#", 1)[1],
            "name": room.get("name"),
            "targetRate": int(room.get("targetRate", 0)),
            "admittedCount": admitted_count,
            "waiting": max(next_number - admitted_count, 0),
        }

    return _response(200, {
        "mode": mode,
        "room": room_stats,
        "requestsLast60s": _recent_traffic_request_count(),
    })


def demo_set_mode(event):
    # Deliberately unauthenticated demo-only endpoint - see module docstring.
    body = json.loads(event.get("body") or "{}")
    mode = body.get("mode")
    if mode not in VALID_MODES:
        return _response(400, {"error": f"mode must be one of {sorted(VALID_MODES)}"})

    table.put_item(Item={**MODE_KEY, "mode": mode})
    return _response(200, {"mode": mode})


def demo_reset_room(event):
    # Deliberately unauthenticated demo-only endpoint - see module docstring.
    # Resets nextNumber/admittedCount to 0 on whichever room demo-status is
    # currently tracking - the "Reset room" button on demo-control.
    # targetRate is left alone: the Queue Controller owns that value and
    # will keep adjusting it regardless (see scripts/reset_demo_room.py,
    # the CLI equivalent, for the same reasoning spelled out in full).
    room = _most_recent_room()
    if not room:
        return _response(404, {"error": "no room to reset"})

    table.update_item(
        Key={"PK": room["PK"], "SK": "META"},
        UpdateExpression="SET nextNumber = :z, admittedCount = :z",
        ExpressionAttributeValues={":z": 0},
    )
    return _response(200, {"roomId": room["PK"].split("#", 1)[1], "reset": True})


ROUTES = {
    "POST /rooms": create_room,
    "GET /rooms": list_rooms,
    "GET /rooms/{roomId}": get_room_stats,
    "PATCH /rooms/{roomId}": update_room,
    "GET /demo/status": demo_status,
    "POST /demo/mode": demo_set_mode,
    "POST /demo/reset": demo_reset_room,
}


def handler(event, context):
    route_key = event.get("routeKey", "")
    fn = ROUTES.get(route_key)
    if not fn:
        return _response(404, {"error": "not found"})

    try:
        return fn(event)
    except Exception as exc:  # noqa: BLE001
        print(f"error handling {route_key}: {exc}")
        return _response(500, {"error": "internal error"})
