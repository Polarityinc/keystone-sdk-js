#!/usr/bin/env bash
set -euo pipefail

# ================================================================
# Keystone — End-to-end Deployment Orchestrator
# ================================================================
#
# Run this on your LAPTOP (macOS/Linux). It will:
#   1. Verify prerequisites (doctl, ssh key)
#   2. Create a worker snapshot (spins up temp droplet, installs tooling,
#      snapshots, destroys — takes ~4 minutes)
#   3. Create the control plane droplet ($6/mo, always-on)
#   4. SSH in and install Consul + Nomad server + Autoscaler
#   5. Register the sandbox job and apply the autoscaling policy
#   6. Print UI URLs and verify everything is running
#
# Usage:
#   export DO_TOKEN="dop_v1_..."
#   ./deploy-keystone.sh
#
# Optional env vars:
#   REGION=nyc1                        # DO region
#   WORKER_SIZE=s-8vcpu-16gb-amd       # Worker droplet size
#   CONTROL_SIZE=s-1vcpu-1gb           # Control plane size
#   SSH_KEY_IDS=12345,67890            # Comma-separated (auto-detected if unset)
#   SKIP_SNAPSHOT=1                    # Reuse existing snapshot
#   KEEP_CONTROL_ON_FAIL=1             # Don't destroy control plane if setup fails
# ================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[deploy]${NC} $*"; }
info() { echo -e "${BLUE}[deploy]${NC} $*"; }
warn() { echo -e "${YELLOW}[deploy]${NC} $*"; }
err()  { echo -e "${RED}[deploy]${NC} $*" >&2; exit 1; }

# ── Config ──
REGION="${REGION:-nyc1}"
WORKER_SIZE="${WORKER_SIZE:-s-8vcpu-16gb-amd}"
CONTROL_SIZE="${CONTROL_SIZE:-s-1vcpu-1gb}"
SNAPSHOT_NAME="keystone-worker"
CONTROL_NAME="keystone-control"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"

# ── Prereqs ──
check_prereqs() {
  log "Checking prerequisites..."

  command -v doctl &>/dev/null || err "doctl not installed. Run: brew install doctl"
  command -v ssh &>/dev/null || err "ssh not found"
  command -v jq &>/dev/null || err "jq not installed. Run: brew install jq"

  [[ -n "${DO_TOKEN:-}" ]] || err "Set DO_TOKEN env var"

  # Verify token works
  if ! doctl compute droplet list -t "$DO_TOKEN" &>/dev/null; then
    err "DO_TOKEN is invalid or lacks droplet:read scope"
  fi
  log "  doctl + token OK"

  # SSH key auto-detection
  if [[ -z "${SSH_KEY_IDS:-}" ]]; then
    SSH_KEY_IDS=$(doctl compute ssh-key list -t "$DO_TOKEN" --format ID --no-header | head -1 | tr -d '[:space:]')
    [[ -n "$SSH_KEY_IDS" ]] || err "No SSH keys in DO account. Add one: doctl compute ssh-key import"
    log "  Using SSH key: $SSH_KEY_IDS"
  fi

  # Verify scripts exist
  for script in setup-worker.sh setup-control-plane.sh; do
    [[ -f "$SCRIPT_DIR/$script" ]] || err "Missing $SCRIPT_DIR/$script"
  done
  log "  Scripts found"

  # Verify sandbox nomad job exists
  [[ -f "$INFRA_DIR/nomad/sandbox.nomad.hcl" ]] || err "Missing $INFRA_DIR/nomad/sandbox.nomad.hcl"
  log "  Nomad jobs found"
}

