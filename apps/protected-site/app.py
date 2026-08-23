"""Protected-site fixture - deliberately fragile demo prop.

NOT one of the three real microservices (see CLAUDE.md's demo/testing
section) - exists purely so the Queue Controller has something real to
react to. Reads its current "mode" from SSM Parameter Store on every
request to / (cached briefly to avoid hammering SSM):

  healthy - instant 200
  slow    - sleeps SLOW_DELAY_SECONDS, then 200
  error   - immediate 500

Runtime-togglable on purpose: mode changes take effect within
MODE_CACHE_SECONDS with no redeploy, no restart. Flip it with
scripts/toggle_protected_site.py, not an HTTP route - keeps this
fixture's own surface area minimal and avoids yet another auth question.

/health always responds instantly with 200 regardless of mode. That's the
ALB target group's health check path, kept immune on purpose: toggling to
"slow"/"error" should simulate a struggling app on its real traffic path,
not get the task itself killed and replaced by ECS.
"""

import os
import time

import boto3
from fastapi import FastAPI
from fastapi.responses import JSONResponse

MODE_PARAMETER_NAME = os.environ["MODE_PARAMETER_NAME"]
SLOW_DELAY_SECONDS = float(os.environ.get("SLOW_DELAY_SECONDS", "3"))
AWS_REGION = os.environ.get("AWS_REGION", "us-west-2")
MODE_CACHE_SECONDS = 5

ssm = boto3.client("ssm", region_name=AWS_REGION)

app = FastAPI(title="Waitly Protected Site Fixture")

_mode_cache = {"value": "healthy", "fetchedAt": 0.0}


def get_mode() -> str:
    now = time.time()
    if now - _mode_cache["fetchedAt"] > MODE_CACHE_SECONDS:
        try:
            resp = ssm.get_parameter(Name=MODE_PARAMETER_NAME)
            _mode_cache["value"] = resp["Parameter"]["Value"]
            _mode_cache["fetchedAt"] = now
        except Exception as exc:  # noqa: BLE001 - keep serving the last-known mode
            print(f"failed to read mode parameter, keeping cached value '{_mode_cache['value']}': {exc}")
    return _mode_cache["value"]


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/")
def index():
    mode = get_mode()

    if mode == "error":
        return JSONResponse(status_code=500, content={"mode": mode, "error": "simulated failure"})

    if mode == "slow":
        time.sleep(SLOW_DELAY_SECONDS)

    return {"mode": mode}
