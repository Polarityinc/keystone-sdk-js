#!/usr/bin/env bash
set -euo pipefail

# Bootstrap a single-node Nomad + Consul dev cluster for Keystone.
# For production, replace -dev flags with proper config directories.
#
# Prerequisites:
#   - nomad, consul, vault binaries on PATH
#   - Docker running
#
# Usage:
#   ./infra/scripts/bootstrap.sh          # start everything
#   ./infra/scripts/bootstrap.sh teardown  # stop everything

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
DATA_DIR="${KEYSTONE_DATA_DIR:-/tmp/keystone-infra}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[keystone]${NC} $*"; }
warn() { echo -e "${YELLOW}[keystone]${NC} $*"; }
err()  { echo -e "${RED}[keystone]${NC} $*" >&2; }

check_deps() {
  local missing=()
  for cmd in nomad consul docker; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    err "Missing required tools: ${missing[*]}"
    err "Install them and re-run."
    exit 1
  fi
}

teardown() {
  log "Tearing down Keystone infra..."
  # Stop Nomad jobs.
  nomad job stop -purge keystone-api 2>/dev/null || true
  nomad job stop -purge keystone-sandbox 2>/dev/null || true
  nomad job stop -purge keystone-experiment 2>/dev/null || true

  # Kill dev agents.
  pkill -f "nomad agent -dev" 2>/dev/null || true
  pkill -f "consul agent -dev" 2>/dev/null || true

  log "Done."
  exit 0
}

if [[ "${1:-}" == "teardown" ]]; then
  teardown
fi

check_deps
mkdir -p "$DATA_DIR"/{consul,nomad}

# ── Consul ──
log "Starting Consul agent (dev mode)..."
consul agent -dev \
  -data-dir="$DATA_DIR/consul" \
  -client="0.0.0.0" \
  -log-level=warn \
  &>"$DATA_DIR/consul.log" &
CONSUL_PID=$!
log "Consul PID: $CONSUL_PID"

# Wait for Consul to be ready.
for i in $(seq 1 30); do
  if consul info &>/dev/null; then
    break
  fi
  sleep 1
done

if ! consul info &>/dev/null; then
  err "Consul failed to start. Check $DATA_DIR/consul.log"
  exit 1
fi
log "Consul is ready."

# ── Nomad ──
log "Starting Nomad agent (dev mode)..."
nomad agent -dev \
  -data-dir="$DATA_DIR/nomad" \
  -consul-address="127.0.0.1:8500" \
  -log-level=warn \
  &>"$DATA_DIR/nomad.log" &
NOMAD_PID=$!
log "Nomad PID: $NOMAD_PID"

for i in $(seq 1 30); do
  if nomad status &>/dev/null; then
    break
  fi
  sleep 1
done

if ! nomad status &>/dev/null; then
  err "Nomad failed to start. Check $DATA_DIR/nomad.log"
  exit 1
fi
log "Nomad is ready."

# ── Namespace ──
log "Creating keystone namespace..."
nomad namespace apply -description "Keystone platform" keystone 2>/dev/null || true

# ── Consul Config Entries ──
log "Writing Consul service config..."
# Split the multi-document HCL files and apply each block.
# In dev mode, intentions are applied inline.
consul config write "$INFRA_DIR/consul/intentions.hcl" 2>/dev/null || warn "Intentions may need manual split-apply."

# ── Register Jobs ──
log "Registering Nomad jobs..."
nomad job run -namespace=keystone "$INFRA_DIR/nomad/keystone-api.nomad.hcl"
nomad job run -namespace=keystone "$INFRA_DIR/nomad/sandbox.nomad.hcl"
nomad job run -namespace=keystone "$INFRA_DIR/nomad/experiment.nomad.hcl"

log ""
log "Keystone infra is running:"
log "  Consul UI : http://localhost:8500"
log "  Nomad UI  : http://localhost:4646"
log "  API Server: http://localhost:8080"
log ""
log "Dispatch a sandbox:"
log "  nomad job dispatch -namespace=keystone -meta sandbox_id=sb-test -meta spec_id=my-spec keystone-sandbox"
log ""
log "Tear down with:"
log "  $0 teardown"
