# Waitly demo kit

Single reference for presenting the system live. Everything below was run
and verified against the real deployed stack, not simulated. The whole
demo now runs from browser tabs alone - no terminal required for the
core beats (see the CodePipeline section for the one thing that's still
CLI-driven, and why).

## Live endpoints

| What | Value |
|---|---|
| **The site** (frontend, demo-control, Admission API, fixture, Room Admin API - all through here) | `https://waitly.internship.cloudelligent-sandbox.com` |
| Room Admin API (raw, for scripting only) | `https://k2uj9et2rk.execute-api.us-west-2.amazonaws.com` |
| CodePipeline console | `https://us-west-2.console.aws.amazon.com/codesuite/codepipeline/pipelines/waitly-pipeline/view?region=us-west-2` |
| DynamoDB table | `waitly-table` (region `us-west-2`) |
| Demo room ID | `rEcu9I_C` |
| Demo room admin key | `VVqvgcLt0RIC0yijAnrXfdLN-TB5c8ey` |

If any of these change (redeploy, new distribution, etc.), regenerate
from `terraform -chdir=infra/live output -json`.

Everything under the site domain is HTTPS, including the Admission API,
protected-site fixture, and Room Admin API calls - none of these are
reachable at their raw AWS-generated URLs from a browser anymore (mixed
content for the first two; just an inconsistency worth not having for
the third), they're routed through CloudFront's `/rooms/*`, `/fixture/*`,
and `/admin/*` behaviors respectively. The frontend and demo-control
pages have this baked in - no endpoint to paste anywhere anymore, that
field is gone. Only matters if you're scripting directly against the raw
API Gateway URL above.

## Browser tabs you need

No terminals required for the demo itself.

- **Tab 1 — demo-control**: `https://waitly.internship.cloudelligent-sandbox.com/demo-control/`
  Live view of mode, targetRate, waiting, admittedCount, the traffic
  banner, and the two traffic-generator buttons - polls every 2s. No
  setup step - open it and go.

- **Tab 2 — visitor waiting screen**: opened fresh right before each
  demo beat that needs it, see below. It joins the instant it loads -
  don't open it early.
  `https://waitly.internship.cloudelligent-sandbox.com/join.html?room=rEcu9I_C`

- **Tab 3 — organizer flow** (for the live room-creation beat only):
  `https://waitly.internship.cloudelligent-sandbox.com/`

## Demo A — a visitor actually sees a waiting state

1. **Terminal** (this one step still needs it - see the note below):
   ```
   python scripts/prime_demo_queue.py rEcu9I_C --rate 2
   ```
2. **Tab 1 (demo-control)** — click **Seed backlog**. Fires ~200 real
   concurrent joins client-side (browser `fetch`/`Promise.all`, not a
   script) into whichever room demo-control is tracking. Takes a few
   seconds; the button shows "Seeded 200/200" when done.
3. **Open Tab 2** (the visitor URL above) within the next **~30-45
   seconds** - that's the tested margin. It lands at a real position
   deep in the queue.
4. Watch it count down live over several real controller ticks. No
   further action needed.

**Why step 1 still needs a terminal:** it does a direct DynamoDB write
(reset + pin the rate) - deliberately bypassing the Room Admin API's
admin-key check for speed, matching how `scripts/reset_demo_room.py`
already worked. Could be wired as a button too if there's time
tomorrow morning; wasn't the priority given everything else this
session. Everything after it is a browser click.

