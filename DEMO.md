# Waitly demo kit

Single reference for presenting the system live. Everything below was run
and verified against the real deployed stack, not simulated.

## Live endpoints

| What | Value |
|---|---|
| Admission API (ALB) | `http://waitly-hw-alb-1872850869.us-west-2.elb.amazonaws.com` |
| Room Admin API | `https://k2uj9et2rk.execute-api.us-west-2.amazonaws.com` |
| Protected-site fixture | `http://waitly-hw-alb-1872850869.us-west-2.elb.amazonaws.com:8100/` |
| DynamoDB table | `waitly-table` (region `us-west-2`) |
| Demo room ID | `rEcu9I_C` |
| Demo room admin key | `VVqvgcLt0RIC0yijAnrXfdLN-TB5c8ey` |

If any of these ever change (redeploy, new ALB, etc.), regenerate from
`terraform -chdir=infra/live output -json`.

## Terminals and tabs you need

Set all of this up before anyone's watching.

- **Terminal 1 — frontend server** (stays running the whole time):
  ```
  cd apps/frontend
  python -m http.server 8010
  ```
- **Terminal 2 — protected-site prober** (only needed while running the
  break/recover demo below; stays running for that section, Ctrl+C after):
  ```
  python scripts/probe_protected_site.py --rate 3
  ```
- **Terminal 3 — command terminal** (everything else: toggling mode,
  resetting the room, running k6). Run from the repo root.

- **Browser tab 1 — demo-control** (aggregate live view: mode, targetRate,
  waiting, admittedCount, polls every 2s):
  ```
  file:///c:/Users/it/OneDrive/Desktop/waitingroom/apps/demo-control/index.html
  ```
  If the API field is empty, paste `https://k2uj9et2rk.execute-api.us-west-2.amazonaws.com` and click Save.

- **Browser tab 2 — visitor waiting screen** (opened fresh right before
  each demo beat that needs it, see below):
  ```
  http://localhost:8010/join.html?room=rEcu9I_C
  ```
  It joins the instant it loads - don't open it early, or you'll join
  before the setup for whichever demo beat you're running is ready.

## Demo A — a visitor actually sees a waiting state

Shows a real visitor landing mid-queue and counting down to admission,
instead of instant admission.

1. **Terminal 3** — reset the room and pin the rate low:
   ```
   python scripts/prime_demo_queue.py rEcu9I_C --rate 2
   ```
2. **Terminal 3** — fire the seed burst (takes ~8s, builds a backlog in
   the low hundreds, 0% failures):
   ```
   k6 run -e API_BASE=http://waitly-hw-alb-1872850869.us-west-2.elb.amazonaws.com -e ROOM_ID=rEcu9I_C -e RATE=60 -e DURATION_S=6 scripts/k6_seed_backlog.js
   ```
3. **Open browser tab 2** (the visitor URL above) any time in the next
   **~30-45 seconds** — that's the tested margin, plenty of room to
   alt-tab or share your screen. It lands at a real position deep in the
   queue.
4. Watch it count down live over several real controller ticks (every
   5s). No further action needed.

