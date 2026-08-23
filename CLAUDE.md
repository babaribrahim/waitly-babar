# Project: Virtual Waiting Room System

Build a virtual waiting room system — similar to Queue-it or Cloudflare Waiting Room — that protects a downstream website from traffic bursts by queuing visitors and admitting them at a rate the site can actually handle, instead of letting everyone through at once and crashing it.

This is a portfolio/learning project. The infrastructure and design decisions are the point — the application logic in each service should be kept intentionally thin.

## Hard constraints (non-negotiable)

- **AWS only**, all infrastructure defined in **Terraform**
- **Compute: ECS on Fargate** for two of the three services (no EC2, no Lambda-only architecture for those two)
- **Primary database: DynamoDB**, single table design — no relational database anywhere in this system
- **Exactly 3 microservices**, each with a real, defensible boundary (not one app artificially split)
- **Deployment: blue/green + canary via AWS CodeDeploy**, orchestrated by **AWS CodePipeline** for the application services. **GitHub Actions is not permitted in this environment** — no part of this project uses it.
- **Cost must stay minimal** — this runs in a personal/shared dev account, not production scale. No NAT Gateway. Use VPC endpoints instead.
- **A real domain is available**: `internship.cloudelligent-sandbox.com`, a **shared** hosted zone in this AWS sandbox account (other interns are almost certainly using it too). The system must be reachable on our own subdomain of it via Route 53 — not raw CloudFront/AWS-generated DNS names — and that subdomain needs to be specific enough not to collide with anyone else's project in the same zone (plain `queue.` is risky if others picked something similarly generic — see the DNS section for the actual value used).
- **Mandatory resource tags**: every supported AWS resource this project creates must carry an `Owner` tag and an `Environment` tag. No exceptions — if a resource type doesn't support tags, note that explicitly rather than silently skipping it.
- **Region: everything in `us-west-2` (Oregon).** No resources in any other region — with exactly one unavoidable exception, noted in the DNS/TLS section below, which is a hard platform limitation, not a choice.

## Why each compute choice was made (context for Claude Code, not to be re-litigated)

- **Admission API → ECS Fargate.** Needs to stay warm and ready before a traffic burst hits — a cold Lambda start during the exact moment of a burst would hurt the users who matter most.
- **Queue Controller → ECS Fargate.** Needs to poll site health every few seconds. EventBridge's native Lambda scheduling can't fire more often than once a minute, which rules Lambda out here on a hard technical constraint, not a preference.
- **Room Admin API → AWS Lambda + API Gateway.** Low, occasional traffic (an organizer setting up an event, checking stats). Doesn't need to stay warm, so a full-time container isn't justified for it.
- **ALB is mandatory, not a preference, for the Fargate side.** AWS CodeDeploy's blue/green deployment type for ECS requires a load balancer, and only Application or Network Load Balancers are supported — API Gateway is not a valid target for this mechanism. API Gateway remains the entry point for the Lambda service specifically, where it's the idiomatic, well-supported pairing (built-in request validation and throttling), not a hard requirement the way the ALB is.

## Architecture overview

```
Visitors ──┐
           ├─→ Route 53 (subdomain) ─→ Frontend (S3 private + CloudFront) ─┬─→ ALB ──────→ Admission API (Fargate) ──┐
Organizer ─┘                                                                └─→ API Gateway → Room Admin API (Lambda) ─┤
                                                                                                                       ├─→ DynamoDB (single table)
                              Queue Controller (Fargate, background loop) ──→ CloudWatch ──────────────────────────────┘
                                        │
                                        └─→ advances the "admitted" counter in DynamoDB
```

- Admission API and Queue Controller run inside a **VPC** (private subnets), reaching DynamoDB via a **gateway VPC endpoint** and ECR/CloudWatch Logs via **interface VPC endpoints** — no NAT Gateway needed.
- Room Admin API (Lambda) needs **no VPC** — it reaches AWS services directly.
- The frontend is reachable on a real subdomain (`waitly.internship.cloudelligent-sandbox.com`) via Route 53, not the default `*.cloudfront.net` address.

## DNS and TLS (Route 53 + ACM)

