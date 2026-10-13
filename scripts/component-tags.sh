#!/usr/bin/env bash
# Prints an image tag for each deployable component, as key=value lines for
# $GITHUB_OUTPUT. A component's tag is the last commit that changed its build
# inputs, so a commit that touches only one component leaves the other's tag,
# and with it that ECS task definition, unchanged. Unchanged tags also mean
# the image already exists in ECR, so the deploy skips rebuilding it.
#
# Needs full history: actions/checkout with fetch-depth: 0.
set -euo pipefail

if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
  echo "component-tags.sh needs full git history (fetch-depth: 0)" >&2
  exit 1
fi

# Last commit that touched any of the given pathspecs.
last_commit() {
  local sha
  sha=$(git log -1 --format=%H -- "$@")
  if [ -z "$sha" ]; then
    echo "no commit touches: $*" >&2
    exit 1
  fi
  echo "$sha"
}

# The agent config is excluded from obs: it ships in the app task definition
# (infra/ecs.tf), and the monitoring task never reads it.
echo "app=$(last_commit app/)"
echo "obs=$(last_commit obs/Dockerfile obs/config ':!obs/config/agent')"