**Shelf life:** steps 1 and 2 should run back to back with no pause
between them - step 1 is the only place idle time costs you anything
(the rate starts compounding again the instant it's healthy). Steps 2
onward are the tested ~30-45s window above; after that the backlog fully
drains on its own and you'd need to re-run from step 1.

If you want to re-run this beat a second time, just start again from
step 1 - it's fully idempotent.

## Demo B — break and recover (AIMD reacting to real health)

Shows the Queue Controller cutting the admission rate on real errors,
then recovering, driven by actual CloudWatch metrics, not a scripted
value.

**First**, get a visible starting rate: run Demo A's step 1 only
(`prime_demo_queue.py rEcu9I_C --rate 2`), then let it sit in **Terminal
1's tab (demo-control)** for 20-30s so `targetRate` climbs to something
worth watching (it climbs +5 every 5s tick automatically). No need to
seed a backlog for this demo - it's about the aggregate rate on
demo-control, not one visitor's position.

1. **Terminal 2** — start the prober if it isn't already running:
   ```
   python scripts/probe_protected_site.py --rate 3
   ```
2. **Terminal 3** — break it:
   ```
   python scripts/toggle_protected_site.py error
   ```
3. **Watch demo-control.** Expected timing, from real runs this session:
   **~80-90 seconds** from the toggle until `targetRate` visibly starts
   dropping (CloudWatch needs real routed error requests to accumulate -
   nothing shows up from the toggle alone, the prober in Terminal 2 has
   to actually be hitting it). Once it starts, it halves on every 5s
   tick - fast and visually obvious.
4. **Terminal 3** — recover it:
   ```
   python scripts/toggle_protected_site.py healthy
   ```
5. **Watch demo-control.** Expected timing: **~20-35 seconds** until
   `targetRate` starts climbing again (+5/tick, additive - visibly
   slower than the halving in step 3, which is the point: AIMD is
   asymmetric on purpose, see CLAUDE.md).
6. **Terminal 2** — Ctrl+C the prober once you're done; the fixture and
   controller are otherwise idle without it (CloudWatch has nothing to
   read from ALB health checks alone).

**Why the asymmetric timing:** breaking needs real error requests to
build up in a 60s trailing CloudWatch window before the controller even
sees a problem (~80-90s total). Recovering only needs that same window
to finish draining the old errors out, which is often already partway
done by the time you flip back (~20-35s). If asked live: this is the
same reason a real CDN/waiting-room health check can't react
instantaneously - it's reading aggregated metrics, not synchronous
request outcomes.

## Demo C (optional/bonus) — full k6 fill-and-drain burst

A longer, scripted ramp (0 to 60 req/s over 45s) against a **fresh**
room, showing the queue filling under sustained load and draining
afterward with real numbers, not a single visitor. Good as a "here's what
it looks like under real traffic" close if there's time.

1. **Terminal 3** — create a fresh low-rate room (reuse the Room Admin
   API directly, since you want a clean nextNumber=0 room dedicated to
   this run, separate from `rEcu9I_C`):
   ```
   curl -s -X POST https://k2uj9et2rk.execute-api.us-west-2.amazonaws.com/rooms \
     -H "Content-Type: application/json" \
     -d '{"name":"k6 Demo","protectedUrl":"http://waitly-hw-alb-1872850869.us-west-2.elb.amazonaws.com:8100/","targetRate":20}'
   ```
   Note the `roomId` it returns - use it below in place of `<roomId>`.
2. **Terminal 3** — run the full ramp:
   ```
   k6 run -e API_BASE=http://waitly-hw-alb-1872850869.us-west-2.elb.amazonaws.com -e ROOM_ID=<roomId> scripts/k6_join_load_test.js
   ```
3. Watch demo-control (it auto-follows the most-recently-created room)
   for the full ~45s ramp, then continue watching a bit after it ends -
   the queue keeps visibly draining for another 30-60s.

Real numbers from the last verified run: 1,757 real joins, 0% failures,
p95 latency 2.88s (DynamoDB single-counter contention under load - a
documented, deliberate tradeoff, see CLAUDE.md, not a bug worth
explaining unless asked).

## If something looks wrong mid-demo

- **`k6` not found** in a fresh terminal: use the full path,
  `"/c/Program Files/k6/k6.exe"`, or open a new terminal so PATH picks up
  the winget install.
- **demo-control shows a different room than the one you're demoing**:
  it always follows whichever room was created most recently - if you
  ran Demo C after Demo A/B, it's now tracking that new room, not
  `rEcu9I_C`. Expected, not a bug.
- **Visitor page says "This room does not exist"**: almost always a
  transcription slip on the room ID, not a backend issue (verified this
  live - both services agree on room existence, checked directly against
  DynamoDB and the Admission API). Re-copy the ID rather than retyping
  it; `I` and `l`/`i` are easy to mistake by hand.
- **Nothing happens after toggling "Erroring"**: check demo-control's
  traffic banner. If it's red ("no traffic in the last 60s"), the
  prober (Terminal 2) isn't running - CloudWatch has nothing to react
  to. Start it.
