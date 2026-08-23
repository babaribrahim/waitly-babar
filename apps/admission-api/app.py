"""Admission API — thin FastAPI service on ECS Fargate.

Endpoints (see CLAUDE.md for the full spec and DynamoDB single-table schema):
  POST /rooms/{room_id}/join                    -> assign the next visitor number
  GET  /rooms/{room_id}/status/{visitor_number}  -> waiting/admitted + position
  POST /rooms/{room_id}/token/{visitor_number}   -> one-time entry token
  GET  /health                                   -> liveness only (no DynamoDB
                                                     call) — used by the ALB
                                                     target group health check
                                                     and the CodeDeploy
                                                     validation Lambda hook

DynamoDB is the only dependency, reached through the account's default
credential chain (the ECS task role — see infra/live/admission_api.tf).
There is no room-creation logic here: rooms are created by the Room Admin
API (a later phase). /join fails with 404 against a room that doesn't
already exist rather than silently creating one.
"""

import os
import secrets
import time
from datetime import datetime, timezone

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError
from fastapi import FastAPI, HTTPException

TABLE_NAME = os.environ["TABLE_NAME"]
AWS_REGION = os.environ.get("AWS_REGION", "us-west-2")

VISITOR_TTL_SECONDS = 6 * 60 * 60  # ~6h, matches CLAUDE.md
TOKEN_TTL_SECONDS = 5 * 60  # ~5min, matches CLAUDE.md

# Explicit, short timeout so a network gap (e.g. a missing VPC endpoint)
# fails fast and loud instead of hanging a request indefinitely - see
# apps/queue-controller/app.py's docstring for why this was added.
BOTO_CONFIG = Config(connect_timeout=5, read_timeout=10, retries={"max_attempts": 2})

dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION, config=BOTO_CONFIG)
table = dynamodb.Table(TABLE_NAME)

app = FastAPI(title="Waitly Admission API")


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _visitor_sk(visitor_number: int) -> str:
    return f"VISITOR#{visitor_number:010d}"


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/rooms/{room_id}/join", status_code=201)
def join(room_id: str):
    # Atomic counter: ADD on the room's META item. This is what guarantees
    # zero collisions under a burst with no read-modify-write race — see
    # CLAUDE.md's DynamoDB section. attribute_exists(PK) stops /join from
    # silently creating a "room" that was never set up by an organizer.
    try:
        resp = table.update_item(
            Key={"PK": f"ROOM#{room_id}", "SK": "META"},
            UpdateExpression="ADD nextNumber :inc",
            ConditionExpression="attribute_exists(PK)",
            ExpressionAttributeValues={":inc": 1},
            ReturnValues="UPDATED_NEW",
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            raise HTTPException(status_code=404, detail="room not found")
        raise

    visitor_number = int(resp["Attributes"]["nextNumber"])

    table.put_item(
        Item={
            "PK": f"ROOM#{room_id}",
            "SK": _visitor_sk(visitor_number),
            "joinedAt": _now_iso(),
            "ttl": int(time.time()) + VISITOR_TTL_SECONDS,
        }
    )

    return {"visitorNumber": visitor_number}


@app.get("/rooms/{room_id}/status/{visitor_number}")
def status(room_id: str, visitor_number: int):
    resp = table.get_item(Key={"PK": f"ROOM#{room_id}", "SK": "META"})
    if "Item" not in resp:
        raise HTTPException(status_code=404, detail="room not found")

    admitted_count = int(resp["Item"].get("admittedCount", 0))

    if visitor_number <= admitted_count:
        return {"status": "admitted", "position": 0}

    return {"status": "waiting", "position": visitor_number - admitted_count}


@app.post("/rooms/{room_id}/token/{visitor_number}", status_code=201)
def issue_token(room_id: str, visitor_number: int):
    resp = table.get_item(Key={"PK": f"ROOM#{room_id}", "SK": "META"})
    if "Item" not in resp:
        raise HTTPException(status_code=404, detail="room not found")

    admitted_count = int(resp["Item"].get("admittedCount", 0))
    if visitor_number > admitted_count:
        raise HTTPException(status_code=403, detail="visitor not yet admitted")

    token = secrets.token_urlsafe(24)

    # Deterministic PK (room + visitor number) is what makes this a genuine
    # conditional write, not just a uniqueness check on a random id: a
    # second call for the same visitor collides on the same key and the
    # ConditionExpression rejects it — "cannot be issued twice for the same
    # visitor" is enforced by DynamoDB itself, not application logic.
    try:
        table.put_item(
            Item={
                "PK": f"TOKEN#{room_id}:{visitor_number}",
                "SK": "TOKEN",
                "roomId": room_id,
                "visitorNumber": visitor_number,
                "token": token,
                "used": False,
                "ttl": int(time.time()) + TOKEN_TTL_SECONDS,
            },
            ConditionExpression="attribute_not_exists(PK)",
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            raise HTTPException(status_code=409, detail="token already issued for this visitor")
        raise

    return {"token": token}
