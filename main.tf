terraform {
  # The configuration for this backend will be filled in by Terragrunt
  backend "gcs" {}
}

provider "google" {
  region      = "${var.provider["region"]}"
  project     = "${var.provider["project"]}"
}

data "google_client_config" "current" {}

provider "kubernetes" {
  load_config_file = false

  host                   = "${google_container_cluster.new_container_cluster.endpoint}"
  token                  = "${data.google_client_config.current.access_token}"
  cluster_ca_certificate = "${base64decode(google_container_cluster.new_container_cluster.master_auth.0.cluster_ca_certificate)}"
}

resource "kubernetes_service_account" "tiller" {
  metadata {
    name      = "tiller"
    namespace = "kube-system"
  }
}

resource "kubernetes_cluster_role_binding" "tiller" {
  metadata {
    name = "tiller"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }

  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "User"
    name      = "system:serviceaccount:kube-system:tiller"
  }
}

locals {
  name_prefix = "${var.general["name"]}-${var.general["env"]}"
  empty_object = {}
}

# This data source fetches the project name, and provides the appropriate URLs to use for container registry for this project.
# https://www.terraform.io/docs/providers/google/d/google_container_registry_repository.html
data "google_container_registry_repository" "registry" {}

# Provides access to available Google Container Engine versions in a zone for a given project.
# https://www.terraform.io/docs/providers/google/d/google_container_engine_versions.html
data "google_container_engine_versions" "region" {
  zone = "${var.general["zone"]}"
}

# Manages a Node Pool resource within GKE
# https://www.terraform.io/docs/providers/google/r/container_node_pool.html
resource "google_container_node_pool" "new_container_cluster_node_pool" {
  count = "${length(var.node_pool)}"
  name       = "${lookup(var.node_pool[count.index], "name", "${local.name_prefix}-pool-${count.index}")}"
  zone       = "${var.general["zone"]}"
  node_count = "${lookup(var.node_pool[count.index], "node_count", 3)}"
  cluster    = "${google_container_cluster.new_container_cluster.name}"

  node_config {
    disk_size_gb    = "${lookup(var.node_pool[count.index], "disk_size_gb", 10)}"
    disk_type       = "${lookup(var.node_pool[count.index], "disk_type", "pd-standard")}"
    image_type      = "${lookup(var.node_pool[count.index], "image", "COS")}"
    local_ssd_count = "${lookup(var.node_pool[count.index], "local_ssd_count", 0)}"
    machine_type    = "${lookup(var.node_pool[count.index], "machine_type", "n1-standard-1")}"

    oauth_scopes    = "${split(",", lookup(var.node_pool[count.index], "oauth_scopes", "https://www.googleapis.com/auth/compute,https://www.googleapis.com/auth/devstorage.read_only,https://www.googleapis.com/auth/logging.write,https://www.googleapis.com/auth/monitoring"))}"
    preemptible     = "${lookup(var.node_pool[count.index], "preemptible", false)}"
    service_account = "${lookup(var.node_pool[count.index], "service_account", "default")}"
    labels          = {
      group = "${lookup(var.node_pool[count.index], "group_label", "default")}"
    }
    tags            = "${var.tags}"
    metadata        = "${var.metadata}"
  }

  autoscaling {
    min_node_count = "${lookup(var.node_pool[count.index], "min_node_count", 2)}"
    max_node_count = "${lookup(var.node_pool[count.index], "max_node_count", 3)}"
  }

  management {
    auto_repair  = "${lookup(var.node_pool[count.index], "auto_repair", true)}"
    auto_upgrade = "${lookup(var.node_pool[count.index], "auto_upgrade", true)}"
  }
}

# Creates a Google Kubernetes Engine (GKE) cluster
# https://www.terraform.io/docs/providers/google/r/container_cluster.html
resource "google_container_cluster" "new_container_cluster" {
  name        = "${local.name_prefix}-master"
  description = "Kubernetes ${var.general["name"]} in ${var.general["zone"]}"
  zone        = "${var.general["zone"]}"
  # region - Conflict zone

  network                  = "${lookup(var.master, "network", "default")}"
  subnetwork               = "${lookup(var.master, "subnetwork", "default")}"
  additional_zones         = ["${var.node_additional_zones}"]
  initial_node_count       = "${lookup(var.default_node_pool, "node_count", 2)}"
  remove_default_node_pool = "${lookup(var.default_node_pool, "remove", false)}"
  
  addons_config {
    horizontal_pod_autoscaling {
      disabled = "${lookup(var.master, "disable_horizontal_pod_autoscaling", false)}"
    }

    http_load_balancing {
      disabled = "${lookup(var.master, "disable_http_load_balancing", false)}"
    }

    kubernetes_dashboard {
      disabled = "${lookup(var.master, "disable_kubernetes_dashboard", false)}"
    }

    network_policy_config {
      disabled = "${lookup(var.master, "disable_network_policy_config", true)}"
    }
  }
  
  # cluster_ipv4_cidr - default 
  enable_kubernetes_alpha = "${lookup(var.master, "enable_kubernetes_alpha", false)}"
  enable_legacy_abac      = "${lookup(var.master, "enable_legacy_abac", false)}"
  ip_allocation_policy    = "${var.ip_allocation_policy}"
  
  maintenance_policy {
    daily_maintenance_window {
      start_time = "${lookup(var.master, "maintenance_window", "04:30")}"
    }
  }
  
  # master_authorized_networks_config - disable (security)
  min_master_version = "${lookup(var.master, "version", data.google_container_engine_versions.region.latest_master_version)}"
  node_version       = "${lookup(var.master, "version", data.google_container_engine_versions.region.latest_node_version)}"
  monitoring_service = "${lookup(var.master, "monitoring_service", "none")}"
  logging_service    = "${lookup(var.master, "logging_service", "logging.googleapis.com")}"
  
  node_config {
    disk_size_gb    = "${lookup(var.default_node_pool, "disk_size_gb", 10)}"
    disk_type       = "${lookup(var.default_node_pool, "disk_type", "pd-standard")}"
    image_type      = "${lookup(var.default_node_pool, "image", "COS")}"
    local_ssd_count = "${lookup(var.default_node_pool, "local_ssd_count", 0)}"
    machine_type    = "${lookup(var.default_node_pool, "machine_type", "n1-standard-1")}"
    # min_cpu_platform - disable (useless)

    # BUG Provider - recreate loop
    # guest_accelerator {
    #   count = "${lookup(var.master, "gpus_number", 0)}"
    #   type  = "${lookup(var.master, "gpus_type", "nvidia-tesla-k80")}"
    # }

    oauth_scopes    = ["${split(",", lookup(var.default_node_pool, "oauth_scopes", "https://www.googleapis.com/auth/compute,https://www.googleapis.com/auth/devstorage.read_only,https://www.googleapis.com/auth/logging.write,https://www.googleapis.com/auth/monitoring"))}"]
    preemptible     = "${lookup(var.default_node_pool, "preemptible", false)}"
    service_account = "${lookup(var.default_node_pool, "service_account", "default")}"
    labels          = "${var.labels}"
    tags            = "${var.tags}"
    metadata        = "${var.metadata}"
  }
}
