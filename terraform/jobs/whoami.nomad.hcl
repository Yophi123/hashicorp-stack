job "whoami" {
  type = "service"

  group "web" {
    count = 1

     # 1. Give upstream load balancers time to stop sending traffic
    shutdown_delay = "30s"

    network {
      port "http" {
        static = 28080
        to     = 80
      }
    }

    service {
      name     = "whoami"
      port     = "http"
      provider = "consul"

      check {
        type     = "http"
        path     = "/"
        interval = "10s"
        timeout  = "2s"
      }
    }

    task "whoami" {
      driver = "docker"

      config {
        image = "traefik/whoami:v1.10"
        ports = ["http"]
        args  = ["--name", "${node.region}"]
      }

      resources {
        cpu    = 50
        memory = 32
      }
    }
  }
}