// Additional Consul health checks beyond what Nomad registers.
//
// These are useful for monitoring sandbox service dependencies
// (databases, caches, etc.) that specs might declare.

// Example: a sandbox-provisioned Postgres instance.
// The Keystone API dynamically registers these when a sandbox
// spec declares services. This file documents the pattern.

// Registered programmatically by the API server via the Consul HTTP API:
//
//   PUT /v1/agent/check/register
//   {
//     "Name": "sandbox-svc-${sandbox_id}-${service_name}",
//     "ServiceID": "keystone-sandbox-${sandbox_id}",
//     "TCP": "${host}:${port}",
//     "Interval": "5s",
//     "Timeout": "2s",
//     "DeregisterCriticalServiceAfter": "30s",
//     "Notes": "Health check for sandbox service: ${service_name}"
//   }
//
// Deregistered when the sandbox is destroyed:
//
//   PUT /v1/agent/check/deregister/sandbox-svc-${sandbox_id}-${service_name}

// The ServiceInfo type in the SDK maps directly to Consul's catalog:
//
//   ServiceInfo.host  -> Consul service address
//   ServiceInfo.port  -> Consul service port
//   ServiceInfo.ready -> Consul check status == "passing"
