// k6 load-test scenarios against the app's /api/simulate endpoint, which
// answers with the latency and error rate each request asks for. Run by
// .github/workflows/load-test.yml and, after every deploy, deploy.yml (smoke);
// locally:
//
//   k6 run -e SCENARIO=smoke -e LOAD_TEST_TOKEN=... loadtest/scenarios.js
//
// Each stage tells a story on the Grafana dashboard:
//   smoke   1 min   low, healthy traffic: a baseline and a check that it all works
//   ramp    10 min  traffic climbs to 60 req/s while the app slows past 1 s:
//                   fires AppSlowResponses and burns the SLO's latency budget
//   spike   10 min  a 6-minute burst of 100 req/s with 10% errors: fires
//                   AppHighErrorRate and both SLO burn-rate alerts
//   soak    30 min  steady 15 req/s with 1% errors, to watch everything settle
//   burnin  ~1 h    all four in order, with 3 quiet minutes between them so
//                   each recovery is visible too
//   art     ~50 min paints ART (default starry-night, or any short text) on the "Latency
//                   distribution" heatmap (see art.js)
import exec from "k6/execution";
import http from "k6/http";
import { check, sleep } from "k6";
import { artGrid, COLUMN_SECONDS, preview, RATE_PER_PIXEL, ROW_LATENCY_MS } from "./art.js";

const BASE_URL = __ENV.BASE_URL || "https://portfolio.geoffgilchrist.com";
const SCENARIO = __ENV.SCENARIO || "smoke";
const SOAK_MINUTES = Number(__ENV.SOAK_MINUTES || 30);
const GAP_SECONDS = 180;

// Each stage: its k6 scenarios (start times relative to the stage) and length.
const STAGES = {
  smoke: {
    seconds: 60,
    scenarios: {
      smoke: { executor: "constant-arrival-rate", rate: 2, timeUnit: "1s", duration: "1m",
               preAllocatedVUs: 5, exec: "healthy" },
    },
  },
  ramp: {
    seconds: 600,
    scenarios: {
      ramp: { executor: "ramping-arrival-rate", startRate: 1, timeUnit: "1s",
              preAllocatedVUs: 40, maxVUs: 200, exec: "degrading",
              stages: [
                { target: 60, duration: "4m" },
                { target: 60, duration: "5m" },
                { target: 0, duration: "1m" },
              ] },
    },
  },
  spike: {
    seconds: 600,
    scenarios: {
      baseline: { executor: "constant-arrival-rate", rate: 5, timeUnit: "1s", duration: "10m",
                  preAllocatedVUs: 10, exec: "healthy" },
      // Longer than the 5 minutes AppHighErrorRate waits before firing.
      burst: { executor: "constant-arrival-rate", rate: 100, timeUnit: "1s", duration: "6m",
               startTime: "60s", preAllocatedVUs: 60, maxVUs: 200, exec: "failing" },
    },
  },
  soak: {
    seconds: SOAK_MINUTES * 60,
    scenarios: {
      soak: { executor: "constant-arrival-rate", rate: 15, timeUnit: "1s",
              duration: `${SOAK_MINUTES}m`, preAllocatedVUs: 20, maxVUs: 60, exec: "steady" },
    },
  },
};

const PROFILES = {
  smoke: ["smoke"],
  ramp: ["ramp"],
  spike: ["spike"],
  soak: ["soak"],
  burnin: ["smoke", "ramp", "spike", "soak"],
  art: [],
};

if (!PROFILES[SCENARIO]) {
  throw new Error(`Unknown SCENARIO "${SCENARIO}"; pick one of ${Object.keys(PROFILES).join(", ")}`);
}

// Lays the stages end to end. Each scenario carries its stage name in STAGE,
// which becomes the request's scenario label, so the dashboard shows which
// stage is running even within one burn-in.
function schedule(stageNames) {
  const scenarios = {};
  let offset = 0;
  for (const name of stageNames) {
    for (const [key, s] of Object.entries(STAGES[name].scenarios)) {
      const start = offset + parseInt(s.startTime || "0", 10);
      scenarios[key] = { ...s, startTime: `${start}s`, env: { STAGE: name } };
    }
    offset += STAGES[name].seconds + GAP_SECONDS;
  }
  return scenarios;
}

// One scenario per heatmap row, each sending that row's latency during the
// minutes its pixels are lit.
const ART = artGrid(__ENV.ART || "starry-night");

function artScenarios() {
  const scenarios = {};
  ROW_LATENCY_MS.forEach((latency, row) => {
    const inFlight = Math.ceil(RATE_PER_PIXEL * (latency / 1000 + 0.5));
    scenarios[`art_row_${String(row).padStart(2, "0")}`] = {
      executor: "constant-arrival-rate", rate: RATE_PER_PIXEL, timeUnit: "1s",
      duration: `${ART[0].length * COLUMN_SECONDS}s`,
      preAllocatedVUs: inFlight + 2, maxVUs: inFlight * 3 + 5,
      exec: "pixel", env: { STAGE: "art", ROW: String(row) },
    };
  });
  return scenarios;
}

