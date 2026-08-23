#!/usr/bin/env bash
set -euo pipefail

# Initializes and applies infra/live against the remote S3 backend created
# by scripts/bootstrap.sh. Requires AWS credentials already active.

cd "$(dirname "$0")/../infra/live"

if [ ! -f backend.hcl ]; then
  echo "backend.hcl not found — run scripts/bootstrap.sh first." >&2
  exit 1
fi

terraform init -backend-config=backend.hcl -reconfigure
terraform plan -out=tfplan
terraform apply tfplan
rm -f tfplan

echo ""
echo "infra/live applied. ECS tasks will fail to pull the initial ':blue'"
echo "image until something actually pushes it — that's expected. Next:"
echo "  python scripts/deploy.py v1 --color blue"
