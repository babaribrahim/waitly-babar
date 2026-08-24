// Fast backlog seeder for a pre-demo waiting-state setup - see
// scripts/prime_demo_queue.py and scripts/trickle_join.py's docstrings
// for why a Python urllib/ThreadPoolExecutor seeder couldn't outrun the
// Queue Controller's compounding AIMD rate: isolated testing showed
// urllib paying ~600-700ms/call with no connection reuse, and under
// concurrency that degraded to an average of 6.8s/call (max 23.5s) -
// almost certainly per-connection setup overhead and thread/GIL
// contention on the client side, not the Admission API or DynamoDB.
// scripts/k6_join_load_test.js already proved the API sustains 60 req/s
// for 45s with 0% failures and a max latency of 6.76s under that FULL
// sustained load - well within what's needed here.
//
// Unlike k6_join_load_test.js's 45s ramp (built to visualize a gradual
// fill), this fires a short, flat burst at a high constant rate and
// stops - the goal is building a large backlog in as few controller
// ticks (5s each) as possible, then getting out of the way so it drains
// visibly afterward instead of draining during seeding.
//
// Usage:
//   k6 run -e API_BASE=http://<alb-dns> -e ROOM_ID=<roomId> scripts/k6_seed_backlog.js

import http from "k6/http";
import { check } from "k6";

const API_BASE = (__ENV.API_BASE || "").replace(/\/$/, "");
const ROOM_ID = __ENV.ROOM_ID;
const RATE = Number(__ENV.RATE || 60);       // req/s, proven sustainable
const DURATION_S = Number(__ENV.DURATION_S || 6); // ~1-2 controller ticks

if (!API_BASE || !ROOM_ID) {
  throw new Error("Set -e API_BASE=... -e ROOM_ID=... when running this script.");
}

export const options = {
  scenarios: {
    seed_burst: {
      executor: "constant-arrival-rate",
      rate: RATE,
      timeUnit: "1s",
      duration: `${DURATION_S}s`,
      preAllocatedVUs: Math.max(20, RATE),
      maxVUs: Math.max(40, RATE * 2),
    },
  },
  thresholds: {
    http_req_failed: ["rate<0.01"],
  },
};

export default function () {
  const resp = http.post(`${API_BASE}/rooms/${ROOM_ID}/join`);
  check(resp, { "status is 201": (r) => r.status === 201 });
}