# ── Build worker snapshot ──
build_snapshot() {
  if [[ -n "${SKIP_SNAPSHOT:-}" ]]; then
    log "Skipping snapshot build (SKIP_SNAPSHOT=1)"
    return
  fi

  # Check if snapshot already exists
  existing=$(doctl compute snapshot list -t "$DO_TOKEN" --format Name --no-header | grep "^$SNAPSHOT_NAME$" || true)
  if [[ -n "$existing" ]]; then
    info "Snapshot '$SNAPSHOT_NAME' already exists. Rebuild? (y/N)"
    read -r -t 10 response || response="n"
    if [[ "$response" != "y" ]]; then
      log "Keeping existing snapshot"
      return
    fi
  fi

  log "Building worker snapshot (~4 min)..."
  DROPLET_NAME="keystone-worker-builder-$(date +%s)"

  DROPLET_ID=$(doctl compute droplet create "$DROPLET_NAME" \
    --image ubuntu-24-04-x64 \
    --size "$WORKER_SIZE" \
    --region "$REGION" \
    --ssh-keys "$SSH_KEY_IDS" \
    --wait \
    --format ID --no-header \
    -t "$DO_TOKEN")
  log "  Builder droplet created: $DROPLET_ID"

  # Get IP
  for _ in $(seq 1 30); do
    DROPLET_IP=$(doctl compute droplet get "$DROPLET_ID" --format PublicIPv4 --no-header -t "$DO_TOKEN" | tr -d '[:space:]')
    [[ -n "$DROPLET_IP" ]] && break
    sleep 2
  done
  log "  Builder IP: $DROPLET_IP"

  # Wait for SSH
  log "  Waiting for SSH..."
  for i in $(seq 1 60); do
    if ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "root@$DROPLET_IP" "true" &>/dev/null; then
      break
    fi
    sleep 3
    [[ $i -eq 60 ]] && err "Builder droplet SSH timeout"
  done

  # Run setup-worker.sh
  log "  Installing Podman + crun + Nomad (~2 min)..."
  scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "$SCRIPT_DIR/setup-worker.sh" "root@$DROPLET_IP:/tmp/setup-worker.sh"
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "root@$DROPLET_IP" "chmod +x /tmp/setup-worker.sh && /tmp/setup-worker.sh" >/tmp/worker-setup.log 2>&1 \
    || err "Worker setup failed. Check /tmp/worker-setup.log"

  # Snapshot
  log "  Powering off + snapshotting..."
  doctl compute droplet-action shutdown "$DROPLET_ID" --wait -t "$DO_TOKEN" >/dev/null

  # Delete old snapshot with same name
  old=$(doctl compute snapshot list -t "$DO_TOKEN" --format ID,Name --no-header | grep " $SNAPSHOT_NAME$" | awk '{print $1}')
  [[ -n "$old" ]] && doctl compute snapshot delete "$old" --force -t "$DO_TOKEN" >/dev/null

  doctl compute droplet-action snapshot "$DROPLET_ID" --snapshot-name "$SNAPSHOT_NAME" --wait -t "$DO_TOKEN" >/dev/null
  SNAP_ID=$(doctl compute snapshot list -t "$DO_TOKEN" --format ID,Name --no-header | grep " $SNAPSHOT_NAME$" | awk '{print $1}')
  log "  Snapshot created: $SNAP_ID"

  # Destroy builder
  log "  Destroying builder droplet..."
  doctl compute droplet delete "$DROPLET_ID" --force -t "$DO_TOKEN"
}

# ── Create control plane ──
create_control_plane() {
  log "Creating control plane droplet ($CONTROL_SIZE in $REGION)..."

  # Check for existing
  existing=$(doctl compute droplet list -t "$DO_TOKEN" --format ID,Name --no-header | grep " $CONTROL_NAME$" | awk '{print $1}')
  if [[ -n "$existing" ]]; then
    warn "Control plane already exists (ID: $existing). Destroy + rebuild? (y/N)"
    read -r -t 10 response || response="n"
    if [[ "$response" == "y" ]]; then
      doctl compute droplet delete "$existing" --force -t "$DO_TOKEN"
      sleep 5
    else
      CONTROL_ID="$existing"
      CONTROL_IP=$(doctl compute droplet get "$existing" --format PublicIPv4 --no-header -t "$DO_TOKEN" | tr -d '[:space:]')
      log "  Reusing existing control plane: $CONTROL_IP"
      return
    fi
  fi

  CONTROL_ID=$(doctl compute droplet create "$CONTROL_NAME" \
    --image ubuntu-24-04-x64 \
    --size "$CONTROL_SIZE" \
    --region "$REGION" \
    --ssh-keys "$SSH_KEY_IDS" \
    --wait \
    --format ID --no-header \
    -t "$DO_TOKEN")
  log "  Control plane created: $CONTROL_ID"

  for _ in $(seq 1 30); do
    CONTROL_IP=$(doctl compute droplet get "$CONTROL_ID" --format PublicIPv4 --no-header -t "$DO_TOKEN" | tr -d '[:space:]')
    [[ -n "$CONTROL_IP" ]] && break
    sleep 2
  done
  log "  Control plane IP: $CONTROL_IP"

  # Wait for SSH
  log "  Waiting for SSH..."
  for i in $(seq 1 60); do
    if ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "root@$CONTROL_IP" "true" &>/dev/null; then
      break
    fi
    sleep 3
    [[ $i -eq 60 ]] && err "Control plane SSH timeout"
  done
}

