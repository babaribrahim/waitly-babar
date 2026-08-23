# Reference: the proven hello-world blue/green pattern

**This directory is not live Terraform.** It's a frozen, non-wired snapshot of
the exact resources that proved out ECS Fargate + ALB + CodeDeploy blue/green
with a canary step and a validation Lambda hook — the highest-risk mechanism
in this project, deliberately proven on throwaway infra before any real
service was built (see `CLAUDE.md`'s build order).

Two real, successful blue/green deployments were run against this exact
configuration on 2026-08-22:
- `d-MCIFDPNIK` — recovery deploy (broken initial state → healthy "blue/v1")
- `d-H9DFQTNIK` — the real proof: a clean blue→green swap between two
  already-healthy versions, including a passing `AfterAllowTestTraffic`
  validation-Lambda hook, confirmed by `curl`ing the ALB before/after.

The AWS resources these files describe have since been torn down and
replaced with the real Admission API (`infra/live/admission_api.tf` and
friends), which is a direct clone of this same pattern — same ALB
blue/green target-group-pair shape, same canary deployment config
(`CodeDeployDefault.ECSCanary10Percent5Minutes`), same validation-Lambda
hook design, same `ignore_changes` lifecycle gotchas worked out here. When
building the Queue Controller next, clone from the *live* Admission API
resources (they're the same pattern, now with real DynamoDB/IAM wiring
included), not from this snapshot.

Files here mirror what was applied under `infra/live/` at that point:
`alb.tf`, `ecr.tf`, `ecs.tf`, `codedeploy.tf`, `validation_lambda.tf`,
`iam.tf`, `lambda_src/validate_hello_world.py`, and the app's
`hello-world.Dockerfile`. They won't `terraform init`/`plan` on their own
(no `providers.tf`/`versions.tf`/backend here) — that's intentional, this
is documentation, not a second stack to maintain.
