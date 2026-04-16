// Long-running service job for the Keystone API server.

variable "docker_registry" {
  type    = string
  default = "registry.keystone.internal"
}

variable "api_count" {
  type    = number
  default = 2
}

job "keystone-api" {
  type        = "service"
  datacenters = ["dc1"]
  namespace   = "keystone"

  update {
    max_parallel     = 1
    health_check     = "checks"
    min_healthy_time = "15s"
    healthy_deadline = "2m"
    canary           = 1
    auto_revert      = true
    auto_promote     = true
  }

  group "api" {
    count = var.api_count

    spread {
      attribute = "${node.unique.id}"
    }

    network {
      mode = "bridge"

      port "http" {
        static = 8080
      }
    }

    service {
      name = "keystone-api"
      port = "http"

      tags = [
        "traefik.enable=true",
        "traefik.http.routers.keystone-api.rule=Host(`keystone.internal`)",
      ]

      check {
        name     = "api-health"
        type     = "http"
        path     = "/healthz"
        port     = "http"
        interval = "10s"
        timeout  = "3s"
      }

      // Accept connections from sandboxes and experiments over the mesh.
      connect {
        sidecar_service {}
      }
    }

    task "api" {
      driver = "docker"

      config {
        image = "${var.docker_registry}/keystone-api:latest"
        ports = ["http"]
      }

      template {
        data        = <<-EOF
          PORT={{ env "NOMAD_PORT_http" }}

          {{ with secret "secret/data/keystone/db" }}
          DATABASE_URL={{ .Data.data.url }}
          {{ end }}

          {{ with secret "secret/data/keystone/api" }}
          KEYSTONE_API_KEY={{ .Data.data.api_key }}
          {{ end }}

          # Nomad API access for dispatching sandbox/experiment jobs.
          NOMAD_ADDR=http://{{ env "attr.unique.network.ip-address" }}:4646
          {{ with secret "secret/data/keystone/nomad" }}
          NOMAD_TOKEN={{ .Data.data.token }}
          {{ end }}
        EOF
        destination = "secrets/env.env"
        env         = true
      }

      resources {
        cpu    = 1000
        memory = 512
      }
    }
  }
}
