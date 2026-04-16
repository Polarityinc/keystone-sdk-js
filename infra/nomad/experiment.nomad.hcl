// Batch job dispatched when `experiments.run(id)` is called.
// The controller task fans out one sandbox dispatch per scenario,
// collects results, and writes the final RunResults back to the API.

variable "docker_registry" {
  type    = string
  default = "registry.keystone.internal"
}

job "keystone-experiment" {
  type        = "batch"
  datacenters = ["dc1"]
  namespace   = "keystone"

  parameterized {
    meta_required = ["experiment_id", "spec_id"]
    meta_optional = ["seed", "concurrency"]
  }

  group "controller" {
    count = 1

    restart {
      attempts = 2
      interval = "1m"
      delay    = "10s"
      mode     = "fail"
    }

    network {
      mode = "bridge"

      port "metrics" {}
    }

    service {
      name = "keystone-experiment"
      port = "metrics"

      meta {
        experiment_id = "${NOMAD_META_experiment_id}"
      }

      tags = [
        "experiment",
        "experiment_id:${NOMAD_META_experiment_id}",
      ]

      check {
        name     = "experiment-alive"
        type     = "http"
        path     = "/healthz"
        port     = "metrics"
        interval = "10s"
        timeout  = "3s"
      }

      connect {
        sidecar_service {
          proxy {
            upstreams {
              destination_name = "keystone-api"
              local_bind_port  = 8200
            }
          }
        }
      }
    }

    task "run-experiment" {
      driver = "docker"

      config {
        image = "${var.docker_registry}/keystone-experiment-runner:latest"

        args = [
          "--experiment-id", "${NOMAD_META_experiment_id}",
          "--spec-id", "${NOMAD_META_spec_id}",
          "--seed", "${NOMAD_META_seed}",
          "--concurrency", "${NOMAD_META_concurrency}",
          "--api-url", "http://${NOMAD_UPSTREAM_ADDR_keystone_api}",
          "--metrics-port", "${NOMAD_PORT_metrics}",
        ]
      }

      env {
        // The experiment runner dispatches sandbox jobs via the Nomad API.
        NOMAD_ADDR = "http://${attr.unique.network.ip-address}:4646"
      }

      template {
        data        = <<-EOF
          {{ with secret "secret/data/keystone/api" }}
          KEYSTONE_API_KEY={{ .Data.data.api_key }}
          {{ end }}
          {{ with secret "secret/data/keystone/nomad" }}
          NOMAD_TOKEN={{ .Data.data.token }}
          {{ end }}
        EOF
        destination = "secrets/env.env"
        env         = true
      }

      resources {
        cpu    = 300
        memory = 256
      }

      // Experiments can run up to 30 minutes before hard kill.
      kill_timeout = "30s"
    }
  }
}