**Shelf life:** steps 1 and 2 should run back to back - step 1 is the
only place idle time costs you anything (the rate starts compounding
the instant it's healthy). Step 3's ~30-45s window is the tested
margin from live runs; after that the backlog fully drains and you'd
restart from step 1.

## Demo B — break and recover (AIMD reacting to real health)

Entirely browser-driven now.

1. **Tab 1 (demo-control)** — click **Start prober**. Runs a client-side
   `setInterval` sending a real request to the fixture every ~300ms
   (`mode: "no-cors"` - it doesn't need to read the response, just
   generate real traffic CloudWatch can see). Runs until you click Stop;
   it does not stop itself.
2. Wait until the traffic banner turns green (confirms real traffic is
   flowing - usually within a few seconds).
3. Click **Erroring**.
4. **Watch demo-control's targetRate.** Expected timing, from real runs
   this session: **~80-90 seconds** from the click until it visibly
   starts dropping (CloudWatch needs real routed error requests to
   accumulate in its 60s window). Once it starts, it halves every 5s
   tick - fast and obvious.
5. Click **Healthy**.
6. **Watch targetRate climb again.** Expected timing: **~20-35 seconds**
   - visibly slower than the halving in step 4 (additive vs.
   multiplicative, on purpose - see CLAUDE.md).
7. Click **Stop prober** when you're done. Nothing else reacts to the
   fixture's mode without real traffic hitting it.

**Why the asymmetric timing:** breaking needs real error requests to
accumulate in a 60s trailing CloudWatch window before the controller
even sees a problem. Recovering only needs that same window to finish
draining the old errors out, which is often already partway done by
the time you flip back. If asked live: this is the same reason a real
CDN/waiting-room health check can't react instantaneously - it's
reading aggregated metrics, not synchronous request outcomes.

## Demo C (optional/bonus) — full k6 fill-and-drain burst

The one part that's still genuinely a terminal script - a scripted 45s
ramp (0→60 req/s) is a different kind of demonstration than a single
click, and worth keeping as a distinct "under real sustained load"
close if there's time.

1. Create a fresh low-rate room (Tab 3's "+ New room", or via curl):
   ```
   curl -s -X POST https://k2uj9et2rk.execute-api.us-west-2.amazonaws.com/rooms \
     -H "Content-Type: application/json" \
     -d '{"name":"k6 Demo","protectedUrl":"https://waitly.internship.cloudelligent-sandbox.com/fixture/","targetRate":20}'
   ```
2. Run the ramp:
   ```
   k6 run -e API_BASE=https://waitly.internship.cloudelligent-sandbox.com -e ROOM_ID=<roomId> scripts/k6_join_load_test.js
   ```
3. Watch demo-control (it auto-follows the most-recently-created room)
   for the ~45s ramp, then keep watching - the queue keeps draining
   visibly for another 30-60s after.

Real numbers from the last verified run: 1,757 real joins, 0% failures,
p95 latency 2.88s (DynamoDB single-counter contention under load - a
documented, deliberate tradeoff, see CLAUDE.md, not a bug worth
explaining unless asked).

## Organizer flow — creating a room live

Safe to do live: room creation is fast and reliable (verified all
session - a plain write, sub-second). The risk isn't creation, it's
everything *downstream* of it needing the same reset+seed sequence
before a visitor demo means anything. So:

- **Show room creation live** on Tab 3 (`/` → "+ New room" → fill in
  name/rate, and for **Protected URL use exactly**
  `https://waitly.internship.cloudelligent-sandbox.com/fixture/`
  (trailing slash matters) → real room, real admin key, real
  `publicLink` shown - this was broken until today, see the bugfix
  note below. Don't guess at this field live: only `/fixture/*` has a
  CloudFront behavior routing to the ALB - anything else (`/protected/`
  included - tried it live, got an S3 AccessDenied XML page) falls
  through to the default behavior, which is the S3 frontend origin,
  not the fixture.
- **Do the actual "visitor waits and drains" beat on the pre-prepared
  `rEcu9I_C`**, not the room you just created live. Best of both: a
  genuine live creation, zero timing risk on the part that needs
  precision.

## CodePipeline

One pipeline (`waitly-pipeline`), covering all three services - Source
→ Build → Deploy per service, 7 stages total. Console link at the top
of this doc; console history shows a fully successful run across all
three services (Admission API, Queue Controller, Room Admin API), one
stage retry visible in that run's timeline (a real IAM permission gap
found and fixed live - see below), which is a realistic thing to show,
not something to hide.

**Watches `feature/waiting-room-babar`** on a personal mirror repo
(`babaribrahim/waitly-babar`), not the shared team repo directly - the
shared repo is private and owned by a different intern's account;
GitHub App repo-access grants are controlled by the repo owner, not
collaborators, so no connection available in this AWS account could be
pointed at it without that owner's own action. Mirroring to a repo
Ibrahim owns sidesteps that entirely. Both remotes get pushed on every
checkpoint (`git push origin ...` and `git push personal ...`).

**Build-side skip only, deploy always runs** - each service's CodeBuild
buildspec hashes its own `apps/<service>/` directory and skips the
docker build/push (or Lambda publish) when nothing changed since the
last successful build, storing the marker in SSM Parameter Store. The
Deploy stage runs every execution regardless - Terraform's AWS provider
doesn't yet expose CodePipeline V2's native stage-skip condition
(open feature requests: hashicorp/terraform-provider-aws#40454, #39284),
and implementing it via raw API calls layered on top of Terraform would
mean part of the pipeline living outside Terraform state. Documented,
deliberate gap - same treatment as the DynamoDB single-counter
tradeoff in CLAUDE.md.

**Two real bugs found and fixed getting this pipeline green:**
- CodeBuild's Docker Hub pulls hit anonymous rate-limiting (`429 Too
  Many Requests`) - CodeBuild's egress IPs are shared across many AWS
  customers. Fixed by switching all three Dockerfiles to the ECR
  Public Gallery mirror (`public.ecr.aws/docker/library/python:...`),
  which isn't subject to Docker Hub's throttling.
- The Room Admin API's CodeDeploy service role lacked S3 read
  permission on the pipeline's artifact bucket. Never surfaced before
  because `scripts/deploy_lambda.py` always passes its AppSpec inline
  (`AppSpecContent`); CodePipeline's CodeDeploy action is different -
  it hands CodeDeploy an S3-based revision, which is the first time
  that code path actually ran. Fixed with a scoped inline policy on
  `codedeploy_lambda`.

**To run it again**: `aws codepipeline start-pipeline-execution
--name waitly-pipeline --region us-west-2`, or push to either remote
above (webhook-triggered - though worth noting this session's testing
found pushes didn't reliably auto-trigger a new execution; manual
`start-pipeline-execution` is the dependable path if that matters live).

## If something looks wrong mid-demo

- **demo-control shows a different room than the one you're demoing**:
  it always follows whichever room was created most recently - if you
  ran Demo C or the organizer flow after Demo A/B, it's now tracking
  that new room, not `rEcu9I_C`. Expected, not a bug.
- **Visitor page says "This room does not exist"**: almost always a
  transcription slip on the room ID, not a backend issue (verified this
  live - both services agree on room existence). Click through rather
  than retyping; `I` and `l`/`i` are easy to mistake by hand.
- **Nothing happens after toggling "Erroring"**: check demo-control's
  traffic banner. If it's red, the prober isn't running - click
  **Start prober** first.
- **A CloudFront page 403s or looks stale right after a Terraform
  apply**: the distribution can take a few minutes to finish
  propagating; `aws cloudfront get-distribution --id E1BGMNPYBES8IT
  --query Distribution.Status` should read `Deployed`. An explicit
  `aws cloudfront create-invalidation --distribution-id E1BGMNPYBES8IT
  --paths "/*"` clears anything stuck.
- **Nothing responds at all - join/status/mode calls all fail**: check
  the ECS services are actually running, don't assume they are:
  `aws ecs describe-services --cluster waitly-cluster --services
  waitly-admission-api waitly-queue-controller waitly-protected-site
  --region us-west-2 --query "services[].[serviceName,desiredCount,
  runningCount]"`. Happened for real on 2026-08-25: another intern
  (`mkashif`, confirmed via CloudTrail) manually scaled all three to 0
  in a shared-account cleanup, unrelated to this project - a one-off
  manual action, not a scheduled policy, so it won't recur on a timer,
  but it *could* happen again if someone does another sweep without
  knowing these are live for a demo. If it happens again: `terraform
  -chdir=infra/live apply` restores the declared desired_count (2/1/1)
  for all three, then `aws ecs wait services-stable ...` before
  trusting anything works.
