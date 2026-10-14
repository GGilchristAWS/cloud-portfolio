#!/usr/bin/env bash
# Reports the CI tool versions Dependabot can't update, because they're
# written into workflow steps: every place each tool is pinned, whether those
# pins agree, and the newest release past the same cooldown Dependabot uses.
#
# Prints a Markdown report. When run in GitHub Actions, also sets the step
# output drift=true if anything is behind or inconsistent.
# Needs: gh (authenticated), GNU grep and date.
set -euo pipefail

COOLDOWN_DAYS=${COOLDOWN_DAYS:-14}
cutoff=$(date -u -d "-${COOLDOWN_DAYS} days" +%Y-%m-%dT%H:%M:%SZ)
workflows=(.github/workflows/*.yml)

# Every pinned version of a tool, one per line, without a leading "v".
pins() {
  case $1 in
    terraform) grep -hoP 'TF_VERSION: \K[0-9.]+' "${workflows[@]}" ;;
    tflint)    grep -hoP 'tflint_version: v?\K[0-9.]+' "${workflows[@]}" ;;
    trivy)     grep -hoP '^\s+version: v\K[0-9.]+' .github/workflows/ci.yml ;; # trivy-action inputs
    checkov)   grep -hoP 'checkov==\K[0-9.]+' "${workflows[@]}" ;;
    uv)        grep -hoP 'UV_VERSION: \K[0-9.]+' "${workflows[@]}"
               grep -hoP 'astral-sh/uv:\K[0-9.]+' app/Dockerfile ;;
  esac
}

# Newest stable x.y.z release published before the cutoff. Sorted by
# version, not date, so a late patch to an older line doesn't win.
latest() {
  gh api "repos/$1/releases?per_page=100" --jq \
    ".[] | select((.draft or .prerelease) | not) | select(.published_at <= \"$cutoff\") | .tag_name" \
    | sed 's/^v//' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1
}

drift=false
echo "### CI tool versions"
echo
echo "Newest release at least ${COOLDOWN_DAYS} days old, compared with what the repo pins."
echo
echo "| Tool | Pinned | Latest eligible | Status |"
echo "|---|---|---|---|"
for entry in terraform:hashicorp/terraform tflint:terraform-linters/tflint \
             trivy:aquasecurity/trivy checkov:bridgecrewio/checkov uv:astral-sh/uv; do
  tool=${entry%%:*}
  repo=${entry#*:}
  pinned=$(pins "$tool" | sort -u | paste -sd' ' -)
  newest=$(latest "$repo")
  if [[ $pinned == *" "* ]]; then
    status="⚠️ pins disagree"
    drift=true
  elif [ "$pinned" = "$newest" ]; then
    status="✅ current"
  elif [ "$(printf '%s\n' "$pinned" "$newest" | sort -V | tail -1)" = "$pinned" ]; then
    status="✅ ahead: pinned within the cooldown"
  elif [ "${pinned%%.*}" != "${newest%%.*}" ]; then
    status="⬆️ new major: read the changelog"
    drift=true
  else
    status="⬆️ behind"
    drift=true
  fi
  echo "| [$tool](https://github.com/$repo/releases) | $pinned | $newest | $status |"
done

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "drift=$drift" >> "$GITHUB_OUTPUT"
fi
