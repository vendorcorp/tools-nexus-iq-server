################################################################################
# Load Vendor Corp Shared Infra
################################################################################
module "shared" {
  source      = "git::ssh://git@github.com/vendorcorp/terraform-shared-infrastructure.git?ref=v0.3.0"
  environment = var.environment
}

################################################################################
# PostgreSQL Provider
################################################################################
provider "postgresql" {
  scheme          = "awspostgres"
  host            = module.shared.pgsql_cluster_endpoint_write
  port            = module.shared.pgsql_cluster_port
  database        = "postgres"
  username        = module.shared.pgsql_cluster_master_username
  password        = var.pgsql_password
  sslmode         = "require"
  connect_timeout = 15
  superuser       = false
}

################################################################################
# PostgreSQL Role and Database
################################################################################
locals {
  pgsql_database = "${var.nxrm_instance_purpose}_nxiq"
  pgsql_username = "${var.nxrm_instance_purpose}_nxiq"
}

resource "postgresql_role" "nxrm" {
  name     = local.pgsql_username
  login    = true
  password = local.pgsql_user_password
}

resource "postgresql_grant_role" "grant_root" {
  role              = module.shared.pgsql_cluster_master_username
  grant_role        = postgresql_role.nxrm.name
  with_admin_option = true
}

resource "postgresql_database" "nxrm" {
  name              = local.pgsql_database
  owner             = local.pgsql_username
  template          = "template0"
  lc_collate        = "C"
  connection_limit  = -1
  allow_connections = true
}

################################################################################
# Connect to our k8s Cluster
################################################################################
provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = module.shared.eks_cluster_arn
}

################################################################################
# k8s Namespace
################################################################################
resource "kubernetes_namespace" "nxrm" {
  metadata {
    name = var.target_namespace
  }
}

################################################################################
# k8s StorageClass for Local Node Storage
################################################################################
# This is already created in tools-nexus-repository (2022-03-30)

################################################################################
# k8s Secrets
################################################################################
resource "kubernetes_secret" "nxiq" {
  metadata {
    name      = "sonatype-nxiq"
    namespace = var.target_namespace
  }

  binary_data = {
    "license.lic" = filebase64("${path.module}/sonatype-license.lic")
  }

  data = {
    "pgsql_password" = local.pgsql_user_password
  }

  type = "Opaque"
}

