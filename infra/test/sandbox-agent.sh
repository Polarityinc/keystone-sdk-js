#!/bin/sh
# Minimal sandbox agent for testing the Nomad + Consul pipeline.
# Exposes HTTP on $PORT via socat, stays alive until killed.

PORT="${PORT:-8080}"
SANDBOX_ID="${KEYSTONE_SANDBOX_ID:-unknown}"
SPEC_ID="${SPEC_ID:-unknown}"
WORKSPACE="${WORKSPACE:-/workspace}"

echo "[sandbox] id=$SANDBOX_ID spec=$SPEC_ID port=$PORT pid=$$"

mkdir -p "$WORKSPACE"
echo "{\"sandbox_id\":\"$SANDBOX_ID\",\"started_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" > "$WORKSPACE/sandbox.json"
echo "[sandbox] wrote $WORKSPACE/sandbox.json"
echo "[sandbox] listening on :$PORT"

BODY="{\"status\":\"ok\",\"sandbox_id\":\"$SANDBOX_ID\",\"spec_id\":\"$SPEC_ID\"}"

# socat with SYSTEM forks a handler per connection — reliable and lightweight.
exec socat TCP-LISTEN:"$PORT",reuseaddr,fork SYSTEM:"echo 'HTTP/1.1 200 OK'; echo 'Content-Type: application/json'; echo 'Connection: close'; echo; echo '$BODY'"
