#!/usr/bin/env bash
set -euo pipefail

# Applies infra/bootstrap (creates the Terraform state S3 bucket, kept in
# local state on purpose — see infra/bootstrap/versions.tf) and writes
# infra/live/backend.hcl so infra/live can be initialized against it.
#
# Requires AWS credentials already active, e.g.:
#   aws sso login --profile sbx
#   export AWS_PROFILE=sbx     # or: $env:AWS_PROFILE = "sbx"  in PowerShell

cd "$(dirname "$0")/../infra/bootstrap"

terraform init
terraform apply -auto-approve

BUCKET=$(terraform output -raw state_bucket_name)

cat > ../live/backend.hcl <<EOF
bucket = "${BUCKET}"
EOF

echo ""
echo "State bucket: ${BUCKET}"
echo "Wrote infra/live/backend.hcl"
echo "Next: scripts/live_init_apply.sh"
