#!/usr/bin/env bash
set -euo pipefail

# ================================================================
# Keystone Control Plane — Always-on $6/mo droplet
# ================================================================
#
# Installs:
#   - Consul server (service discovery)
#   - Nomad server (scheduler only, no client/workloads)
#   - Nomad Autoscaler (creates/destroys worker droplets)
#
# This node runs NO sandboxes. It just accepts API requests
# and decides where to place workloads.
#
# Usage:
#   export DO_TOKEN="dop_v1_..."
#   sudo -E ./setup-control-plane.sh
# ================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[control-plane]${NC} $*"; }
warn() { echo -e "${YELLOW}[control-plane]${NC} $*"; }
err()  { echo -e "${RED}[control-plane]${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || err "Run as root: sudo -E $0"
[[ -n "${DO_TOKEN:-}" ]] || err "Set DO_TOKEN env var for autoscaler"

NOMAD_VERSION="1.11.3"
CONSUL_VERSION="1.22.6"
AUTOSCALER_VERSION="0.4.5"
ARCH=$(dpkg --print-architecture)
PRIVATE_IP=$(hostname -I | awk '{print $1}')

log "Private IP: $PRIVATE_IP"

# ── System prep ──
apt-get update -qq
apt-get install -y -qq curl unzip jq >/dev/null

# ── Consul server ──
log "Installing Consul ${CONSUL_VERSION}..."
if ! command -v consul &>/dev/null; then
  curl -fsSL "https://releases.hashicorp.com/consul/${CONSUL_VERSION}/consul_${CONSUL_VERSION}_linux_${ARCH}.zip" \
    -o /tmp/consul.zip
  unzip -o /tmp/consul.zip -d /usr/local/bin/ >/dev/null
  rm /tmp/consul.zip
fi

id -u consul &>/dev/null || useradd --system --home /etc/consul.d --shell /bin/false consul
mkdir -p /opt/consul /etc/consul.d
chown -R consul:consul /opt/consul /etc/consul.d

CONSUL_ENCRYPT=$(consul keygen)

cat > /etc/consul.d/consul.hcl <<HCL
datacenter = "dc1"
data_dir   = "/opt/consul"
bind_addr  = "${PRIVATE_IP}"
client_addr = "0.0.0.0"

server           = true
bootstrap_expect = 1

encrypt = "${CONSUL_ENCRYPT}"

ui_config {
  enabled = true
}

connect {
  enabled = true
}

# Advertise the private IP so workers can join.
advertise_addr = "${PRIVATE_IP}"

# Retry join via DO tag — workers tag themselves "keystone-consul".
retry_join = ["provider=digitalocean region=nyc1 tag_name=keystone-consul api_token=${DO_TOKEN}"]
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

systemctl daemon-reload
systemctl enable --now consul
log "Consul server running."

# ── Nomad server (no client) ──
log "Installing Nomad ${NOMAD_VERSION}..."
if ! command -v nomad &>/dev/null; then
  curl -fsSL "https://releases.hashicorp.com/nomad/${NOMAD_VERSION}/nomad_${NOMAD_VERSION}_linux_${ARCH}.zip" \
    -o /tmp/nomad.zip
  unzip -o /tmp/nomad.zip -d /usr/local/bin/ >/dev/null
  rm /tmp/nomad.zip
fi

mkdir -p /opt/nomad /etc/nomad.d

cat > /etc/nomad.d/nomad.hcl <<HCL
datacenter = "dc1"
data_dir   = "/opt/nomad"
bind_addr  = "0.0.0.0"

advertise {
  http = "${PRIVATE_IP}"
  rpc  = "${PRIVATE_IP}"
  serf = "${PRIVATE_IP}"
}

server {
  enabled          = true
  bootstrap_expect = 1
}

# No client block — this node does NOT run workloads.

consul {
  address = "127.0.0.1:8500"
}

telemetry {
  publish_allocation_metrics = true
  publish_node_metrics       = true
  prometheus_metrics         = true
}
HCL

cat > /etc/systemd/system/nomad.service <<'UNIT'
[Unit]
Description=Nomad Agent
Wants=network-online.target consul.service
After=network-online.target consul.service

[Service]
Type=simple
ExecStart=/usr/local/bin/nomad agent -config /etc/nomad.d/
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now nomad
log "Nomad server running."

# ── Nomad Autoscaler ──
log "Installing Nomad Autoscaler ${AUTOSCALER_VERSION}..."
curl -fsSL "https://releases.hashicorp.com/nomad-autoscaler/${AUTOSCALER_VERSION}/nomad-autoscaler_${AUTOSCALER_VERSION}_linux_${ARCH}.zip" \
  -o /tmp/autoscaler.zip
unzip -o /tmp/autoscaler.zip -d /usr/local/bin/ >/dev/null
rm /tmp/autoscaler.zip

mkdir -p /etc/nomad-autoscaler

cat > /etc/nomad-autoscaler/config.hcl <<HCL
nomad {
  address = "http://${PRIVATE_IP}:4646"
}

log_level = "INFO"

policy_eval {
  workers = {
    cluster    = 2
    horizontal = 2
  }
}

# Auto-load policy files from this directory at startup so we don't need to
# run \`nomad-autoscaler policy apply\` manually after boot.
policy_dir = "/etc/nomad-autoscaler/policies"

apm "nomad-apm" {
  driver = "nomad-apm"
}

strategy "target-value" {
  driver = "target-value"
}
HCL

mkdir -p /etc/nomad-autoscaler/policies

# Autoscaling policy: watch for pending sandbox allocations.
# Placed in policies/ directory so it's auto-loaded by nomad-autoscaler on start.
cat > /etc/nomad-autoscaler/policies/keystone-workers.hcl <<HCL
scaling "keystone-workers" {
  enabled = true
  type    = "cluster"

  min = 0
  max = 24  # 25 droplet limit minus 1 control plane

  policy {
    # Scale based on total allocatable CPU remaining.
    # When free CPU drops below 2000 MHz, add a node.
    # When free CPU exceeds 6000 MHz, remove a node.
    check "cpu_allocated_percentage" {
      source = "nomad-apm"
      query  = "percentage-allocated_cpu"

      strategy "target-value" {
        target = 70
      }
    }

    target "digitalocean" {
      driver = "digitalocean"

      digitalocean_token     = "${DO_TOKEN}"
      droplet_size           = "s-8vcpu-16gb-amd"  # Premium AMD — best price/perf
      droplet_region         = "nyc1"
      droplet_image          = "keystone-worker"    # DO snapshot name
      droplet_ssh_keys       = ""                 # comma-separated key IDs
      droplet_tag            = "keystone-worker"
      droplet_user_data_file = "/etc/nomad-autoscaler/worker-cloud-init.sh"

      node_class             = "worker"
      node_drain_deadline    = "5m"
      node_drain_ignore_system_jobs = true

      # Cooldown: wait 3 min after scale-up before scaling again.
      # Prevents thrashing when workers are still booting.
      cooldown            = "180s"
      cooldown_scale_down = "300s"
    }
  }
}
HCL

# Cloud-init script injected into new worker droplets.
cat > /etc/nomad-autoscaler/worker-cloud-init.sh <<CLOUDINIT
#!/bin/bash
# Worker droplets boot from a pre-baked snapshot that has
# Nomad + Podman + crun already installed.
# This script just configures and starts the services.

PRIVATE_IP=\$(hostname -I | awk '{print \$1}')
CONTROL_PLANE_IP="${PRIVATE_IP}"

# Configure Consul client to join the control plane.
cat > /etc/consul.d/consul.hcl <<EOF
datacenter  = "dc1"
data_dir    = "/opt/consul"
bind_addr   = "\$PRIVATE_IP"
client_addr = "0.0.0.0"
retry_join  = ["\$CONTROL_PLANE_IP"]
EOF

# Configure Nomad client to join the control plane.
cat > /etc/nomad.d/nomad.hcl <<EOF
datacenter = "dc1"
data_dir   = "/opt/nomad"
bind_addr  = "0.0.0.0"

client {
  enabled    = true
  node_class = "worker"

  servers = ["\$CONTROL_PLANE_IP:4647"]
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
EOF

systemctl restart consul
systemctl restart nomad
CLOUDINIT

cat > /etc/systemd/system/nomad-autoscaler.service <<'UNIT'
[Unit]
Description=Nomad Autoscaler
Wants=nomad.service
After=nomad.service

[Service]
Type=simple
ExecStart=/usr/local/bin/nomad-autoscaler agent -config /etc/nomad-autoscaler/
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now nomad-autoscaler
log "Autoscaler running."

# ── Save config for workers ──
echo "${CONSUL_ENCRYPT}" > /etc/keystone-consul-encrypt.key
echo "${PRIVATE_IP}" > /etc/keystone-control-plane-ip

# ── Summary ──
sleep 5
log ""
log "============================================"
log "  Keystone Control Plane"
log "============================================"
log "  Consul:      $(consul members &>/dev/null && echo 'RUNNING' || echo 'STARTING')"
log "  Nomad:       $(nomad status &>/dev/null && echo 'RUNNING' || echo 'STARTING')"
log "  Autoscaler:  $(systemctl is-active nomad-autoscaler)"
log ""
log "  Consul UI:   http://${PRIVATE_IP}:8500"
log "  Nomad UI:    http://${PRIVATE_IP}:4646"
log ""
log "  Next: build the worker snapshot with:"
log "    ./build-worker-snapshot.sh"
log "============================================"
