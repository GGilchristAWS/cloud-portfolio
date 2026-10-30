// Background traffic for a demo session, so the dashboards have something to
// show from the first minutes. Run by the monitoring task (infra/observability.tf)
// against the public URL, through the load balancer like any visitor.
//
// About 3 requests a second to /api/simulate, labeled "ambient": synthetic
// traffic, shown as such on the dashboards and counted in the SLO. Latency
// drifts in a 20-minute wave between about 40 and 140 ms, with a rare error,
// so the graphs, heatmap and traces look like a quiet, healthy service.
import http from "k6/http";

const WAVE_SECONDS = 1200;

export const options = {
  scenarios: {
    ambient: {
      executor: "constant-arrival-rate", rate: 3, timeUnit: "1s",
      duration: "24h", // the task is torn down long before
      preAllocatedVUs: 5, maxVUs: 20,
    },
  },
};

// Requests fail until the load balancer and DNS are ready; k6 just keeps going.
export default function () {
  const wave = Math.sin((2 * Math.PI * Date.now()) / 1000 / WAVE_SECONDS);
  const latency = Math.round(90 + 50 * wave);
  http.get(`${__ENV.BASE_URL}/api/simulate?latency_ms=${latency}&jitter_ms=40&error_rate=0.003`, {
    headers: { "X-Load-Test-Token": __ENV.LOAD_TEST_TOKEN, "X-Load-Test-Scenario": "ambient" },
    tags: { name: "simulate" },
  });
}
