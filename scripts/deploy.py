#!/usr/bin/env python
"""Build, push, and blue/green-deploy a new revision of an ECS Fargate service.

Every invocation of this script — including the very first one — performs a
real AWS CodeDeploy blue/green deployment: it registers a new ECS task
definition revision and asks CodeDeploy to stand up a new task set on
whichever target group (blue or green) is currently idle, run the canary
steps, invoke the validation Lambda against the test listener, and only then
cut prod traffic over. CodeDeploy — not this script — decides which ALB
target group is "blue" and which is "green" at deploy time; this script only
ever talks about app *versions* (v1, v2, ...) to avoid confusing that with
CodeDeploy's own blue/green target-group bookkeeping.

Generic across services on purpose: it reads everything (ECR repo, task
family, container name, task/execution roles, log group, CodeDeploy
app/deployment group, validation Lambda ARN) from `terraform output -json`
in infra/live rather than hardcoding a single service, and the app's build
context is assumed to live at apps/<container_name>/. That's what makes
this the reusable "known-good template" the Admission API cloned from
hello-world's proof, and what future services (Queue Controller) can clone
from too, without editing this script.

Usage:
    python scripts/deploy.py v1
    python scripts/deploy.py v2

Requires: docker, aws CLI, terraform — all on PATH — and active AWS
credentials.
"""

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
LIVE_DIR = REPO_ROOT / "infra" / "live"
CONTAINER_PORT = 80


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


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("version", help="Version label used as the ECR image tag, e.g. v1")
    parser.add_argument("--color", default="steelblue", help="Cosmetic build-arg some apps (e.g. hello-world) use; harmless if unused")
    parser.add_argument("--skip-build", action="store_true", help="Skip docker build/push, reuse an already-pushed tag")
    args = parser.parse_args()

    outputs = terraform_outputs()
    ecr_url = outputs["ecr_repository_url"]
    region = outputs["region"]
    family = outputs["task_definition_family"]
    container_name = outputs["container_name"]
    exec_role_arn = outputs["ecs_task_execution_role_arn"]
    task_role_arn = outputs.get("ecs_task_role_arn")  # not every service needs one
    table_name = outputs.get("dynamodb_table_name")  # not every service uses DynamoDB
    log_group = outputs["log_group_name"]
    app_name = outputs["codedeploy_app_name"]
    dg_name = outputs["codedeploy_deployment_group_name"]
    lambda_arn = outputs["validation_lambda_arn"]

    app_dir = REPO_ROOT / "apps" / container_name
    image_uri = f"{ecr_url}:{args.version}"
    registry_host = ecr_url.split("/")[0]

    if not args.skip_build:
        print(f"\n==> Logging in to ECR ({registry_host})")
        password = capture(["aws", "ecr", "get-login-password", "--region", region])
        run(
            ["docker", "login", "--username", "AWS", "--password-stdin", registry_host],
            input=password,
            text=True,
        )

        print(f"\n==> Building {image_uri}")
        run(
            [
                "docker", "build",
                "--build-arg", f"COLOR={args.color}",
                "--build-arg", f"VERSION={args.version}",
                "-t", image_uri,
                str(app_dir),
            ]
        )

        print(f"\n==> Pushing {image_uri}")
        run(["docker", "push", image_uri])

    print("\n==> Registering new ECS task definition revision")
    environment = [{"name": "AWS_REGION", "value": region}]
    if table_name:
        environment.append({"name": "TABLE_NAME", "value": table_name})

    container_def = [{
        "name": container_name,
        "image": image_uri,
        "essential": True,
        "portMappings": [{"containerPort": CONTAINER_PORT, "protocol": "tcp"}],
        "environment": environment,
        "logConfiguration": {
            "logDriver": "awslogs",
            "options": {
                "awslogs-group": log_group,
                "awslogs-region": region,
                "awslogs-stream-prefix": container_name,
            },
        },
    }]

    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
        json.dump(container_def, f)
        container_def_path = f.name

    register_cmd = [
        "aws", "ecs", "register-task-definition",
        "--region", region,
        "--family", family,
        "--requires-compatibilities", "FARGATE",
        "--network-mode", "awsvpc",
        "--cpu", "256",
        "--memory", "512",
        "--execution-role-arn", exec_role_arn,
        "--container-definitions", f"file://{container_def_path}",
        "--query", "taskDefinition.taskDefinitionArn",
        "--output", "text",
    ]
    if task_role_arn:
        register_cmd += ["--task-role-arn", task_role_arn]

    task_def_arn = capture(register_cmd)
    print(f"New task definition: {task_def_arn}")

    print("\n==> Creating CodeDeploy deployment")
    appspec_content = json.dumps({
        "version": "0.0",
        "Resources": [{
            "TargetService": {
                "Type": "AWS::ECS::Service",
                "Properties": {
                    "TaskDefinition": task_def_arn,
                    "LoadBalancerInfo": {
                        "ContainerName": container_name,
                        "ContainerPort": CONTAINER_PORT,
                    },
                },
            },
        }],
        "Hooks": [{"AfterAllowTestTraffic": lambda_arn}],
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

    print("\n==> Waiting for deployment to complete (canary steps + validation hook, can take ~10-15 min)")
    try:
        run(["aws", "deploy", "wait", "deployment-successful", "--region", region, "--deployment-id", deployment_id])
    except subprocess.CalledProcessError:
        print(f"\nDeployment did not succeed. Inspect it with:")
        print(f"  aws deploy get-deployment --region {region} --deployment-id {deployment_id}")
        sys.exit(1)

    print(f"\n==> Deployment {deployment_id} succeeded")
    print(f"    http://{outputs['alb_dns_name']}/")


if __name__ == "__main__":
    main()
