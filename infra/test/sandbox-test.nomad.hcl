// Test sandbox job — parameterized, dispatched per sandbox creation.
// Uses the lightweight keystone-sandbox-test image (alpine + socat, ~10MB).

job "keystone-sandbox" {
  type        = "batch"
  datacenters = ["dc1"]

  parameterized {
    meta_required = ["sandbox_id", "spec_id"]
    meta_optional = ["timeout_seconds"]
  }

  group "sandbox" {
    count = 1

    restart {
      attempts = 0
      mode     = "fail"
    }

    network {
      port "agent" {}
    }

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
        path     = "/"
        port     = "agent"
        interval = "5s"
        timeout  = "2s"
      }
    }

    task "agent" {
      driver = "docker"

      config {
        image = "keystone-sandbox-test:dev"
        ports      = ["agent"]
      }

      env {
        PORT                = "${NOMAD_PORT_agent}"
        KEYSTONE_SANDBOX_ID = "${NOMAD_META_sandbox_id}"
        SPEC_ID             = "${NOMAD_META_spec_id}"
      }

      resources {
        cpu    = 100
        memory = 64
      }
    }
  }
}