# ── Install control plane ──
install_control_plane() {
  log "Installing Consul + Nomad + Autoscaler on control plane..."

  # Copy setup script
  scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "$SCRIPT_DIR/setup-control-plane.sh" "root@$CONTROL_IP:/tmp/setup-control-plane.sh"

  # Run it (pass DO_TOKEN via env)
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "root@$CONTROL_IP" \
    "DO_TOKEN='$DO_TOKEN' chmod +x /tmp/setup-control-plane.sh && DO_TOKEN='$DO_TOKEN' /tmp/setup-control-plane.sh" \
    2>&1 | sed 's/^/    /'

  log "  Control plane installation complete"
}

# ── Register sandbox job ──
register_jobs() {
  log "Registering Nomad sandbox job..."

  scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "$INFRA_DIR/nomad/sandbox.nomad.hcl" "root@$CONTROL_IP:/tmp/sandbox.nomad.hcl"

  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "root@$CONTROL_IP" \
    "nomad job run /tmp/sandbox.nomad.hcl" 2>&1 | sed 's/^/    /' || warn "Job registration failed"
}

# ── Verify ──
verify() {
  log "Verifying deployment..."
  sleep 3

  local ok=true
  for svc in consul nomad nomad-autoscaler; do
    if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "root@$CONTROL_IP" "systemctl is-active $svc" &>/dev/null; then
      log "  $svc: RUNNING"
    else
      warn "  $svc: NOT RUNNING"
      ok=false
    fi
  done

  if [[ "$ok" != "true" ]]; then
    warn "Some services are not running. Check logs:"
    warn "  ssh root@$CONTROL_IP 'journalctl -u nomad -u consul -u nomad-autoscaler -n 50'"
  fi
}

# ── Summary ──
print_summary() {
  cat <<EOF

${GREEN}============================================${NC}
${GREEN}  Keystone deployment complete${NC}
${GREEN}============================================${NC}

  Control plane:  http://$CONTROL_IP
    Consul UI:    http://$CONTROL_IP:8500
    Nomad UI:     http://$CONTROL_IP:4646
    API server:   http://$CONTROL_IP:8080 (deploy keystone-api job next)

  SSH:            ssh root@$CONTROL_IP

  Worker snapshot: $SNAPSHOT_NAME (used by autoscaler)

  ${BLUE}What runs now:${NC}
    - Consul server (service discovery)
    - Nomad server (scheduler only, no workloads)
    - Nomad Autoscaler (watches pending allocations, creates workers)

  ${BLUE}How scaling works:${NC}
    1. Client hits /v1/sandboxes
    2. API dispatches keystone-sandbox Nomad job
    3. If no worker has capacity, autoscaler creates a DO droplet from snapshot
    4. Worker joins cluster in ~30s, sandbox starts in ~150ms (Podman+crun)
    5. After 5min idle, autoscaler destroys the worker

  ${BLUE}Test dispatch (once keystone-api is deployed):${NC}
    ssh root@$CONTROL_IP "nomad job dispatch -meta sandbox_id=sb-001 -meta spec_id=test keystone-sandbox"

  ${BLUE}Monitor autoscaler:${NC}
    ssh root@$CONTROL_IP "journalctl -u nomad-autoscaler -f"

  ${BLUE}Resource limits:${NC}
    - Max concurrent per API key: 20
    - Max per sandbox: 8 vCPU / 16 GiB
    - Default sandbox: 2 vCPU / 4 GiB
    - Workers: $WORKER_SIZE (fits ~4 default sandboxes each)
    - Max workers: 24 (DO account droplet limit minus 1)

${GREEN}============================================${NC}
EOF
}

# ── Cleanup on failure ──
cleanup() {
  if [[ $? -ne 0 ]] && [[ -z "${KEEP_CONTROL_ON_FAIL:-}" ]] && [[ -n "${CONTROL_ID:-}" ]]; then
    warn "Setup failed. Destroying control plane droplet (set KEEP_CONTROL_ON_FAIL=1 to keep)..."
    doctl compute droplet delete "$CONTROL_ID" --force -t "$DO_TOKEN" || true
  fi
}
trap cleanup EXIT

# ── Run ──
check_prereqs
build_snapshot
create_control_plane
install_control_plane
register_jobs
verify
print_summary
trap - EXIT
