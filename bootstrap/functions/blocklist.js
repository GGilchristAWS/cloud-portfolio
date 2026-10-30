// Viewer-request function on every behavior of the resume, demo and Grafana
// distributions (edge.tf, site.tf). Refuses viewers whose IP address is a key
// in the blocklist key value store; scripts/edge.sh adds and removes keys, and
// a change reaches every edge location within seconds, with no deploy.
import cf from "cloudfront";

const blocklist = cf.kvs("${kvs_id}");

async function handler(event) {
  try {
    if (await blocklist.exists(event.viewer.ip)) {
      return { statusCode: 403, statusDescription: "Forbidden" };
    }
  } catch (err) {
    // Fail open: a store error must not take the site down.
  }
  return event.request;
}
