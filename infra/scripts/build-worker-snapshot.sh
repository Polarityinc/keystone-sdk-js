#!/usr/bin/env bash
set -euo pipefail

# ================================================================
# Build a DO snapshot for fast worker spinup (self-contained cloud-init)
# ================================================================
#
# Uses a single cloud-init runcmd that installs everything inline —
# no file-embedding, no SSH, no fragile YAML escaping.
#
# Usage:
#   export DO_TOKEN="dop_v1_..."
#   ./build-worker-snapshot.sh
# ================================================================

REGION="${REGION:-nyc1}"
SIZE="${SIZE:-s-8vcpu-16gb-amd}"
SNAPSHOT_NAME="keystone-worker"
DROPLET_NAME="keystone-worker-builder-$(date +%s)"

NOMAD_VERSION="1.11.3"
CONSUL_VERSION="1.22.6"
PODMAN_DRIVER_VERSION="0.6.4"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
log() { echo -e "${GREEN}[snapshot]${NC} $*"; }
err() { echo -e "${RED}[snapshot]${NC} $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2 ;;
    --size)   SIZE="$2"; shift 2 ;;
    *) err "Unknown arg: $1" ;;
  esac
done

command -v doctl &>/dev/null || err "doctl not found. Install: brew install doctl"
[[ -n "${DO_TOKEN:-}" ]] || err "Set DO_TOKEN env var"
DOCTL_ARGS="-t $DO_TOKEN"
doctl compute droplet list $DOCTL_ARGS &>/dev/null || err "DO_TOKEN invalid"

# ── Build cloud-init with inline install commands ──
USER_DATA_FILE=$(mktemp /tmp/keystone-cloudinit.XXXXXX.yaml)
trap 'rm -f "$USER_DATA_FILE"' EXIT

cat > "$USER_DATA_FILE" <<YAML
#cloud-config
package_update: true
package_upgrade: false
packages:
  - curl
  - unzip
  - jq
  - podman
  - crun
  - cgroup-tools

runcmd:
  - [ sh, -c, "echo '[engine]\nruntime = \"crun\"' > /etc/containers/containers.conf" ]
  - systemctl enable podman.socket
  - mkdir -p /etc/systemd/system/podman.socket.d
  - [ sh, -c, "echo '[Socket]\nSocketMode=0666' > /etc/systemd/system/podman.socket.d/override.conf" ]
  - [ sh, -c, "cd /tmp && curl -fsSL https://releases.hashicorp.com/nomad/${NOMAD_VERSION}/nomad_${NOMAD_VERSION}_linux_amd64.zip -o nomad.zip && unzip -o nomad.zip -d /usr/local/bin/ && rm nomad.zip" ]
  - [ sh, -c, "cd /tmp && curl -fsSL https://releases.hashicorp.com/consul/${CONSUL_VERSION}/consul_${CONSUL_VERSION}_linux_amd64.zip -o consul.zip && unzip -o consul.zip -d /usr/local/bin/ && rm consul.zip" ]
  - mkdir -p /opt/nomad/plugins /opt/nomad /opt/consul /etc/nomad.d /etc/consul.d
  - [ sh, -c, "cd /tmp && curl -fsSL https://releases.hashicorp.com/nomad-driver-podman/${PODMAN_DRIVER_VERSION}/nomad-driver-podman_${PODMAN_DRIVER_VERSION}_linux_amd64.zip -o pd.zip && unzip -o pd.zip -d /opt/nomad/plugins/ && chmod +x /opt/nomad/plugins/nomad-driver-podman && rm pd.zip" ]
  - useradd --system --shell /bin/false consul || true
  - chown -R consul:consul /opt/consul /etc/consul.d
  - systemctl daemon-reload
  - systemctl enable podman.socket
  - [ sh, -c, "podman pull docker.io/library/alpine:3.20 || true" ]
  - [ sh, -c, "podman pull docker.io/library/postgres:16-alpine || true" ]
  - [ sh, -c, "podman pull docker.io/library/redis:7-alpine || true" ]
  - touch /tmp/keystone-setup-done
  - sync
  - shutdown -h +1
YAML

log "Creating builder droplet ($SIZE in $REGION)..."
DROPLET_ID=$(doctl compute droplet create "$DROPLET_NAME" \
  --image ubuntu-24-04-x64 \
  --size "$SIZE" \
  --region "$REGION" \
  --user-data-file "$USER_DATA_FILE" \
  --wait \
  --format ID --no-header \
  $DOCTL_ARGS)
log "Droplet created: $DROPLET_ID"

log "Waiting for cloud-init to install + auto-shutdown (~5 min)..."
MAX_WAIT=900
ELAPSED=0
while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  STATUS=$(doctl compute droplet get "$DROPLET_ID" --format Status --no-header $DOCTL_ARGS 2>/dev/null | tr -d '[:space:]')
  if [[ "$STATUS" == "off" ]]; then
    log "Droplet shut down — cloud-init done."
    break
  fi
  printf "."
  sleep 15
  ELAPSED=$((ELAPSED + 15))
done
echo ""

[[ $ELAPSED -ge $MAX_WAIT ]] && err "Cloud-init timeout. Droplet $DROPLET_ID left for debugging."

# Delete old snapshot with same name (|| true so grep-no-match doesn't trigger set -e)
OLD_SNAP=$(doctl compute snapshot list --format ID,Name --no-header $DOCTL_ARGS | grep " $SNAPSHOT_NAME$" | awk '{print $1}' || true)
if [[ -n "$OLD_SNAP" ]]; then
  log "Deleting old snapshot $OLD_SNAP..."
  doctl compute snapshot delete "$OLD_SNAP" --force $DOCTL_ARGS
fi

log "Creating snapshot..."
doctl compute droplet-action snapshot "$DROPLET_ID" --snapshot-name "$SNAPSHOT_NAME" --wait $DOCTL_ARGS
SNAP_ID=$(doctl compute snapshot list --format ID,Name --no-header $DOCTL_ARGS | grep " $SNAPSHOT_NAME$" | awk '{print $1}' || true)
log "Snapshot created: $SNAP_ID"

log "Destroying builder droplet..."
doctl compute droplet delete "$DROPLET_ID" --force $DOCTL_ARGS

log ""
log "Done! Snapshot '$SNAPSHOT_NAME' (ID: $SNAP_ID) ready for autoscaler."
