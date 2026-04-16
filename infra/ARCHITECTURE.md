```
                          Keystone Platform — System Architecture

    ┌─────────────────────────────────────────────────────────────────────────────┐
    │                          Digital Ocean Droplet                              │
    │                                                                             │
    │  ┌──────────────┐       ┌──────────────────────────────────────────────┐    │
    │  │              │       │                   Nomad                      │    │
    │  │   Consul     │       │                                              │    │
    │  │              │       │  ┌─ keystone-api (service job) ────────────┐ │    │
    │  │  - service   │◄──────│  │  Podman + crun                         │ │    │
    │  │    catalog   │       │  │  ┌─────────────────────────────────┐   │ │    │
    │  │  - health    │       │  │  │  Keystone API Server            │   │ │    │
    │  │    checks    │       │  │  │  :8080                          │   │ │    │
    │  │  - service   │       │  │  │                                 │   │ │    │
    │  │    mesh      │       │  │  │  POST /v1/sandboxes             │   │ │    │
    │  │              │       │  │  │    ──► nomad job dispatch        │   │ │    │
    │  │              │       │  │  │  GET  /v1/sandboxes/:id         │   │ │    │
    │  │              │       │  │  │    ──► consul catalog query      │   │ │    │
    │  │              │       │  │  │  DELETE /v1/sandboxes/:id       │   │ │    │
    │  │              │       │  │  │    ──► nomad job stop            │   │ │    │
    │  │              │       │  │  └─────────────────────────────────┘   │ │    │
    │  │              │       │  └────────────────────────────────────────┘ │    │
    │  │              │       │                                              │    │
    │  │              │       │  ┌─ keystone-sandbox (parameterized batch) ─┐│    │
    │  │              │       │  │                                          ││    │
    │  │  ┌────────┐  │       │  │  Dispatched per sandbox. Each dispatch:  ││    │
    │  │  │sb-001  │  │◄──reg─│  │                                          ││    │
    │  │  │:29001  │  │       │  │  ┌─ task group (shared network) ───────┐││    │
    │  │  │passing │  │       │  │  │                                     │││    │
    │  │  ├────────┤  │       │  │  │  ┌────────────┐  ┌──────────────┐  │││    │
    │  │  │sb-002  │  │◄──reg─│  │  │  │   agent    │  │  svc-db      │  │││    │
    │  │  │:29002  │  │       │  │  │  │  Podman    │  │  Podman      │  │││    │
    │  │  │passing │  │       │  │  │  │  + crun    │  │  + crun      │  │││    │
    │  │  ├────────┤  │       │  │  │  │            │  │              │  │││    │
    │  │  │sb-003  │  │◄──reg─│  │  │  │  AI agent  │  │  postgres   │  │││    │
    │  │  │:29003  │  │       │  │  │  │  process   │  │  :5432       │  │││    │
    │  │  │passing │  │       │  │  │  │            │  │              │  │││    │
    │  │  └────────┘  │       │  │  │  └─────┬──────┘  └──────┬───────┘  │││    │
    │  │              │       │  │  │        │    localhost     │         │││    │
    │  │              │       │  │  │        └────────◄─────────┘         │││    │
    │  │              │       │  │  └─────────────────────────────────────┘││    │
    │  │              │       │  └──────────────────────────────────────────┘│    │
    │  └──────────────┘       └──────────────────────────────────────────────┘    │
    │                                                                             │
    │  Podman + crun (daemonless)         No Docker daemon running.              │
    │  Startup: ~100-200ms per sandbox    Memory overhead: ~5-10MB per sandbox   │
    │  Isolation: cgroups v2 + namespaces OCI-compatible images                  │
    └─────────────────────────────────────────────────────────────────────────────┘
                     │
                     │ HTTPS
                     ▼
    ┌─────────────────────────────────────────────────────────────────────────────┐
    │  SDK Clients                                                                │
    │                                                                             │
    │  import { Keystone } from '@polarity/keystone';                             │
    │  const ks = new Keystone({ baseUrl: 'https://keystone.example.com' });      │
    │                                                                             │
    │  // Create sandbox ──► API ──► Nomad dispatch ──► Podman+crun container     │
    │  const sb = await ks.sandboxes.create({ spec_id: 'eval-v2' });              │
    │                                                                             │
    │  // Get sandbox ──► API ──► Consul catalog ──► ServiceInfo                  │
    │  const info = await ks.sandboxes.get(sb.id);                                │
    │  // info.services.db = { host: '...', port: 5432, ready: true }             │
    │                                                                             │
    │  // Destroy sandbox ──► API ──► Nomad stop ──► Consul deregister            │
    │  await ks.sandboxes.destroy(sb.id);                                         │
    └─────────────────────────────────────────────────────────────────────────────┘


    ┌─────────────────────────────────────────────────────────────────────────────┐
    │  Data Flow: Sandbox Lifecycle                                               │
    │                                                                             │
    │  CREATE:                                                                    │
    │    SDK ──► API ──► Nomad dispatch ──► crun starts container (~150ms)         │
    │                                  ──► Consul registers service               │
    │                                  ──► health check passes ──► state: ready   │
    │                                                                             │
    │  SERVICES (from spec YAML):                                                 │
    │    spec.services.db = postgres:16-alpine                                    │
    │      ──► Nomad task group adds svc-db task (Podman sidecar)                 │
    │      ──► shares network namespace with agent (localhost:5432)               │
    │      ──► Consul registers with TCP health check                             │
    │      ──► SDK sees: services.db = { host, port: 5432, ready: true }          │
    │                                                                             │
    │  DESTROY:                                                                   │
    │    SDK ──► API ──► Nomad stop -purge ──► crun kills containers              │
    │                                     ──► Consul auto-deregisters             │
    └─────────────────────────────────────────────────────────────────────────────┘
```
