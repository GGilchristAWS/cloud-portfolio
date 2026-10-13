// k6 load-test scenarios against the app's /api/simulate endpoint, which
// answers with the latency and error rate each request asks for. Run by
// .github/workflows/load-test.yml; locally:
//
//   k6 run -e SCENARIO=smoke -e LOAD_TEST_TOKEN=... loadtest/scenarios.js
//
// Each scenario tells a story on the Grafana dashboard:
//   smoke  low, healthy traffic: a baseline, and a check that everything works
//   ramp   traffic climbs while the app slows down, so p95 and CPU rise with it
//   spike  a burst of slow, failing requests that fires the error-rate and
//          fast-burn SLO alerts
//   soak   steady moderate traffic for a long run, to watch for drift
import exec from "k6/execution";
import http from "k6/http";
import { check } from "k6";

const BASE_URL = __ENV.BASE_URL || "https://portfolio.geoffgilchrist.com";
const SCENARIO = __ENV.SCENARIO || "smoke";
const SOAK_MINUTES = Number(__ENV.SOAK_MINUTES || 30);

const PROFILES = {
  smoke: {
    scenarios: {
      smoke: { executor: "constant-arrival-rate", rate: 2, timeUnit: "1s", duration: "1m",
               preAllocatedVUs: 5, exec: "healthy" },
    },
    // The only scenario with performance thresholds: it asks for a healthy app.
    thresholds: { http_req_duration: ["p(95)<500"], http_req_failed: ["rate<0.01"] },
  },
  ramp: {
    scenarios: {
      ramp: { executor: "ramping-arrival-rate", startRate: 1, timeUnit: "1s",
              preAllocatedVUs: 20, maxVUs: 100, exec: "degrading",
              stages: [
                { target: 40, duration: "5m" },
                { target: 40, duration: "2m" },
                { target: 0, duration: "1m" },
              ] },
    },
  },
  spike: {
    scenarios: {
      baseline: { executor: "constant-arrival-rate", rate: 5, timeUnit: "1s", duration: "5m",
                  preAllocatedVUs: 10, exec: "healthy" },
      burst: { executor: "constant-arrival-rate", rate: 60, timeUnit: "1s", duration: "2m",
               startTime: "1m", preAllocatedVUs: 40, maxVUs: 120, exec: "failing" },
    },
  },
  soak: {
    scenarios: {
      soak: { executor: "constant-arrival-rate", rate: 10, timeUnit: "1s",
              duration: `${SOAK_MINUTES}m`, preAllocatedVUs: 20, maxVUs: 50, exec: "steady" },
    },
  },
};

if (!PROFILES[SCENARIO]) {
  throw new Error(`Unknown SCENARIO "${SCENARIO}"; pick one of ${Object.keys(PROFILES).join(", ")}`);
}

export const options = {
  scenarios: PROFILES[SCENARIO].scenarios,
  // Every scenario must at least reach the endpoint: a wrong token or a
  // stack that's down shows up as failed checks, not as a "passing" run.
  thresholds: { checks: ["rate>0.99"], ...PROFILES[SCENARIO].thresholds },
  summaryTrendStats: ["med", "p(95)", "p(99)", "max"],
};

// Fail fast, before any load, if the endpoint doesn't answer.
export function setup() {
  if (!__ENV.LOAD_TEST_TOKEN) exec.test.abort("LOAD_TEST_TOKEN is not set");
  const res = simulate({});
  if (res.status !== 200) {
    exec.test.abort(`${BASE_URL}/api/simulate answered ${res.status}: wrong token, or the stack is down`);
  }
}

function simulate(params) {
  const query = Object.entries(params).map(([k, v]) => `${k}=${v}`).join("&");
  return http.get(`${BASE_URL}/api/simulate?${query}`, {
    headers: { "X-Load-Test-Token": __ENV.LOAD_TEST_TOKEN, "X-Load-Test-Scenario": SCENARIO },
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

// Latency grows from 40 ms to 400 ms over the run, crossing the SLO's 250 ms.
export function degrading() {
  const latency = Math.round(40 + 360 * exec.scenario.progress);
  answered(simulate({ latency_ms: latency, jitter_ms: 30 }));
}

export function failing() {
  answered(simulate({ latency_ms: 300, jitter_ms: 200, error_rate: 0.1 }));
}

export function steady() {
  answered(simulate({ latency_ms: 120, jitter_ms: 60, error_rate: 0.01 }));
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
