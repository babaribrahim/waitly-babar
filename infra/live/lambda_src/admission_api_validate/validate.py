"""CodeDeploy AfterAllowTestTraffic validation hook for the Admission API.

Cloned from the hello-world proof (see
infra/reference/hello-world-blue-green/lambda_src/validate_hello_world.py) —
same mechanism, now checking the real service's /health endpoint.

Runs after CodeDeploy has shifted the new task set's traffic onto the ALB's
test listener (port 8080) but before any of it reaches the prod listener.
Makes one HTTP request against the test listener and reports success or
failure back to CodeDeploy, which decides whether to proceed or roll back.
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
