// k6 load test: ramps from 0 to a few thousand requests over ~45s against
// the Admission API's POST /rooms/{roomId}/join endpoint (CLAUDE.md's
// demo/testing spec). Meant to be watched live alongside
// scripts/watch_room_rate.py or apps/demo-control/index.html so the queue
// visibly fills (join calls outpacing targetRate) then drains (the Queue
// Controller's AIMD loop catching back up) - not just a pass/fail report.
//
// Uses the ramping-arrival-rate executor, not ramping-vus: /join is a fast
// call (tens of ms), so a VU-count ramp would conflate concurrency with
// actual request rate. Arrival-rate lets the ramp state a real req/s
// target directly, which is what "a queue filling" actually means here.
//
// Point this at a room with a LOW starting targetRate first (see
// scripts/reset_demo_room.py's sibling call, or just create a fresh room
// via POST /rooms with a small targetRate) - the existing long-running
// demo room's rate has climbed into the thousands over the session and
// would drain a burst like this in a single 5s controller tick, leaving
// nothing visible to watch fill or drain.
//
// Usage:
//   k6 run -e API_BASE=http://<alb-dns> -e ROOM_ID=<roomId> scripts/k6_join_load_test.js

import http from "k6/http";
import { check } from "k6";

const API_BASE = (__ENV.API_BASE || "").replace(/\/$/, "");
const ROOM_ID = __ENV.ROOM_ID;

if (!API_BASE || !ROOM_ID) {
  throw new Error("Set -e API_BASE=... -e ROOM_ID=... when running this script.");
}

export const options = {
  scenarios: {
    join_burst: {
      executor: "ramping-arrival-rate",
      startRate: 0,
      timeUnit: "1s",
      preAllocatedVUs: 60,
      maxVUs: 150,
      stages: [
        { target: 60, duration: "20s" }, // ramp 0 -> 60 req/s
        { target: 60, duration: "15s" }, // hold at 60 req/s - this is the burst
        { target: 0, duration: "10s" },  // ramp back down
      ],
    },
  },
  thresholds: {
    // A join failing outright (not "waiting", an actual non-2xx) would be
    // a real bug - keep the run loud about that rather than just reporting
    // a pass/fail summary at the end.
    http_req_failed: ["rate<0.01"],
  },
};

export default function () {
  const resp = http.post(`${API_BASE}/rooms/${ROOM_ID}/join`);
  check(resp, {
    "status is 201": (r) => r.status === 201,
    "has visitorNumber": (r) => {
      try {
        return typeof JSON.parse(r.body).visitorNumber === "number";
      } catch {
        return false;
      }
    },
  });
}
