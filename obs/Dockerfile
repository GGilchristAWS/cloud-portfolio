# Config image for the monitoring task. It holds no software of its own: at
# task start it copies the configs and dashboards into a volume shared with
# the upstream collector, Prometheus, Loki, Tempo and Grafana containers, then
# exits. Building the configs into an image keeps them versioned with the
# commit they belong to and scanned like every other image.
FROM busybox:1.37

COPY config /config

# Runs as root because the shared volume is root-owned; it exits in a second.
CMD ["cp", "-a", "/config/.", "/etc/obs/"]
