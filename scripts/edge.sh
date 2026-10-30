#!/usr/bin/env bash
# Handles unexpected traffic at CloudFront (bootstrap/edge.tf): find the
# busiest viewer IPs in the access logs, and block or unblock one. A block
# reaches every edge location within seconds; nothing is redeployed.
#
#   scripts/edge.sh top [HOURS]          busiest IPs over the last HOURS (default 1)
#   scripts/edge.sh block IP [REASON]    refuse IP on the resume, demo and Grafana
#   scripts/edge.sh unblock IP
#   scripts/edge.sh list                 blocked IPs, with when and why
#
# Uses AWS_PROFILE (default portfolio-admin). For a flood from many addresses,
# turn on WAF instead (waf_enabled in bootstrap; README, "Unexpected traffic").
set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-portfolio-admin}"
export AWS_REGION=us-east-1 # CloudFront's logs and key value stores
PROJECT=cloud-portfolio
LOG_GROUP="/aws/vendedlogs/cloudfront/$PROJECT"

usage() { sed -n '5,9p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

kvs_arn() {
  aws cloudfront describe-key-value-store --name "$PROJECT-blocklist" \
    --query KeyValueStore.ARN --output text
}

etag() { aws cloudfront-keyvaluestore describe-key-value-store --kvs-arn "$1" --query ETag --output text; }

# CloudFront's viewer.ip is in canonical form (IPv6 compressed), so keys must be too.
canonical_ip() {
  python3 -c 'import ipaddress, sys; print(ipaddress.ip_address(sys.argv[1]))' "$1" 2>/dev/null \
    || { echo "Not an IP address: $1" >&2; exit 2; }
}

# Backticks below are Logs Insights and JMESPath syntax, not shell.
# shellcheck disable=SC2016
top() {
  local hours="${1:-1}" now query_id status
  now=$(date +%s)
  query_id=$(aws logs start-query --log-group-name "$LOG_GROUP" \
    --start-time $((now - hours * 3600)) --end-time "$now" \
    --query-string 'stats count(*) as requests by `c-ip`, `x-host-header` | sort requests desc | limit 15' \
    --query queryId --output text)
  for _ in $(seq 1 30); do
    status=$(aws logs get-query-results --query-id "$query_id" --query status --output text)
    [ "$status" = Complete ] && break
    sleep 2
  done
  echo "Busiest viewers, last ${hours}h (requests, IP, host):"
  aws logs get-query-results --query-id "$query_id" \
    --query 'results[].[ [?field==`requests`].value | [0], [?field==`c-ip`].value | [0], [?field==`x-host-header`].value | [0] ]' \
    --output text
}

block() {
  local ip arn
  ip=$(canonical_ip "$1")
  arn=$(kvs_arn)
  aws cloudfront-keyvaluestore put-key --kvs-arn "$arn" --if-match "$(etag "$arn")" \
    --key "$ip" --value "$(date -u +%FT%TZ) ${2:-blocked by hand}" > /dev/null
  echo "Blocked $ip"
}

unblock() {
  local ip arn
  ip=$(canonical_ip "$1")
  arn=$(kvs_arn)
  aws cloudfront-keyvaluestore delete-key --kvs-arn "$arn" --if-match "$(etag "$arn")" --key "$ip" > /dev/null
  echo "Unblocked $ip"
}

list() {
  aws cloudfront-keyvaluestore list-keys --kvs-arn "$(kvs_arn)" --query 'Items[].[Key, Value]' --output text
}

case "${1:-}" in
  top) top "${2:-1}" ;;
  block) [ $# -ge 2 ] || usage; block "$2" "${*:3}" ;;
  unblock) [ $# -eq 2 ] || usage; unblock "$2" ;;
  list) list ;;
  *) usage ;;
esac
