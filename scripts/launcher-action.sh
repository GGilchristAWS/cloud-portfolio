#!/usr/bin/env bash
# Sends an action to the demo launcher (launcher/handler.py), as the deploy
# role. Used by deploy.yml (ensure_teardown) and keep-up.yml (cancel_teardown).
#
#   LAUNCHER_FUNCTION=cloud-portfolio-demo-launcher scripts/launcher-action.sh <action>
set -euo pipefail

action=${1:?usage: launcher-action.sh <ensure_teardown|cancel_teardown>}
out=$(mktemp)

# invoke succeeds even when the function fails; FunctionError says so.
error=$(aws lambda invoke --function-name "${LAUNCHER_FUNCTION:?}" \
  --cli-binary-format raw-in-base64-out --payload "{\"action\": \"$action\"}" \
  --query FunctionError --output text "$out")
if [ "$error" != None ]; then
  echo "::error::The launcher failed ($error): $(cat "$out")"
  exit 1
fi
