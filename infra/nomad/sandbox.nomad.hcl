// ================================================================
// Keystone Sandbox — Production Job (Podman + crun)
// ================================================================
//
// Parameterized batch job: dispatched once per sandbox creation.
// The Keystone API server calls:
//   nomad job dispatch keystone-sandbox -meta sandbox_id=sb-xxx -meta spec_id=...
//
// On Linux with crun, containers start in ~100-200ms with ~5MB overhead.
// Each sandbox is a task group with shared networking:
//   - agent task: the AI agent process
//   - svc-* tasks: auxiliary services from the spec (db, cache, etc.)
//
// All tasks share localhost. Nomad exposes ports for Consul registration.
// ================================================================

job "keystone-sandbox" {
  type        = "batch"
  datacenters = ["dc1"]

  parameterized {
    meta_required = ["sandbox_id", "spec_id"]
    meta_optional = ["agent_image", "timeout_seconds"]
  }

  group "sandbox" {
    count = 1

    restart {
      attempts = 0
      mode     = "fail"
    }

    network {
      // All tasks share this network namespace.
      // Agent and services communicate over localhost.
      port "agent" {}
      port "db"    {}
      port "cache" {}
    }

    // ── Agent service: registered in Consul for the API server to find ──
    service {
      name = "keystone-sandbox"
      port = "agent"

      meta {
        sandbox_id = "${NOMAD_META_sandbox_id}"
        spec_id    = "${NOMAD_META_spec_id}"
      }

      tags = [
        "sandbox",
        "sandbox_id:${NOMAD_META_sandbox_id}",
        "spec_id:${NOMAD_META_spec_id}",
      ]

      check {
        name     = "sandbox-health"
        type     = "http"
        path     = "/healthz"
        port     = "agent"
        interval = "5s"
        timeout  = "2s"
      }
    }

    // ── DB service: registered separately so SDK sees services.db ──
    service {
      name = "keystone-sandbox-db"
      port = "db"

      meta {
        sandbox_id   = "${NOMAD_META_sandbox_id}"
        service_name = "db"
      }

      tags = [
        "sandbox-service",
        "sandbox_id:${NOMAD_META_sandbox_id}",
      ]

      check {
        name     = "db-health"
        type     = "tcp"
        port     = "db"
        interval = "5s"
        timeout  = "2s"
      }
    }

    // ── Agent task ──
    task "agent" {
      driver = "podman"

      config {
        // Default image; can be overridden via agent_image meta.
        image      = "keystone-agent-runner:latest"
        force_pull = false
        ports      = ["agent"]
      }

      env {
        PORT                = "${NOMAD_PORT_agent}"
        KEYSTONE_SANDBOX_ID = "${NOMAD_META_sandbox_id}"
        KEYSTONE_BASE_URL   = "http://keystone-api.service.consul:8080"
        WORKSPACE           = "${NOMAD_ALLOC_DIR}/workspace"

        // Services available on localhost within the task group.
        DB_HOST    = "localhost"
        DB_PORT    = "${NOMAD_PORT_db}"
        CACHE_HOST = "localhost"
        CACHE_PORT = "${NOMAD_PORT_cache}"
      }

      resources {
        cpu    = 2000  // 2 vCPU
        memory = 4096  // 4 GiB
      }

      kill_timeout = "10s"
    }

    // ── Database sidecar (Postgres) ──
    task "svc-db" {
      driver = "podman"

      lifecycle {
        hook    = "prestart"
        sidecar = true
      }

      config {
        image      = "docker.io/library/postgres:16-alpine"
        force_pull = false
        ports      = ["db"]
      }

      env {
        POSTGRES_PASSWORD = "keystone"
        POSTGRES_DB       = "sandbox"
        PGPORT            = "${NOMAD_PORT_db}"
      }

      resources {
        cpu    = 100
        memory = 128
      }
    }

    // ── Cache sidecar (Redis) ──
    task "svc-cache" {
      driver = "podman"

      lifecycle {
        hook    = "prestart"
        sidecar = true
      }

      config {
        image      = "docker.io/library/redis:7-alpine"
        force_pull = false
        ports      = ["cache"]
        args       = ["redis-server", "--port", "${NOMAD_PORT_cache}"]
      }

      resources {
        cpu    = 50
        memory = 64
      }
    }
  }
}
