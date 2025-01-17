/**
  * Copyright 2022 Google LLC
  *
  * Licensed under the Apache License, Version 2.0 (the "License");
  * you may not use this file except in compliance with the License.
  * You may obtain a copy of the License at
  *
  *      http://www.apache.org/licenses/LICENSE-2.0
  *
  * Unless required by applicable law or agreed to in writing, software
  * distributed under the License is distributed on an "AS IS" BASIS,
  * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  * See the License for the specific language governing permissions and
  * limitations under the License.
  */

locals {
  gke_master_version   = var.gke_version != null ? var.gke_version : data.google_container_engine_versions.gkeversion.latest_master_version
  node_service_account = var.node_service_account == null ? data.google_compute_default_service_account.account.email : var.node_service_account
  oauth_scopes = [
    "https://www.googleapis.com/auth/cloud-platform",
    "https://www.googleapis.com/auth/dataaccessauditlogging",
  ]
}

data "google_compute_default_service_account" "account" {
  project = var.project_id
}

data "google_client_config" "current" {}

data "google_container_engine_versions" "gkeversion" {
  location = var.region
  project  = var.project_id
}

module "network" {
  source = "../../common/network"

  nic0_existing   = var.network_existing
  project_id      = var.project_id
  region          = var.region
  resource_prefix = var.resource_prefix
}

module "dashboard" {
  source = "../../common/dashboard"
  count  = var.enable_gke_dashboard ? 1 : 0

  enable_gce_gke_gpu_utilization_widgets = true
  enable_nvidia_dcgm_widgets             = true
  enable_nvidia_nvml_widgets             = true
  project_id                             = var.project_id
  resource_prefix                        = var.resource_prefix
}

module "resource_policy" {
  source = "../../common/resource_policy"
  for_each = {
    for idx, node_pool in var.node_pools : "np-${idx}" => node_pool
    if node_pool.compact_placement_policy != null
  }
  project_id                    = var.project_id
  new_resource_policy_name      = each.value.compact_placement_policy.new_policy ? "${var.resource_prefix}-${each.key}" : null
  existing_resource_policy_name = each.value.compact_placement_policy.existing_policy_name
  region                        = var.region
}

# Definition of the private GKE cluster.
resource "google_container_cluster" "cluster" {
  provider = google-beta

  project  = var.project_id
  name     = var.resource_prefix
  location = var.region

  # We need to explicitly manage the node pool to enable features such as
  # auto-upgrade and auto-scaling, but we can't create a cluster with no node
  # pool defined. So we create the smallest possible default  node pool and
  # immediately delete it. This is a best-practice suggested in the Terraform
  # documentation for the container_cluster resource.
  remove_default_node_pool = true
  initial_node_count       = 1
  min_master_version       = local.gke_master_version
  deletion_protection      = false

  network    = module.network.network_self_links[0]
  subnetwork = module.network.subnetwork_self_links[0]

  master_authorized_networks_config {
  }

  master_auth {
    client_certificate_config {
      issue_client_certificate = false
    }
  }

  # Enable shielded nodes to meet go/gke-cluster-pattern#req1.1.5
  enable_shielded_nodes = true

  cluster_autoscaling {
    autoscaling_profile = "OPTIMIZE_UTILIZATION"
    # The name of this attribute is very misleading, it controls node
    # autoprovisioning (NAP), not autoscaling.
    enabled = false
  }

  network_policy {
    # Enabling NetworkPolicy for clusters with DatapathProvider=ADVANCED_DATAPATH
    # is not allowed. Dataplane V2 will take care of network policy enforcement
    # instead.
    enabled = false
    # GKE Dataplane V2 support. This must be set to PROVIDER_UNSPECIFIED in
    # order to let the datapath_provider take effect.
    # https://github.com/terraform-google-modules/terraform-google-kubernetes-engine/issues/656#issuecomment-720398658
    provider = "PROVIDER_UNSPECIFIED"
  }

  # This change will also enable the metadata server on nodes.
  # go/gke-cluster-pattern#req4.1.1#req1.1.5 (parts of, vTPM is another section)
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  authenticator_groups_config {
    # Contact safer-gcp to get your group whitelisted for access.
    # Beta feaure: don't depend on it for breakglass access.
    security_group = "gke-security-groups@google.com"
  }

  datapath_provider = "ADVANCED_DATAPATH"
  networking_mode   = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_ipv4_cidr_block  = "/14"
    services_ipv4_cidr_block = "/20"
  }


  release_channel {
    channel = "UNSPECIFIED"
  }

  addons_config {
    gce_persistent_disk_csi_driver_config {
      enabled = true
    }
    gcs_fuse_csi_driver_config {
      enabled = true
    }
  }

  # enable multi-NIC network
  enable_multi_networking = true

  lifecycle {
    # Ignore all changes to the default node pool. It's being removed
    # after creation anyway.
    ignore_changes = [
      node_config
    ]
  }

  logging_service    = "logging.googleapis.com/kubernetes"
  monitoring_service = "monitoring.googleapis.com/kubernetes"

  timeouts {
    create = "120m"
    update = "120m"
  }
}

