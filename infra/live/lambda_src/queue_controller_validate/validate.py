"""CodeDeploy AfterAllowTestTraffic validation hook for the Queue Controller.

Same mechanism as the Admission API's hook (and the hello-world proof
before it) — checks the test listener's /health, reports success or
failure back to CodeDeploy.
"""

import json
import os
import urllib.request

import boto3

codedeploy = boto3.client("codedeploy")


def handler(event, context):
    print(f"Validation hook event: {json.dumps(event)}")

    deployment_id = event["DeploymentId"]
    hook_execution_id = event["LifecycleEventHookExecutionId"]

    status = "Failed"
    try:
        url = os.environ["TEST_ENDPOINT"]
        with urllib.request.urlopen(url, timeout=5) as response:
            if response.status == 200:
                status = "Succeeded"
            else:
                print(f"Unexpected status code from {url}: {response.status}")
    except Exception as exc:  # noqa: BLE001 - any failure here means validation failed
        print(f"Validation request failed: {exc}")

    codedeploy.put_lifecycle_event_hook_execution_status(
        deploymentId=deployment_id,
        lifecycleEventHookExecutionId=hook_execution_id,
        status=status,
    )

    return {"status": status}