- The domain itself already exists in this AWS account (assigned by the sandbox): **`internship.cloudelligent-sandbox.com`**. It's a shared hosted zone — **do not create a new hosted zone**. Look it up with a Terraform data source (`data "aws_route53_zone" "shared" { name = "internship.cloudelligent-sandbox.com" }`) instead of provisioning one.
- Create **one subdomain** for the system, `waitly.internship.cloudelligent-sandbox.com`, as a Route 53 **alias record** pointing at the CloudFront distribution. This is the only DNS record genuinely needed — visitors and organizers only ever type or click this one address; the ALB and API Gateway are called by the frontend's own JavaScript using their AWS-generated DNS names, which never need to be human-friendly since no person types them directly. Adding custom subdomains for those too would be a decorative addition, not a functional one — skip it unless there's a specific reason to want it later.
- **ACM certificate gotcha to handle correctly — this is the one exception to the Oregon-only rule, and it's non-negotiable:** CloudFront requires its ACM certificate to be issued in **us-east-1**, regardless of which region the rest of the stack lives in. This isn't a design choice — CloudFront simply won't accept a certificate from any other region, including `us-west-2`. Use a second, aliased AWS provider block scoped to `us-east-1` specifically for this one certificate resource, and validate it via DNS (a Route 53 record Terraform creates automatically from the certificate's validation options). Every other resource in the project stays in `us-west-2`.

## Service 1: Admission API (ECS Fargate)

Public-facing service behind the ALB. This is what visitors' browsers talk to directly. Bursty, stateless, must scale fast.

**Endpoints:**
- `POST /rooms/{roomId}/join` — creates a visitor record, atomically assigns the next sequential queue number, returns it to the caller.
- `GET /rooms/{roomId}/status/{visitorNumber}` — compares the visitor's number to the room's current "admitted up to" counter; returns waiting/admitted + estimated position.
- `POST /rooms/{roomId}/token/{visitorNumber}` — once admitted, exchanges the visitor's spot for a one-time entry token (conditional write, cannot be issued twice for the same visitor).

## Service 2: Queue Controller (ECS Fargate)

Background service, no public endpoint, runs continuously. Nobody calls this directly.

**Loop, every few seconds:**
1. Read the protected site's health from CloudWatch (ALB target group latency + error rate for the protected-site fixture).
2. Decide the next admission rate using **AIMD (additive increase, multiplicative decrease)**:
   - Healthy → increase the admission rate by a small fixed amount.
   - Unhealthy (error rate or latency crosses a threshold) → cut the rate in half immediately.
3. Advance the room's "admitted up to" counter in DynamoDB by the decided amount (a single atomic `ADD`, not a per-visitor write).

This asymmetric increase/decrease shape is deliberate — it's the same principle as TCP congestion control, and it's what prevents the system from oscillating (overshoot → crash → overcorrect → repeat).

## Service 3: Room Admin API (AWS Lambda + API Gateway)

For event organizers, not end visitors. Low traffic, doesn't need to stay warm.

**Endpoints:**
- `POST /rooms` — create a new room: name, protected URL, starting target rate. Generates the room's shareable public link. Also generates an admin key (store only its hash).
- `GET /rooms` — list all rooms for the organizer (homepage view).
- `GET /rooms/{roomId}` — live stats: currently waiting, admitted so far, current rate, avg wait.
- `PATCH /rooms/{roomId}` — update target admission rate mid-event.

Auth: simple admin-key-hash check per room (stored in the same DynamoDB table) — proportionate to project scope, not a full auth system.

## DynamoDB table design

**One table.** Every access pattern below is a direct key lookup — no GSIs needed, no joins, no ad-hoc queries. That's the actual justification for DynamoDB here; if any access pattern needed "give me all rooms sorted by X" or a multi-table join, that would be the wrong fit — it isn't, because nothing in this system needs that.

| PK | SK | Contents |
|---|---|---|
| `ROOM#<roomId>` | `META` | protectedUrl, targetRate, `nextNumber` (atomic counter), `admittedCount` (atomic counter), adminKeyHash, createdAt |
| `ROOM#<roomId>` | `VISITOR#<zero-padded number>` | joinedAt, **TTL ~6h** (abandoned visitors self-delete, no cleanup job needed) |
| `TOKEN#<tokenId>` | `TOKEN` | roomId, visitorNumber, `used` (bool), **TTL ~5min** |