# We define explicit node pools, so that it can be modified without
# having to destroy the entire cluster.
resource "google_container_node_pool" "node-pools" {
  provider = google-beta
  count    = length(var.node_pools)

  project        = var.project_id
  name           = "np-${count.index}"
  cluster        = google_container_cluster.cluster.id
  node_locations = [var.node_pools[count.index].zone]
  node_count     = var.node_pools[count.index].node_count

  upgrade_settings {
    max_surge       = 0
    max_unavailable = 1
  }

  management {
    auto_repair = true
    # disabling auto_upgrade to stop automatic upgrade during customer workload execution.
    auto_upgrade = false
  }

  node_config {
    service_account = local.node_service_account
    machine_type    = var.node_pools[count.index].machine_type
    image_type      = "COS_CONTAINERD"
    disk_size_gb    = var.disk_size_gb
    disk_type       = var.disk_type

    ephemeral_storage_local_ssd_config {
      local_ssd_count = 16
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    gvnic {
      enabled = true
    }

    # Implied by Workload Identity
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    # Implied by workload identity.
    metadata = {
      "disable-legacy-endpoints" = "true"
    }

    labels = {
      "cloud.google.com/gke-kdump-enabled" = "true"
    }

    dynamic "host_maintenance_policy" {
      for_each = var.host_maintenance_interval != null ? [1] : []
      content {
        maintenance_interval = var.host_maintenance_interval
      }
    }

    dynamic "reservation_affinity" {
      for_each = try(
        var.node_pools[count.index].compact_placement_policy.specific_reservation,
        null
        ) != null ? [
        var.node_pools[count.index].compact_placement_policy.specific_reservation
      ] : []
      content {
        consume_reservation_type = "SPECIFIC_RESERVATION"
        key                      = "compute.googleapis.com/reservation-name"
        values                   = [reservation_affinity.value]
      }
    }

    oauth_scopes = local.oauth_scopes
  }

  network_config {
    dynamic "additional_node_network_configs" {
      for_each = toset(range(1, length(module.network.network_names)))
      iterator = id
      content {
        network    = module.network.network_names[id.value]
        subnetwork = module.network.subnetwork_names[id.value]
      }
    }
  }

  dynamic "placement_policy" {
    for_each = var.node_pools[count.index].compact_placement_policy != null ? [1] : []
    content {
      type        = "COMPACT"
      policy_name = module.resource_policy["np-${count.index}"].resource_name
    }
  }

  lifecycle {
    ignore_changes = [
      node_config[0].labels,
      node_config[0].taint,
    ]
  }
  timeouts {
    create = "10m"
    update = "10m"
  }
}


# For container logs to show up under Cloud Logging and GKE metrics to show up
# on Cloud Monitoring console, some project level roles are needed for the
# node_service_account
resource "google_project_iam_member" "node_service_account_logWriter" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${local.node_service_account}"
}

resource "google_project_iam_member" "node_service_account_metricWriter" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${local.node_service_account}"
}

resource "google_project_iam_member" "node_service_account_monitoringViewer" {
  project = var.project_id
  role    = "roles/monitoring.viewer"
  member  = "serviceAccount:${local.node_service_account}"
}

module "kubectl-apply" {
  source = "./kubectl-apply"

  cluster_id = resource.google_container_cluster.cluster.id
  daemonsets = {
    device_plugin = "https://raw.githubusercontent.com/GoogleCloudPlatform/container-engine-accelerators/master/cmd/nvidia_gpu/device-plugin.yaml"
    nvidia_driver = "https://raw.githubusercontent.com/GoogleCloudPlatform/container-engine-accelerators/master/nvidia-driver-installer/cos/daemonset-preloaded-latest.yaml"
    nccl_plugin   = "https://raw.githubusercontent.com/GoogleCloudPlatform/container-engine-accelerators/master/gpudirect-tcpx/nccl-tcpx-installer.yaml"
  }
  enable     = var.ksa != null
  ksa        = var.ksa
  gcp_sa     = local.node_service_account
  project_id = var.project_id
}