################################################################################
# Create PersistentVolume
################################################################################
resource "kubernetes_persistent_volume" "nxiq_data" {
  metadata {
    name = "nxiq-data-pv"
  }
  spec {
    capacity = {
      storage = "50Gi"
    }
    volume_mode                      = "Filesystem"
    access_modes                     = ["ReadWriteOnce"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = "local-node-storage"
    persistent_volume_source {
      local {
        path = "/mnt"
      }
    }
    node_affinity {
      required {
        node_selector_term {
          match_expressions {
            key      = "instancegroup"
            operator = "In"
            values   = ["shared"]
          }
        }
        node_selector_term {
          match_expressions {
            key      = "topology.kubernetes.io/zone"
            operator = "In"
            values   = module.shared.availability_zones
          }
        }
      }
    }
  }
}

resource "kubernetes_persistent_volume" "nxiq_logs" {
  metadata {
    name = "nxiq-logs-pv"
  }
  spec {
    capacity = {
      storage = "50Gi"
    }
    volume_mode                      = "Filesystem"
    access_modes                     = ["ReadWriteOnce"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = "local-node-storage"
    persistent_volume_source {
      local {
        path = "/mnt"
      }
    }
    node_affinity {
      required {
        node_selector_term {
          match_expressions {
            key      = "instancegroup"
            operator = "In"
            values   = ["shared"]
          }
        }
        node_selector_term {
          match_expressions {
            key      = "topology.kubernetes.io/zone"
            operator = "In"
            values   = module.shared.availability_zones
          }
        }
      }
    }
  }
}

################################################################################
# Create PersistentVolumeClaim
################################################################################
resource "kubernetes_persistent_volume_claim" "nxiq_data" {
  metadata {
    name      = "nxiq-data-pvc"
    namespace = var.target_namespace
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-node-storage"
    resources {
      requests = {
        storage = "40Gi"
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim" "nxiq_logs" {
  metadata {
    name      = "nxiq-logs-pvc"
    namespace = var.target_namespace
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-node-storage"
    resources {
      requests = {
        storage = "40Gi"
      }
    }
  }
}

################################################################################
# Create Deployment for NXRM
################################################################################
resource "kubernetes_deployment" "nxiq" {
  metadata {
    name      = "${var.nxrm_instance_purpose}-nxiq"
    namespace = var.target_namespace
    labels = {
      app = "nxiq"
    }
  }
  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "nxiq"
      }
    }

    template {
      metadata {
        labels = {
          app = "nxiq"
        }
      }

      spec {
        node_selector = {
          instancegroup = "shared"
        }

        init_container {
          name    = "chown-nexusdata-owner-to-nexus-and-init-log-dir"
          image   = "busybox:1.33.1"
          command = ["/bin/sh"]

          args = [
            "-c",
            ">- chown -R '1000:1000' /sonatype-work /var/log/nexus-iq-server"
          ]

          volume_mount {
            mount_path = "/sonatype-work"
            name       = "nxiq-data"
          }

          volume_mount {
            mount_path = "/var/log/nexus-iq-server"
            name       = "nxiq-logs"
          }
        }

        container {
          image             = "sonatype/nexus-iq-server:1.135.0"
          name              = "nxiq-app"
          image_pull_policy = "IfNotPresent"

          env {
            name  = "JAVA_OPTS"
            value = "-Ddw.baseUrl=https://iq.corp.${module.shared.dns_zone_public_name} -Ddw.licenseFile=/nxiq-secrets/license.lic -Djava.util.prefs.userRoot=/sonatype-work/javaprefs"
          }

          port {
            container_port = 8070
          }

          port {
            container_port = 8071
          }

          security_context {
            run_as_user = 1000
          }

          volume_mount {
            mount_path = "/sonatype-work"
            name       = "nxiq-data"
          }

          volume_mount {
            mount_path = "/var/log/nexus-iq-server"
            name       = "nxiq-logs"
          }

          volume_mount {
            mount_path = "/nxiq-secrets"
            name       = "nxiq-secrets"
          }
        }

        volume {
          name = "nxiq-data"
          persistent_volume_claim {
            claim_name = "nxiq-data-pvc"
          }
        }

        volume {
          name = "nxiq-logs"
          persistent_volume_claim {
            claim_name = "nxiq-logs-pvc"
          }
        }

        volume {
          name = "nxiq-secrets"
          secret {
            secret_name = "sonatype-nxiq"
          }
        }
      }
    }
  }
}

################################################################################
# Create Service for NXIQ
################################################################################
resource "kubernetes_service" "nxiq" {
  metadata {
    name      = "nxiq-service"
    namespace = var.target_namespace
    labels = {
      app = "nxiq"
    }
  }
  spec {
    selector = {
      app = kubernetes_deployment.nxiq.metadata.0.labels.app
    }

    port {
      name        = "http"
      port        = 8070
      target_port = 8070
      protocol    = "TCP"
    }

    type = "NodePort"
  }
}

################################################################################
# Create Ingress for NXIQ
################################################################################
resource "kubernetes_ingress" "nxiq" {
  metadata {
    name      = "nxiq-ingress"
    namespace = var.target_namespace
    labels = {
      app = "nxiq"
    }
    annotations = {
      "kubernetes.io/ingress.class"               = "alb"
      "alb.ingress.kubernetes.io/group.name"      = "vencorcorp-shared-core"
      "alb.ingress.kubernetes.io/scheme"          = "internal"
      "alb.ingress.kubernetes.io/certificate-arn" = module.shared.vendorcorp_net_cert_arn
      "alb.ingress.kubernetes.io/success-codes"   = "200-303"
      # "alb.ingress.kubernetes.io/healthcheck-port" = "8071"
      # "alb.ingress.kubernetes.io/healthcheck-path" = "/healthcheck"
    }
  }

  spec {
    rule {
      host = "iq.corp.${module.shared.dns_zone_public_name}"
      http {
        path {
          path = "/*"
          backend {
            service_name = "nxiq-service"
            service_port = 8070
          }
        }
      }
    }
  }

  wait_for_load_balancer = true
}

################################################################################
# Add/Update DNS for Load Balancer Ingress
################################################################################
resource "aws_route53_record" "keycloak_dns" {
  zone_id = module.shared.dns_zone_public_id
  name    = "iq.corp"
  type    = "CNAME"
  ttl     = "300"
  records = [
    kubernetes_ingress.nxiq.status.0.load_balancer.0.ingress.0.hostname
  ]
}
