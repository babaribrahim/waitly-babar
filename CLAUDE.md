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
7. Frontend screens, wired up to the real endpoints, served from the subdomain.
8. Protected-site fixture + k6 load test script for the demo.