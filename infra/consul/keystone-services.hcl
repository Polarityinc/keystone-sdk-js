// Consul service defaults and intentions for the Keystone service mesh.
//
// Apply with:
//   consul config write infra/consul/keystone-services.hcl

// Global proxy defaults -- all sidecars in the "keystone" partition.
Kind = "proxy-defaults"
Name = "global"

Config {
  protocol = "http"
}

MeshGateway {
  Mode = "local"
}

---

// keystone-api: the central API server.
Kind = "service-defaults"
Name = "keystone-api"

Protocol = "http"

---

// keystone-sandbox: ephemeral sandbox agents.
Kind = "service-defaults"
Name = "keystone-sandbox"

Protocol = "http"

---

// keystone-experiment: experiment controller jobs.
Kind = "service-defaults"
Name = "keystone-experiment"

Protocol = "http"
