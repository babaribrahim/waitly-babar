#!/usr/bin/env python
"""Build, push, and roll out a new revision of the protected-site fixture.

Plain ECS rolling deployment, not CodeDeploy - this fixture is a demo
prop, not one of the three real services, so the blue/green mechanism
(already proven three times over on the real services) isn't warranted
here.

Usage:
    python scripts/deploy_protected_site.py v1

Requires: docker, aws CLI, terraform - all on PATH - and active AWS
credentials.
"""

import argparse
import json
import subprocess
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
LIVE_DIR = REPO_ROOT / "infra" / "live"
CONTAINER_NAME = "protected-site"
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
    return {k: v["value"] for k, v in json.loads(raw).items()}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("version", help="Version label used as the ECR image tag, e.g. v1")
    parser.add_argument("--skip-build", action="store_true", help="Skip docker build/push, reuse an already-pushed tag")
    args = parser.parse_args()

    outputs = terraform_outputs()
    ecr_url = outputs["protected_site_ecr_repository_url"]
    region = outputs["region"]
    family = outputs["protected_site_task_definition_family"]
    exec_role_arn = outputs["ecs_task_execution_role_arn"]
    task_role_arn = outputs["protected_site_task_role_arn"]
    log_group = outputs["protected_site_log_group_name"]
    cluster = outputs["ecs_cluster_name"]
    service = outputs["protected_site_service_name"]
    table_name = outputs["dynamodb_table_name"]

    app_dir = REPO_ROOT / "apps" / CONTAINER_NAME
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
        run(["docker", "build", "-t", image_uri, str(app_dir)])

        print(f"\n==> Pushing {image_uri}")
        run(["docker", "push", image_uri])

    print("\n==> Registering new ECS task definition revision")
    container_def = [{
        "name": CONTAINER_NAME,
        "image": image_uri,
        "essential": True,
        "portMappings": [{"containerPort": CONTAINER_PORT, "protocol": "tcp"}],
        "environment": [
            {"name": "TABLE_NAME", "value": table_name},
            {"name": "AWS_REGION", "value": region},
            {"name": "SLOW_DELAY_SECONDS", "value": "3"},
        ],
        "logConfiguration": {
            "logDriver": "awslogs",
            "options": {
                "awslogs-group": log_group,
                "awslogs-region": region,
                "awslogs-stream-prefix": CONTAINER_NAME,
            },
        },
    }]

    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
        json.dump(container_def, f)
        container_def_path = f.name

    task_def_arn = capture(
        [
            "aws", "ecs", "register-task-definition",
            "--region", region,
            "--family", family,
            "--requires-compatibilities", "FARGATE",
            "--network-mode", "awsvpc",
            "--cpu", "256",
            "--memory", "512",
            "--execution-role-arn", exec_role_arn,
            "--task-role-arn", task_role_arn,
            "--container-definitions", f"file://{container_def_path}",
            "--query", "taskDefinition.taskDefinitionArn",
            "--output", "text",
        ]
    )
    print(f"New task definition: {task_def_arn}")

    print("\n==> Updating ECS service (plain rolling deployment, no CodeDeploy)")
    run(
        [
            "aws", "ecs", "update-service",
            "--region", region,
            "--cluster", cluster,
            "--service", service,
            "--task-definition", task_def_arn,
            "--output", "text",
            "--query", "service.serviceName",
        ]
    )

    print("\n==> Waiting for service to stabilize")
    run(["aws", "ecs", "wait", "services-stable", "--region", region, "--cluster", cluster, "--services", service])

    print(f"\n==> Deployed {image_uri}")


if __name__ == "__main__":
    main()
