// Background traffic for a demo session, so the dashboards have something to
// show from the first minutes. Run by the monitoring task (infra/observability.tf)
// against the public URL, through the load balancer like any visitor.
//
// About 3 requests a second to /api/simulate, labeled "ambient": synthetic
// traffic, shown as such on the dashboards and counted in the SLO. Latency
// drifts in a 20-minute wave between about 40 and 140 ms, with a rare error,
// so the graphs, heatmap and traces look like a quiet, healthy service.
//
// It steps aside while a load test runs (any other scenario sending traffic),
// so a test's results and the art scenario's heatmap picture aren't mixed
// with it. Prometheus is in the same task, on localhost.
import http from "k6/http";

const WAVE_SECONDS = 1200;
const CHECK_MS = 15000;
const LOAD_TEST_QUERY = 'sum(rate(load_test_requests_total{scenario!="ambient"}[1m])) > 0';
const PROMETHEUS = `http://127.0.0.1:9090/api/v1/query?query=${encodeURIComponent(LOAD_TEST_QUERY)}`;

export const options = {
  scenarios: {
    ambient: {
      executor: "constant-arrival-rate", rate: 3, timeUnit: "1s",
      duration: "24h", // the task is torn down long before
      preAllocatedVUs: 5, maxVUs: 20,
    },
  },
};

// Each VU asks Prometheus at most every 15 s; a failed check means "no test".
let checkedAt = 0;
let loadTestRunning = false;

function yieldToLoadTest() {
  if (Date.now() - checkedAt >= CHECK_MS) {
    checkedAt = Date.now();
    const res = http.get(PROMETHEUS, { tags: { name: "prometheus" } });
    try {
      loadTestRunning = res.status === 200 && res.json("data.result").length > 0;
    } catch {
      loadTestRunning = false;
    }
  }
  return loadTestRunning;
}

// Requests fail until the load balancer and DNS are ready; k6 just keeps going.
export default function () {
  if (yieldToLoadTest()) return;
  const wave = Math.sin((2 * Math.PI * Date.now()) / 1000 / WAVE_SECONDS);
  const latency = Math.round(90 + 50 * wave);
  http.get(`${__ENV.BASE_URL}/api/simulate?latency_ms=${latency}&jitter_ms=40&error_rate=0.003`, {
    headers: { "X-Load-Test-Token": __ENV.LOAD_TEST_TOKEN, "X-Load-Test-Scenario": "ambient" },
    tags: { name: "simulate" },
  });
}
