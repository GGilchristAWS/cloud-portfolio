"""Copy CloudFront's request count from us-east-1 to this region, for an alarm.

CloudFront's metrics exist only in us-east-1, where the organization's region
policy allows reading them but not creating an alarm (bootstrap/edge.tf).
"""

import os
from datetime import UTC, datetime, timedelta

import boto3

WINDOW = timedelta(minutes=15)

cloudfront_metrics = boto3.client("cloudwatch", region_name="us-east-1")
local_metrics = boto3.client("cloudwatch")


def handler(_event, _context):
    end = datetime.now(UTC).replace(second=0, microsecond=0)
    queries = [
        {
            "Id": f"d{index}",
            "MetricStat": {
                "Metric": {
                    "Namespace": "AWS/CloudFront",
                    "MetricName": "Requests",
                    "Dimensions": [
                        {"Name": "DistributionId", "Value": distribution},
                        {"Name": "Region", "Value": "Global"},
                    ],
                },
                "Period": 60,
                "Stat": "Sum",
            },
        }
        for index, distribution in enumerate(os.environ["DISTRIBUTION_IDS"].split(","))
    ]
    results = cloudfront_metrics.get_metric_data(
        MetricDataQueries=queries, StartTime=end - WINDOW, EndTime=end
    )["MetricDataResults"]
    requests = sum(sum(result["Values"]) for result in results)

    local_metrics.put_metric_data(
        Namespace=os.environ["METRIC_NAMESPACE"],
        MetricData=[{"MetricName": os.environ["METRIC_NAME"], "Value": requests}],
    )
    return {"requests": requests}
