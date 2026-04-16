#!/usr/bin/env bash
set -euo pipefail

# ================================================================
# Keystone Platform — Digital Ocean Droplet Setup
# ================================================================
#
# Installs and configures:
#   - Podman + crun (lightweight container runtime)
#   - Nomad (job scheduler)
#   - Consul (service discovery + health checks)
#   - Nomad Podman driver plugin
#
# Tested on: Ubuntu 22.04 / 24.04 LTS
#
# Usage:
#   curl -sSL <raw-url> | sudo bash
#   # or
#   chmod +x setup-droplet.sh && sudo ./setup-droplet.sh
#
# After setup:
#   systemctl status consul nomad
#   nomad status
#   consul members
# ================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[keystone]${NC} $*"; }
warn() { echo -e "${YELLOW}[keystone]${NC} $*"; }
err()  { echo -e "${RED}[keystone]${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || err "Run as root: sudo $0"

NOMAD_VERSION="1.11.3"
CONSUL_VERSION="1.22.6"
PODMAN_DRIVER_VERSION="0.6.4"
ARCH=$(dpkg --print-architecture)  # amd64 or arm64

# ── System prep ──
log "Updating system packages..."
apt-get update -qq
apt-get install -y -qq curl unzip jq gnupg software-properties-common cgroup-tools >/dev/null

# ── Podman + crun ──
log "Installing Podman + crun..."
# Ubuntu 22.04+ has Podman in the official repos.
apt-get install -y -qq podman crun >/dev/null 2>&1 || {
  # Fallback: add the Kubic repo for older Ubuntu.
  . /etc/os-release
  echo "deb https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/xUbuntu_${VERSION_ID}/ /" \
    > /etc/apt/sources.list.d/podman.list
  curl -fsSL "https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/xUbuntu_${VERSION_ID}/Release.key" \
    | gpg --dearmor -o /etc/apt/trusted.gpg.d/podman.gpg
  apt-get update -qq
  apt-get install -y -qq podman crun >/dev/null
}

# Verify crun is the default OCI runtime.
if ! podman info --format '{{.Host.OCIRuntime.Name}}' 2>/dev/null | grep -q crun; then
  warn "Setting crun as default OCI runtime..."
  mkdir -p /etc/containers
  cat > /etc/containers/containers.conf <<'CONF'
[engine]
runtime = "crun"
CONF
fi

CRUN_VERSION=$(crun --version | head -1)
PODMAN_VERSION=$(podman --version)
log "Installed: $PODMAN_VERSION, $CRUN_VERSION"

# Enable Podman socket (required by Nomad driver).
log "Enabling Podman socket..."
systemctl enable --now podman.socket
PODMAN_SOCK=$(systemctl show podman.socket -p Listen | sed 's/Listen=//' | tr -d ' ')
log "Podman socket: $PODMAN_SOCK"

# ── Consul ──
log "Installing Consul ${CONSUL_VERSION}..."
if ! command -v consul &>/dev/null; then
  curl -fsSL "https://releases.hashicorp.com/consul/${CONSUL_VERSION}/consul_${CONSUL_VERSION}_linux_${ARCH}.zip" \
    -o /tmp/consul.zip
  unzip -o /tmp/consul.zip -d /usr/local/bin/ >/dev/null
  rm /tmp/consul.zip
fi

# Create consul user and dirs.
id -u consul &>/dev/null || useradd --system --home /etc/consul.d --shell /bin/false consul
mkdir -p /opt/consul /etc/consul.d
chown -R consul:consul /opt/consul /etc/consul.d

# Consul config.
cat > /etc/consul.d/consul.hcl <<'HCL'
datacenter = "dc1"
data_dir   = "/opt/consul"
bind_addr  = "0.0.0.0"
client_addr = "0.0.0.0"

server           = true
bootstrap_expect = 1

ui_config {
  enabled = true
}

connect {
  enabled = true
}

ports {
  grpc     = 8502
  grpc_tls = 8503
}
HCL

# Consul systemd unit.
cat > /etc/systemd/system/consul.service <<'UNIT'
[Unit]
Description=Consul Agent
Documentation=https://www.consul.io/docs/
Requires=network-online.target
After=network-online.target

[Service]
Type=notify
User=consul
Group=consul
ExecStart=/usr/local/bin/consul agent -config-dir=/etc/consul.d/
ExecReload=/bin/kill -HUP $MAINPID
KillMode=process
KillSignal=SIGTERM
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now consul
log "Consul running."

# ── Nomad ──
log "Installing Nomad ${NOMAD_VERSION}..."
if ! command -v nomad &>/dev/null; then
  curl -fsSL "https://releases.hashicorp.com/nomad/${NOMAD_VERSION}/nomad_${NOMAD_VERSION}_linux_${ARCH}.zip" \
    -o /tmp/nomad.zip
  unzip -o /tmp/nomad.zip -d /usr/local/bin/ >/dev/null
  rm /tmp/nomad.zip
fi

# Create nomad user and dirs.
id -u nomad &>/dev/null || useradd --system --home /etc/nomad.d --shell /bin/false nomad
mkdir -p /opt/nomad /etc/nomad.d /opt/nomad/plugins
chown -R nomad:nomad /opt/nomad /etc/nomad.d

# ── Nomad Podman driver plugin ──
log "Installing Nomad Podman driver ${PODMAN_DRIVER_VERSION}..."
curl -fsSL "https://releases.hashicorp.com/nomad-driver-podman/${PODMAN_DRIVER_VERSION}/nomad-driver-podman_${PODMAN_DRIVER_VERSION}_linux_${ARCH}.zip" \
  -o /tmp/nomad-driver-podman.zip
unzip -o /tmp/nomad-driver-podman.zip -d /opt/nomad/plugins/ >/dev/null
rm /tmp/nomad-driver-podman.zip
chmod +x /opt/nomad/plugins/nomad-driver-podman

# Nomad config.
cat > /etc/nomad.d/nomad.hcl <<'HCL'
datacenter = "dc1"
data_dir   = "/opt/nomad"
bind_addr  = "0.0.0.0"

server {
  enabled          = true
  bootstrap_expect = 1
}

client {
  enabled = true

  // Allow the exec driver with full isolation.
  options {
    "driver.exec.enable" = "1"
  }
}

plugin_dir = "/opt/nomad/plugins"

plugin "nomad-driver-podman" {
  config {
    // Use the systemd-managed Podman socket.
    socket_path = "unix:///run/podman/podman.sock"

    // Don't recover containers from before a Nomad restart.
    recover_stopped = false

    // crun handles cgroup v2 natively.
    // No extra config needed — Podman uses it by default.
  }
}

consul {
  address = "127.0.0.1:8500"
}

telemetry {
  publish_allocation_metrics = true
  publish_node_metrics       = true
  prometheus_metrics         = true
}
HCL

# Allow nomad user to access the Podman socket.
usermod -aG systemd-journal nomad 2>/dev/null || true
# Create a polkit rule or socket override so Nomad can talk to Podman.
mkdir -p /etc/systemd/system/podman.socket.d
cat > /etc/systemd/system/podman.socket.d/override.conf <<'OVERRIDE'
[Socket]
SocketMode=0660
SocketGroup=nomad
OVERRIDE
systemctl daemon-reload
systemctl restart podman.socket

# Nomad systemd unit.
cat > /etc/systemd/system/nomad.service <<'UNIT'
[Unit]
Description=Nomad Agent
Documentation=https://www.nomadproject.io/docs/
Wants=network-online.target consul.service
After=network-online.target consul.service

[Service]
Type=simple
User=root
Group=root
ExecStart=/usr/local/bin/nomad agent -config /etc/nomad.d/
ExecReload=/bin/kill -HUP $MAINPID
KillMode=process
KillSignal=SIGINT
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
LimitNPROC=infinity
TasksMax=infinity

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now nomad
log "Nomad running."

# ── Verify ──
log ""
log "Waiting for services to stabilize..."
sleep 5

CONSUL_OK=false
NOMAD_OK=false
PODMAN_OK=false

consul members &>/dev/null && CONSUL_OK=true
nomad status &>/dev/null && NOMAD_OK=true
podman info &>/dev/null && PODMAN_OK=true

log "============================================"
log "  Keystone Infrastructure Status"
log "============================================"
log "  Consul:  $($CONSUL_OK && echo 'RUNNING' || echo 'FAILED')"
log "  Nomad:   $($NOMAD_OK && echo 'RUNNING' || echo 'FAILED')"
log "  Podman:  $($PODMAN_OK && echo 'RUNNING' || echo 'FAILED')"
log "  Runtime: $(crun --version | head -1)"
log ""
log "  Consul UI:  http://$(hostname -I | awk '{print $1}'):8500"
log "  Nomad  UI:  http://$(hostname -I | awk '{print $1}'):4646"
log ""

# Show Nomad driver status.
for i in $(seq 1 15); do
  DRIVERS=$(nomad node status -self 2>&1 | grep "Driver Status" || true)
  if echo "$DRIVERS" | grep -q podman; then
    log "  Nomad drivers: $DRIVERS"
    break
  fi
  sleep 2
done

log ""
log "  Next steps:"
log "    1. Copy your Nomad job files to this server"
log "    2. nomad job run sandbox.nomad.hcl"
log "    3. nomad job dispatch -meta sandbox_id=sb-001 -meta spec_id=my-spec keystone-sandbox"
log ""
log "============================================"
