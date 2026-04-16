#!/usr/bin/env bash
set -euo pipefail

# ================================================================
# Keystone Worker Node Setup
# ================================================================
#
# Installs everything a worker needs to run sandboxes:
#   - Podman + crun
#   - Nomad client + Podman driver plugin
#   - Consul client
#
# Run this to create the base image, then snapshot it.
# The autoscaler injects cloud-init to configure + start services.
#
# Usage:
#   sudo ./setup-worker.sh
# ================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[worker]${NC} $*"; }
err()  { echo -e "${RED}[worker]${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || err "Run as root: sudo $0"

NOMAD_VERSION="1.11.3"
CONSUL_VERSION="1.22.6"
PODMAN_DRIVER_VERSION="0.6.4"
ARCH=$(dpkg --print-architecture)

# ── System prep ──
log "Updating system..."
apt-get update -qq
apt-get install -y -qq curl unzip jq cgroup-tools >/dev/null

# ── Podman + crun ──
log "Installing Podman + crun..."
apt-get install -y -qq podman crun >/dev/null 2>&1

mkdir -p /etc/containers
cat > /etc/containers/containers.conf <<'CONF'
[engine]
runtime = "crun"
CONF

systemctl enable podman.socket

# ── Pre-pull common sandbox images ──
log "Pre-pulling common images for fast sandbox startup..."
podman pull docker.io/library/postgres:16-alpine >/dev/null 2>&1 &
podman pull docker.io/library/redis:7-alpine >/dev/null 2>&1 &
podman pull docker.io/library/alpine:3.20 >/dev/null 2>&1 &
wait
log "Images pre-pulled."

# ── Consul client ──
log "Installing Consul ${CONSUL_VERSION}..."
curl -fsSL "https://releases.hashicorp.com/consul/${CONSUL_VERSION}/consul_${CONSUL_VERSION}_linux_${ARCH}.zip" \
  -o /tmp/consul.zip
unzip -o /tmp/consul.zip -d /usr/local/bin/ >/dev/null
rm /tmp/consul.zip

id -u consul &>/dev/null || useradd --system --shell /bin/false consul
mkdir -p /opt/consul /etc/consul.d
chown -R consul:consul /opt/consul /etc/consul.d

# Placeholder config — cloud-init overwrites this with the real join address.
cat > /etc/consul.d/consul.hcl <<'HCL'
datacenter  = "dc1"
data_dir    = "/opt/consul"
bind_addr   = "0.0.0.0"
client_addr = "0.0.0.0"
retry_join  = ["CONTROL_PLANE_IP"]
HCL

cat > /etc/systemd/system/consul.service <<'UNIT'
[Unit]
Description=Consul Agent
Requires=network-online.target
After=network-online.target

[Service]
Type=notify
User=consul
Group=consul
ExecStart=/usr/local/bin/consul agent -config-dir=/etc/consul.d/
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT

# ── Nomad client ──
log "Installing Nomad ${NOMAD_VERSION}..."
curl -fsSL "https://releases.hashicorp.com/nomad/${NOMAD_VERSION}/nomad_${NOMAD_VERSION}_linux_${ARCH}.zip" \
  -o /tmp/nomad.zip
unzip -o /tmp/nomad.zip -d /usr/local/bin/ >/dev/null
rm /tmp/nomad.zip

mkdir -p /opt/nomad /etc/nomad.d /opt/nomad/plugins

# Nomad Podman driver plugin.
log "Installing Nomad Podman driver ${PODMAN_DRIVER_VERSION}..."
curl -fsSL "https://releases.hashicorp.com/nomad-driver-podman/${PODMAN_DRIVER_VERSION}/nomad-driver-podman_${PODMAN_DRIVER_VERSION}_linux_${ARCH}.zip" \
  -o /tmp/podman-driver.zip
unzip -o /tmp/podman-driver.zip -d /opt/nomad/plugins/ >/dev/null
rm /tmp/podman-driver.zip
chmod +x /opt/nomad/plugins/nomad-driver-podman

# Placeholder config — cloud-init overwrites with real server address.
cat > /etc/nomad.d/nomad.hcl <<'HCL'
datacenter = "dc1"
data_dir   = "/opt/nomad"
bind_addr  = "0.0.0.0"

client {
  enabled    = true
  node_class = "worker"
  servers    = ["CONTROL_PLANE_IP:4647"]
}

plugin_dir = "/opt/nomad/plugins"

plugin "nomad-driver-podman" {
  config {
    socket_path     = "unix:///run/podman/podman.sock"
    recover_stopped = false
  }
}

consul {
  address = "127.0.0.1:8500"
}
HCL

# Socket permissions for Nomad -> Podman.
mkdir -p /etc/systemd/system/podman.socket.d
cat > /etc/systemd/system/podman.socket.d/override.conf <<'OVERRIDE'
[Socket]
SocketMode=0666
OVERRIDE

cat > /etc/systemd/system/nomad.service <<'UNIT'
[Unit]
Description=Nomad Agent
Wants=network-online.target consul.service podman.socket
After=network-online.target consul.service podman.socket

[Service]
Type=simple
ExecStart=/usr/local/bin/nomad agent -config /etc/nomad.d/
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
LimitNPROC=infinity
TasksMax=infinity

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload

# Don't enable/start services — cloud-init does that after injecting config.

# ── Clean up for snapshotting ──
log "Cleaning up for snapshot..."
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /tmp/*
truncate -s 0 /var/log/*.log 2>/dev/null || true

log ""
log "Worker image ready. Snapshot this droplet now:"
log "  doctl compute droplet-action snapshot <droplet-id> --snapshot-name keystone-worker"