// The smoke stage asks for a healthy app, so it's the one with performance
// thresholds (k6 tags every request with its scenario).
const smokeThresholds = PROFILES[SCENARIO].includes("smoke")
  ? { "http_req_duration{scenario:smoke}": ["p(95)<500"], "http_req_failed{scenario:smoke}": ["rate<0.01"] }
  : {};

export const options = {
  scenarios: SCENARIO === "art" ? artScenarios() : schedule(PROFILES[SCENARIO]),
  setupTimeout: "90s", // art waits up to a minute in setup()
  // Every stage must at least reach the endpoint: a wrong token or a stack
  // that's down shows up as failed checks, not as a "passing" run.
  thresholds: { checks: ["rate>0.99"], ...smokeThresholds },
  summaryTrendStats: ["med", "p(95)", "p(99)", "max"],
};

// Fail fast, before any load, if the endpoint doesn't answer.
export function setup() {
  if (SCENARIO === "art") console.log(`Drawing ${ART[0].length} minutes of pixels:\n${preview(ART)}`);
  if (!__ENV.LOAD_TEST_TOKEN) exec.test.abort("LOAD_TEST_TOKEN is not set");
  const res = simulate({});
  if (res.status !== 200) {
    exec.test.abort(`${BASE_URL}/api/simulate answered ${res.status}: wrong token, or the stack is down`);
  }
  // Heatmap columns end on whole minutes, so start drawing on one; otherwise
  // every pixel would straddle two columns.
  if (SCENARIO === "art") sleep(COLUMN_SECONDS - ((Date.now() / 1000) % COLUMN_SECONDS));
}

function simulate(params) {
  const query = Object.entries(params).map(([k, v]) => `${k}=${v}`).join("&");
  return http.get(`${BASE_URL}/api/simulate?${query}`, {
    headers: {
      "X-Load-Test-Token": __ENV.LOAD_TEST_TOKEN,
      "X-Load-Test-Scenario": __ENV.STAGE || SCENARIO,
    },
    tags: { name: "simulate" }, // one k6 metric series, whatever the query string
  });
}

// 200 is a normal answer, 500 a failure the request asked for. Anything else
// (404 for a bad token, 502/503 from the load balancer) is a real problem.
function answered(res) {
  check(res, { "answered as asked": (r) => r.status === 200 || r.status === 500 });
}

export function healthy() {
  answered(simulate({ latency_ms: 40, jitter_ms: 20 }));
}

// Latency climbs from 40 ms past 1 s halfway through, then holds at 1.5 s.
export function degrading() {
  const latency = Math.min(1500, Math.round(40 + 2000 * exec.scenario.progress));
  answered(simulate({ latency_ms: latency, jitter_ms: 100 }));
}

export function failing() {
  answered(simulate({ latency_ms: 300, jitter_ms: 200, error_rate: 0.1 }));
}

export function steady() {
  answered(simulate({ latency_ms: 120, jitter_ms: 60, error_rate: 0.01 }));
}

export function pixel() {
  const row = Number(__ENV.ROW);
  const latency = ROW_LATENCY_MS[row];
  // A request is counted when it finishes, so pick the column it will
  // finish in. Otherwise the slow rows would spill into the next minute.
  const finishesAt = Date.now() + latency + 50 - exec.scenario.startTime;
  const level = ART[row][Math.floor(finishesAt / (COLUMN_SECONDS * 1000))] || 0;
  // Brightness: of every RATE_PER_PIXEL iterations, send `level`.
  if (exec.scenario.iterationInTest % RATE_PER_PIXEL >= level) return;
  answered(simulate({ latency_ms: latency }));
}

// A short Markdown report for the GitHub Actions job summary.
export function handleSummary(data) {
  const m = data.metrics;
  const ms = (v) => (v === undefined ? "-" : `${Math.round(v)} ms`);
  const pct = (v) => (v === undefined ? "-" : `${(v * 100).toFixed(2)}%`);
  const failed = Object.entries(data.metrics)
    .filter(([, metric]) => metric.thresholds)
    .flatMap(([name, metric]) =>
      Object.entries(metric.thresholds).filter(([, t]) => !t.ok).map(([expr]) => `${name} ${expr}`));
  const md = [
    `### k6 load test: ${SCENARIO}`,
    "",
    "| Requests | Rate | Median | p95 | p99 | Max | 5xx and failures | Checks passed |",
    "|---|---|---|---|---|---|---|---|",
    `| ${m.http_reqs.values.count} | ${m.http_reqs.values.rate.toFixed(1)}/s ` +
      `| ${ms(m.http_req_duration.values.med)} | ${ms(m.http_req_duration.values["p(95)"])} ` +
      `| ${ms(m.http_req_duration.values["p(99)"])} | ${ms(m.http_req_duration.values.max)} ` +
      `| ${pct(m.http_req_failed.values.rate)} | ${pct(m.checks?.values.rate)} |`,
    "",
    failed.length ? `**Thresholds failed:** ${failed.join(", ")}` : "All thresholds passed.",
    "",
  ].join("\n");
  return { stdout: `${md}\n`, "summary.md": md };
}
