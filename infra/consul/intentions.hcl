// Service intentions: which services can talk to which.
//
// Apply with:
//   consul config write infra/consul/intentions.hcl

// Sandboxes can reach the API server (to report traces, state).
Kind = "service-intentions"
Name = "keystone-api"

Sources = [
  {
    Name   = "keystone-sandbox"
    Action = "allow"
  },
  {
    Name   = "keystone-experiment"
    Action = "allow"
  }
]

---

// Deny everything else by default.
Kind = "service-intentions"
Name = "*"

Sources = [
  {
    Name   = "*"
    Action = "deny"
  }
]
