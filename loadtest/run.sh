#!/usr/bin/env bash
# Runs a k6 scenario from scenarios.js in the k6 image pinned in
# obs/compose.yaml. Used by load-test.yml and by deploy.yml (post-deploy smoke).
#
#   BASE_URL=https://... LOAD_TEST_TOKEN=... loadtest/run.sh smoke
#
# Writes loadtest/summary.md for the job summary.
set -euo pipefail

scenario=${1:?usage: run.sh <smoke|ramp|spike|soak>}
cd "$(dirname "$0")"
image=$(yq '.services.k6.image' ../obs/compose.yaml)

docker run --rm --user "$(id -u)" -v "$PWD:/loadtest" -w /loadtest \
  -e LOAD_TEST_TOKEN -e BASE_URL -e SOAK_MINUTES -e SCENARIO="$scenario" \
  "$image" run --quiet scenarios.js
