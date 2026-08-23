# Waitly — Virtual Waiting Room System

A virtual waiting room (like Queue-it / Cloudflare Waiting Room) that
protects a downstream site from traffic bursts by queuing visitors and
admitting them at a rate the site can actually handle. Portfolio/learning
project — full spec, hard constraints, and design rationale in
[CLAUDE.md](CLAUDE.md).

**Stack:** AWS only, all infra in Terraform. 3 microservices — Admission
API (ECS Fargate), Queue Controller (ECS Fargate), Room Admin API (Lambda +
API Gateway) — DynamoDB single-table, CodeDeploy blue/green + canary +
validation-Lambda hook, CodePipeline/CodeBuild for app deploys, Route
53/ACM/CloudFront for the frontend. Region `us-west-2` throughout, except
the CloudFront ACM cert (`us-east-1`, a hard AWS requirement).

## Status

- [x] Terraform remote-state backend (S3, native locking)
- [x] VPC/networking (private subnets, no NAT — VPC endpoints instead)
- [x] Blue/green + canary + validation-hook deployment mechanism, proven on
      a disposable hello-world service before any real service was built
      (see [infra/reference/hello-world-blue-green/](infra/reference/hello-world-blue-green/))
- [x] DynamoDB single-table
- [x] Admission API (join / status / token), deployed via the proven
      pattern, verified under concurrent load (20 parallel `/join` calls →
      zero duplicates, zero gaps)
- [ ] Queue Controller (AIMD health-polling loop)
- [ ] Room Admin API (Lambda)
- [ ] Frontend (S3 + CloudFront + Route 53 subdomain)
- [ ] CodePipeline (source → build → deploy) for the application services
- [ ] Protected-site fixture + k6 load test

## Repo layout

```
infra/
  bootstrap/    Terraform state bucket — applied once manually, local state
  live/         Everything else — VPC, ALB, ECS, CodeDeploy, DynamoDB, IAM...
  reference/    Frozen snapshots of proven patterns (not live Terraform)
apps/
  admission-api/   FastAPI service, deployed to ECS Fargate
  hello-world/     The disposable proof service (decommissioned; see infra/reference/)
scripts/
  deploy.py     Generic build → push → CodeDeploy blue/green deploy, works
                against whatever service's Terraform outputs are currently live
```

## Running Terraform

Applied manually from a local machine (no infra pipeline — see CLAUDE.md).

```
scripts/bootstrap.sh          # one-time: creates the state bucket
scripts/live_init_apply.sh    # infra/live: VPC, ALB, ECS, CodeDeploy, DynamoDB...
python scripts/deploy.py v1   # build, push, and blue/green-deploy a service
```

Requires AWS credentials for the sandbox account and Docker running locally.
