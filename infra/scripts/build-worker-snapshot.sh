#!/usr/bin/env bash
set -euo pipefail

# ================================================================
# Build a DO snapshot for fast worker spinup
# ================================================================
#
# Creates a temporary droplet, runs the worker setup, snapshots it,
# then destroys the droplet. The snapshot is used by the autoscaler
# to boot new workers in ~30s instead of ~90s.
#
# Requires: doctl CLI authenticated
#
# Usage:
#   ./build-worker-snapshot.sh
#   ./build-worker-snapshot.sh --region sfo3 --size s-2vcpu-4gb
# ================================================================

REGION="${REGION:-nyc1}"
SIZE="${SIZE:-s-8vcpu-16gb-amd}"
SNAPSHOT_NAME="keystone-worker"
DROPLET_NAME="keystone-worker-builder-$(date +%s)"
SSH_KEY_IDS="${SSH_KEY_IDS:-}"  # comma-separated doctl SSH key IDs

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
log() { echo -e "${GREEN}[snapshot]${NC} $*"; }
err() { echo -e "${RED}[snapshot]${NC} $*" >&2; exit 1; }

# Parse args.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2 ;;
    --size)   SIZE="$2"; shift 2 ;;
    --ssh-keys) SSH_KEY_IDS="$2"; shift 2 ;;
    *) err "Unknown arg: $1" ;;
  esac
done

command -v doctl &>/dev/null || err "doctl not found. Install: brew install doctl"
doctl account get &>/dev/null || err "doctl not authenticated. Run: doctl auth init"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKER_SCRIPT="$SCRIPT_DIR/setup-worker.sh"
[[ -f "$WORKER_SCRIPT" ]] || err "setup-worker.sh not found at $WORKER_SCRIPT"

# ── Create builder droplet ──
log "Creating builder droplet ($SIZE in $REGION)..."
SSH_ARGS=""
[[ -n "$SSH_KEY_IDS" ]] && SSH_ARGS="--ssh-keys $SSH_KEY_IDS"

DROPLET_ID=$(doctl compute droplet create "$DROPLET_NAME" \
  --image ubuntu-24-04-x64 \
  --size "$SIZE" \
  --region "$REGION" \
  --tag-names "keystone-builder" \
  $SSH_ARGS \
  --wait \
  --format ID --no-header)

log "Droplet created: $DROPLET_ID"

# Get the IP.
for i in $(seq 1 30); do
  DROPLET_IP=$(doctl compute droplet get "$DROPLET_ID" --format PublicIPv4 --no-header)
  [[ -n "$DROPLET_IP" && "$DROPLET_IP" != "" ]] && break
  sleep 2
done
log "Droplet IP: $DROPLET_IP"

# Wait for SSH.
log "Waiting for SSH..."
for i in $(seq 1 60); do
  ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no "root@$DROPLET_IP" true 2>/dev/null && break
  sleep 3
done

# ── Run worker setup ──
log "Uploading and running worker setup..."
scp -o StrictHostKeyChecking=no "$WORKER_SCRIPT" "root@$DROPLET_IP:/tmp/setup-worker.sh"
ssh -o StrictHostKeyChecking=no "root@$DROPLET_IP" "chmod +x /tmp/setup-worker.sh && /tmp/setup-worker.sh"

# ── Snapshot ──
log "Powering off droplet for clean snapshot..."
doctl compute droplet-action shutdown "$DROPLET_ID" --wait

log "Creating snapshot: $SNAPSHOT_NAME"
# Delete old snapshot with the same name if it exists.
OLD_SNAP=$(doctl compute snapshot list --format ID,Name --no-header | grep "$SNAPSHOT_NAME" | awk '{print $1}')
if [[ -n "$OLD_SNAP" ]]; then
  log "Deleting old snapshot: $OLD_SNAP"
  doctl compute snapshot delete "$OLD_SNAP" --force
fi

doctl compute droplet-action snapshot "$DROPLET_ID" --snapshot-name "$SNAPSHOT_NAME" --wait
SNAP_ID=$(doctl compute snapshot list --format ID,Name --no-header | grep "$SNAPSHOT_NAME" | awk '{print $1}')
log "Snapshot created: $SNAP_ID"

# ── Cleanup ──
log "Destroying builder droplet..."
doctl compute droplet delete "$DROPLET_ID" --force

log ""
log "Done! Worker snapshot '$SNAPSHOT_NAME' (ID: $SNAP_ID) is ready."
log "The autoscaler will use this to boot new workers in ~30s."
