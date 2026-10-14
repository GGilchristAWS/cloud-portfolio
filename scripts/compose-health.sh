#!/usr/bin/env bash
# Starts the local observability stack (obs/compose.yaml) and waits until it
# works end to end: Grafana answers, Prometheus scrapes every monitoring
# component successfully, and the app's own telemetry reaches Prometheus
# through the collector. Used by CI so a dependency bump that validates but
# won't run fails the pull request.
set -euo pipefail

compose="docker compose -f obs/compose.yaml"
$compose up --build --detach --wait --wait-timeout 180

prom() {
  curl -fsS --max-time 5 http://localhost:9090/api/v1/query --data-urlencode "query=$1" \
    | jq -r '.data.result[0].value[1] // "0"'
}

for attempt in $(seq 1 30); do
  curl -fsS --max-time 5 http://localhost:8000/ > /dev/null || true # generate app telemetry
  grafana=$(curl -fsS --max-time 5 http://localhost:3000/api/health | jq -r .database || echo down)
  up=$(prom 'count(up == 1)' || echo 0)
  down=$(prom 'count(up == 0)' || echo 0)
  app=$(prom 'count(target_info{job="portfolio-app"})' || echo 0)
  echo "Attempt $attempt: grafana=$grafana scrape targets up=$up down=$down app telemetry=$app"
  if [ "$grafana" = ok ] && [ "$up" -ge 5 ] && [ "$down" = 0 ] && [ "$app" -ge 1 ]; then
    echo "Observability stack is healthy."
    exit 0
  fi
  sleep 6
done

echo "::error::Observability stack did not become healthy"
exit 1
