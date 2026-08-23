#!/usr/bin/env python
"""Zip, publish, and blue/green-deploy a new version of a Lambda service.

The Lambda equivalent of scripts/deploy.py: reads a service's Terraform
outputs, publishes a new Lambda version, and drives a real CodeDeploy
deployment that shifts the "live" alias's traffic from the old version to
the new one (canary, then full cutover) - not a plain update-alias.

Different deploy mechanism from the ECS services on purpose: Lambda
CodeDeploy deployments shift weighted traffic between two numbered
versions of one function via an alias, no Docker image or ALB target
group involved.

Usage:
    python scripts/deploy_lambda.py room-admin-api

Requires: aws CLI, terraform - both on PATH - and active AWS credentials.
"""

import argparse
import json
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
LIVE_DIR = REPO_ROOT / "infra" / "live"


def run(cmd, **kwargs):
    print(f"+ {' '.join(cmd)}")
    return subprocess.run(cmd, check=True, **kwargs)


def capture(cmd, **kwargs):
    print(f"+ {' '.join(cmd)}")
    result = subprocess.run(cmd, check=True, capture_output=True, text=True, **kwargs)
    return result.stdout.strip()


def terraform_outputs():
    raw = capture(["terraform", f"-chdir={LIVE_DIR}", "output", "-json"])
    parsed = json.loads(raw)
    return {k: v["value"] for k, v in parsed.items()}


def zip_app_dir(app_dir: Path, zip_path: Path):
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for path in sorted(app_dir.rglob("*")):
            if path.is_file():
                zf.write(path, path.relative_to(app_dir))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("service", help="Service name, e.g. room-admin-api")
    args = parser.parse_args()

    outputs = terraform_outputs()
    service_key = args.service.replace("-", "_")
    if service_key not in outputs:
        available = ", ".join(k.replace("_", "-") for k in outputs if isinstance(outputs[k], dict))
        print(f"Unknown service '{args.service}'. Available: {available}")
        sys.exit(1)
    svc = outputs[service_key]

    region = outputs["region"]
    function_name = svc["function_name"]
    alias_name = svc["alias_name"]
    app_name = svc["codedeploy_app_name"]
    dg_name = svc["codedeploy_deployment_group_name"]

    app_dir = REPO_ROOT / "apps" / args.service

    print(f"\n==> Current version behind alias '{alias_name}'")
    current_version = capture(
        [
            "aws", "lambda", "get-alias",
            "--region", region,
            "--function-name", function_name,
            "--name", alias_name,
            "--query", "FunctionVersion",
            "--output", "text",
        ]
    )
    print(f"Current version: {current_version}")

    with tempfile.TemporaryDirectory() as tmp:
        zip_path = Path(tmp) / "function.zip"
        print(f"\n==> Zipping {app_dir}")
        zip_app_dir(app_dir, zip_path)

        print("\n==> Publishing new Lambda version")
        new_version = capture(
            [
                "aws", "lambda", "update-function-code",
                "--region", region,
                "--function-name", function_name,
                "--zip-file", f"fileb://{zip_path}",
                "--publish",
                "--query", "Version",
                "--output", "text",
            ]
        )
    print(f"New version: {new_version}")

    if new_version == current_version:
        print("New version is identical to the current one (no code change) - nothing to deploy.")
        return

    print("\n==> Waiting for the new version to finish updating")
    run(
        [
            "aws", "lambda", "wait", "function-updated",
            "--region", region,
            "--function-name", function_name,
            "--qualifier", new_version,
        ]
    )

    print("\n==> Creating CodeDeploy deployment")
    appspec_content = json.dumps({
        "version": "0.0",
        "Resources": [{
            "RoomAdminFunction": {
                "Type": "AWS::Lambda::Function",
                "Properties": {
                    "Name": function_name,
                    "Alias": alias_name,
                    "CurrentVersion": current_version,
                    "TargetVersion": new_version,
                },
            },
        }],
    })

    deployment_request = {
        "applicationName": app_name,
        "deploymentGroupName": dg_name,
        "revision": {
            "revisionType": "AppSpecContent",
            "appSpecContent": {"content": appspec_content},
        },
    }

    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
        json.dump(deployment_request, f)
        request_path = f.name

    deployment_id = capture(
        [
            "aws", "deploy", "create-deployment",
            "--region", region,
            "--cli-input-json", f"file://{request_path}",
            "--query", "deploymentId",
            "--output", "text",
        ]
    )
    print(f"Deployment ID: {deployment_id}")

    print("\n==> Waiting for deployment to complete (canary steps, can take ~5-10 min)")
    try:
        run(["aws", "deploy", "wait", "deployment-successful", "--region", region, "--deployment-id", deployment_id])
    except subprocess.CalledProcessError:
        print(f"\nDeployment did not succeed. Inspect it with:")
        print(f"  aws deploy get-deployment --region {region} --deployment-id {deployment_id}")
        sys.exit(1)

    print(f"\n==> Deployment {deployment_id} succeeded")
    print(f"    {outputs[service_key]['api_endpoint']}")


if __name__ == "__main__":
    main()