**Mechanisms to implement explicitly:**
- **Atomic counters** (`UpdateItem` with `ADD`) for `nextNumber` (on join) and `admittedCount` (on Queue Controller's decision) — this is what guarantees zero collisions under a burst with no read-modify-write race.
- **Conditional writes** (`attribute_not_exists`) for token issuance and redemption — a token can only be created once per visitor and marked used only once; a replay attempt gets rejected by the database itself.
- **TTL** on visitor and token records — no manual cleanup logic needed.

**Known, deliberate limitation (be ready to explain, don't over-engineer around it):** every join for a given room updates one shared counter record — a single point of write contention. At this project's scale (low thousands of visitors in a demo) this is nowhere near its ceiling. The documented next step, if it ever needed to scale further, is sharding the counter across N partitions, trading perfectly exact ordering for higher throughput. **Do not build the sharded version** — build the simple single-counter version and be able to explain the tradeoff.

## Infrastructure / Terraform requirements

- **Resource tagging**: every supported resource must carry `Owner` and `Environment` tags. Implement this once, at the provider level, using the `default_tags` block on the `aws` provider (including the aliased `us-east-1` provider used for the ACM certificate) rather than tagging each resource individually — that way it's applied automatically and can't be forgotten when a new resource is added later. Fill in real values for `Owner` (your name) and `Environment` (e.g. `sandbox` or `dev`) rather than leaving placeholders.
- **Provider region**: the main `aws` provider block is `region = "us-west-2"`. The only other provider block in the whole project is the aliased one scoped to `us-east-1`, used exclusively for the CloudFront ACM certificate — nothing else should ever reference it.
- **Remote state**: S3 bucket for Terraform state, with state locking enabled (native S3 locking, or a DynamoDB lock table if using an older Terraform version) — standard good practice regardless of how Terraform gets run, and protects against a corrupted or lost local state file.
- VPC with private subnets for Fargate tasks only.
- **No NAT Gateway.** Gateway VPC endpoint for DynamoDB (free), interface VPC endpoints for ECR and CloudWatch Logs.
- ALB with two target groups (blue/green) in front of the Admission API and the Queue Controller (if it needs any health-check surface) — actual live traffic only goes to Admission API.
- API Gateway (HTTP API type) in front of the Room Admin Lambda, with a Lambda alias for CodeDeploy traffic shifting.
- ECR repository for the Fargate container images.
- **Route 53 + ACM**, as described above.
- **CodeDeploy**: `CODE_DEPLOY` deployment controller on the ECS services, with `lifecycle { ignore_changes = [task_definition, load_balancer] }` on those services since CodeDeploy mutates them out of band. Canary steps + a validation Lambda hook on at least one service (don't triple this up across all three — one solid example is enough).
- **CodePipeline + CodeBuild + a CodeStar Connection to GitHub** (source stays on GitHub — only the CI/CD *engine* is restricted, not the git host) — see the pipeline section below for how these fit together.
- S3 bucket (private, no public access) + CloudFront with Origin Access Control for the frontend.
- CloudWatch for logs and the metrics the Queue Controller polls.

**Build order — do this first, before any application code:** stand up a bare-bones "hello world" blue/green deployment through CodeDeploy on day one. This is the part most likely to eat unexpected time (target groups, `appspec.yaml`, the `ignore_changes` lifecycle block) — get it working before building the real services on top of it.

## Terraform changes: applied manually (no pipeline)

There is no automated pipeline for infrastructure changes. Run `terraform plan` and `terraform apply` from your own machine as needed. This is a deliberate scope cut, not an oversight — keep it simple, and the remote state backend above still protects the state file either way.

## CI/CD pipeline for the application (AWS CodePipeline)

This is what actually gets new code out — a new container image for the Admission API or Queue Controller, or new Lambda code for the Room Admin API. GitHub Actions isn't available in this environment, so this runs entirely on AWS-native tooling instead.

**Three stages:**

1. **Source** — CodePipeline pulls from the GitHub repo via a **CodeStar Connection**. This is what lets an AWS-native pipeline read a GitHub repo without needing GitHub Actions at all — the connection is just a read trigger, no GitHub-side compute involved.
2. **Build** — a **CodeBuild** project: builds the Docker image for whichever Fargate service changed, pushes it to ECR, and packages the Lambda deployment bundle for Room Admin API changes. Output artifacts (the new task definition / image URI, or the Lambda package) get passed to the next stage.
3. **Deploy** — a **CodeDeploy** action within the same pipeline, using the blue/green + canary configuration already defined in the infrastructure. This is where CodePipeline and CodeDeploy meet: CodePipeline orchestrates *when* a deployment happens and *what* gets deployed; CodeDeploy handles *how* the traffic shift itself is executed.

**IAM, kept simple:** CodePipeline, CodeBuild, and CodeDeploy each get their own scoped service role — standard AWS-native roles, no OIDC federation needed since everything runs inside AWS already (that concern is specific to letting an external CI system like GitHub Actions assume an AWS role, which doesn't apply here).

## Frontend (kept simple — not the focus of this project)

Static site (plain HTML/JS or a lightweight framework — your choice) hosted on S3 + CloudFront, served from the Route 53 subdomain. Screens needed:

1. **Rooms list / homepage** — organizer's list of their rooms with live status, "+ New room" button.
2. **Create room form** — event name, protected URL, starting admission rate.
3. **Room dashboard** — live stats (waiting, admitted, rate, avg wait) + a way to adjust the target rate.
4. **Visitor waiting screen** — shows position number and estimated wait, auto-polls status every few seconds.
5. **Admitted screen** — "You're in! Redirecting…", then redirects to the protected URL with the one-time token attached.

## Demo / testing setup

- Build a small, deliberately fragile "protected site" fixture (toggle-able slow/error responses) as a demo prop — this is not one of the three real microservices, it exists purely so the Queue Controller has something real to react to.
- Use **k6** for load testing: a script that ramps from 0 to a few thousand requests over 30–60 seconds against the join endpoint, to demonstrate the queue filling and draining live.

## Explicitly out of scope (do not build these)

- No GitHub Actions — not permitted in this environment. AWS CodePipeline handles application deployment instead; Terraform changes are applied manually.
- No SQS, EventBridge, or any message queue in the core system — nothing here needs to react to a background event asynchronously. (Only becomes relevant if a real-time push "Notifier" stretch feature is added later.)
- No Secrets Manager — nothing in this system is sensitive enough to justify it (use SSM Parameter Store only if something genuinely needs it).
- No GSIs on the DynamoDB table.
- No custom subdomains for the ALB or API Gateway — see the DNS section above for why.
- No actual ticket purchasing, payment, or checkout logic — this system only manages the queue and redirects to an external, separately-owned protected site.
- No sharded counters — see the DynamoDB section above.

## What to build first

1. Terraform backend (S3 state + locking), applied manually. No pipeline bootstrap needed here — just get a clean `terraform init` / `apply` working from your own machine.
2. VPC, endpoints, ECR, Route 53 data source + ACM certificate, and a working CodeDeploy blue/green "hello world" deploy — then wire up the CodePipeline (source → build → deploy) around that same hello-world service, so the full automated release path is proven before any real service code exists.
3. DynamoDB table with the schema above.
4. Admission API (join / status / token endpoints).
5. Queue Controller (health polling + AIMD loop).
6. Room Admin API (Lambda + API Gateway).
7. **Protected-site fixture + k6 load test script** — moved ahead of the frontend (see build-order swap below).
8. Frontend screens, wired up to the real endpoints, served from the subdomain.

*(Original order had the frontend before the fixture — swapped 2026-08-23, see below.)*

## Implementation log (updated as we build — read this before assuming this doc alone is current)

Repo: `feature/waiting-room-babar` on the shared org repo `awabamjad1/internship-program-2026` (root of that branch, not a subfolder — matches every other intern's branch). Commit at each meaningful checkpoint, short plain commit messages (max ~3 lines, no em dashes). Never touch `main` or any other branch.

### Status as of 2026-08-23

- **Done, deployed, verified:** Terraform backend, VPC/networking, DynamoDB table, Admission API, Queue Controller, Room Admin API, hello-world proof (built then decommissioned — see `infra/reference/hello-world-blue-green/`), protected-site fixture + demo-control tooling (mid-verification as this note was written).
- **Not started:** CodePipeline (source→build→deploy automation — the hello-world proof only proved the CodeDeploy mechanism, not the pipeline around it), Route 53/ACM/CloudFront, real frontend, k6 load test.
- **Build order swap (2026-08-23):** protected-site fixture moved ahead of the frontend. Reasoning: the fixture is what makes the Queue Controller's AIMD loop demonstrable (reacting to a real struggling site) — judged the most interesting, provable part of the system. The frontend is presentation; if time runs short, a working control-loop demo matters more than polished screens with a controller that's only ever seen "assume healthy."

### Terraform layout

`infra/bootstrap/` — S3 state bucket, local state, applied once. `infra/live/` — everything else, one `.tf` file per deployable service (`admission_api.tf`, `queue_controller.tf`, `room_admin_api.tf`, `protected_site.tf`) plus shared files (`vpc.tf`, `vpc_endpoints.tf`, `security_groups.tf`, `iam.tf` for shared roles only, `dynamodb.tf`, `alb.tf` for just the shared ALB resource, `ecs_cluster.tf`, `hello_world_legacy.tf` for the two kept-as-provenance resources). This per-service-file split was a deliberate mid-project reorg, verified zero-diff via `terraform plan` before adding anything new to it.

### Key infra decisions and why

- **VPC interface endpoints are single-AZ, not one per AZ.** Checked the actual numbers: 3 services × 2 AZs would be ~$43.80/mo — *more* than the NAT Gateway this design exists to avoid (~$32.85/mo). Single-AZ brings it to ~$21.90/mo. Same-VPC traffic reaches an ENI regardless of which AZ it's in (implicit local route), so the only real gap is if that specific AZ has an outage — accepted at this project's scale, documented in `vpc_endpoints.tf`.
- **Protected-site fixture's mode toggle is a DynamoDB item, not SSM Parameter Store**, despite CLAUDE.md mentioning SSM as an option. Found via live testing: the fixture's task runs in a private, NAT-less subnet, and `ssm:GetParameter` had no route out at all — it just hung every request until boto3's timeout, since there was no SSM VPC endpoint. Adding one would have cost ~$7.30/mo. Switched instead to one item in the existing table (`PK=CONFIG#protected-site, SK=MODE`), which reuses the already-free DynamoDB gateway endpoint — $0 marginal cost. Also moved the mode read to a background thread (`apps/protected-site/app.py`, same pattern as the Queue Controller's own AIMD loop) so the request-handling path never does synchronous I/O — a synchronous call there would have polluted the exact `TargetResponseTime` CloudWatch metric the Queue Controller reads, which is the one thing that call path must never do.
- **Port/exposure decisions on the shared ALB security group** (all documented inline in `security_groups.tf`, treat that comment block as the source of truth): `:80` real traffic (must be public). `:8080`/`:8091` (CodeDeploy test listeners for Admission API / Queue Controller) are open to `0.0.0.0/0` — deliberate, because each service's validation Lambda has no VPC config (kept that way on purpose, matches CLAUDE.md's Lambda rationale) and calls out over the public internet from an unpredictable AWS-managed IP, so there's no real CIDR to scope to. Production fix would be VPC-attached Lambdas + a `codedeploy` interface endpoint (~$7.30/mo) — not worth it for a GET-only `/health` check with no data behind it. `:8090` (Queue Controller's prod listener) has **no ingress rule at all** — nothing, not even our own tooling, ever calls it; it exists purely because CodeDeploy's `target_group_pair_info` schema requires a prod route alongside the test route. `:8100` (protected-site fixture) is open to `0.0.0.0/0` for a different reason: it's meant to be hit by `scripts/probe_protected_site.py`, standing in for real visitor traffic until the frontend exists, and that prober can run from anywhere.
- **Queue Controller runs at `desired_count = 1`, deliberately.** Its AIMD rate is control-loop state read/written to each room's `targetRate` every tick; two instances would race and double-adjust. Scaling this out safely needs leader election — out of scope at this project's scale, same spirit as the DynamoDB single-counter tradeoff already in this doc.
- **Room Admin API's `GET /rooms`, `POST /rooms`, and both `/demo/*` routes are unauthenticated on purpose** — no owner/tenant model exists in the schema, so anyone can enumerate rooms or drive the demo fixture. `GET /rooms/{roomId}` and `PATCH /rooms/{roomId}` require the per-room admin-key hash. Documented in `room_admin_api.tf` and `app.py`.
- **hello-world proof was fully decommissioned** once the Admission API replaced it (freed ALB ports 80/8080) — its Terraform is frozen as reference in `infra/reference/hello-world-blue-green/`, not live. Its ECR repo and one CloudWatch log group were deliberately left running (negligible cost, useful provenance); everything deployable (ECS service/task-def, CodeDeploy app/group, target groups, listeners, validation Lambda) was torn down.
- **`scripts/deploy.py`** (ECS/CodeDeploy services) and **`scripts/deploy_lambda.py`** (Lambda/CodeDeploy services) are both generic — they read a `service` argument, look up that service's Terraform output object, and need no edits when a new service is added. `scripts/deploy_protected_site.py` is separate and simpler: the fixture uses plain rolling ECS deployment, not CodeDeploy, since blue/green was already proven three times over on the real services and this is a demo prop, not a fourth example.
- **`admittedCount` is capped at `nextNumber` in the Queue Controller — a real correctness bug, found and fixed 2026-08-23.** The original implementation unconditionally `ADD`ed the decided rate to `admittedCount` every tick, even with an empty queue (nobody having joined). Left running idle, that counter drifts arbitrarily far ahead of `nextNumber` with no ceiling; any burst of real visitors arriving afterward lands under that inflated number and gets admitted instantly, with zero throttling — the exact scenario this whole system exists to prevent. Fixed by computing `min(admittedCount + rate, nextNumber)` from the room snapshot `scan_rooms()` already read that tick, then a plain `SET` (not the atomic `ADD` CLAUDE.md's DynamoDB section describes) for `admittedCount` specifically. Deliberate, not an oversight: nothing else ever writes `admittedCount` (Admission API only reads it) and the Queue Controller runs as exactly one instance (see the `desired_count=1` note above), so there's no concurrent writer for this field to race against — the single-writer assumption that already justified `desired_count=1` covers this too. Verified live: reset a room, left it idle ~4.5 minutes with nobody joining — `admittedCount` held at 0 the whole time while `targetRate` kept climbing normally (3595→3875, unaffected by this fix). A single visitor joining after that idle period got a real `waiting` status, not instant admission. A burst of 30 concurrent joins right after all showed `waiting` (0 admitted) when checked ~3s later, then were admitted a few seconds after that via a real controller tick, with `admittedCount` landing at exactly `31` (matching `nextNumber`, not the multi-thousand `targetRate`).

### Demo tooling (`scripts/`, all read `terraform output -json` from `infra/live` — run from the repo root with AWS credentials active)

- `toggle_protected_site.py {healthy|slow|error}` — flips the fixture's mode via the Room Admin API's `POST /demo/mode` (not a direct AWS call — one code path for "how the mode changes", shared with the demo-control page). Takes effect within ~5s, no redeploy.
- `probe_protected_site.py [--rate N] [--duration S]` — sends continuous real GET requests to the fixture, logging each one's status/latency. Necessary, not optional: CloudWatch's `TargetResponseTime`/`HTTPCode_Target_5XX_Count` only populate from real routed requests, not from the ALB's own health checks, so without this the Queue Controller has nothing to react to.
- `watch_room_rate.py <roomId> [--interval S] [--duration S]` — polls a room's `targetRate`/`admittedCount` from DynamoDB at a fixed interval, timestamped — a time series for watching the controller react, not a before/after snapshot.
- `demo_sequence.py [--baseline S] [--hold S] [--recover S] [--bad-mode slow|error]` — scripted healthy→bad→healthy sequence with exact toggle timestamps logged, meant to run alongside the two scripts above.
- `reset_demo_room.py <roomId>` — zeroes `nextNumber`/`admittedCount` for one specific room, by id, via direct DynamoDB access. `targetRate` is left alone deliberately (the Queue Controller owns it and will readjust it regardless). Run this close to the actual "visitor joins" demo beat, not minutes/hours ahead — `admittedCount` climbs the whole time the room sits idle-but-healthy (see the cap-fix note above; the cap stops it from exceeding `nextNumber`, but doesn't stop `nextNumber` itself from needing a fresh reset before a demo).
- `apps/demo-control/index.html` — standalone page, NOT part of the real product UI, not linked from the organizer dashboard. Open directly as a local file (`file://`), paste the Room Admin API endpoint once (saved in that browser's `localStorage`). Buttons to flip the mode, a "Reset room" button (calls the Room Admin API's `POST /demo/reset` — the same effect as `reset_demo_room.py`, but scoped to whichever room `/demo/status` is currently tracking, no roomId to type), live view of the demo room's `targetRate`/`waiting`/`admittedCount`, polls every 2s.