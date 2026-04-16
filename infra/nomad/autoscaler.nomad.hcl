// Nomad Autoscaler — runs on the control plane node.
// Watches for pending sandbox allocations and creates/destroys
// DO droplets as Nomad client workers.

job "autoscaler" {
  type        = "service"
  datacenters = ["dc1"]

  group "autoscaler" {
    count = 1

    task "autoscaler" {
      driver = "raw_exec"

      artifact {
        source      = "https://releases.hashicorp.com/nomad-autoscaler/0.4.5/nomad-autoscaler_0.4.5_linux_amd64.zip"
        destination = "local/"
      }

      config {
        command = "local/nomad-autoscaler"
        args    = ["agent", "-config", "local/config.hcl"]
      }

      template {
        data        = <<-HCL
          nomad {
            address = "http://{{ env "attr.unique.network.ip-address" }}:4646"
          }

          policy_eval {
            workers = {
              cluster    = 2
              horizontal = 2
            }
          }

          apm "nomad-apm" {
            driver = "nomad-apm"
          }

          target "do-workers" {
            driver = "dynamic-app-sizing"
          }

          strategy "target-value" {
            driver = "target-value"
          }
        HCL
        destination = "local/config.hcl"
      }

      resources {
        cpu    = 100
        memory = 128
      }
    }
  }
}
